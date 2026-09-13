import Foundation

/// A bounded ingress mailbox and a single serial disk owner. The lock protects
/// intent only: it is never held during SQLite, decryption, or a client callback.
/// Uncommitted removals are volatile; failure is never reported as durable.
final class ContentCacheMaintenanceCoordinator: @unchecked Sendable {
    typealias Namespace = EncryptedContentCache.Namespace
    struct Key: Hashable, Sendable {
        let deviceID: String
        let namespace: Namespace
        let itemID: String
        var byteCount: Int { deviceID.utf8.count + itemID.utf8.count + namespace.rawValue.utf8.count }
    }
    enum Outcome: Equatable, Sendable { case durable, durabilityUnknown, exhausted, capacity }
    struct Notice: Equatable, Sendable {
        let namespace: Namespace
        let outcome: Outcome
    }
    struct RestoreToken: Equatable, Sendable {
        let deviceID: String
        let generation: UUID
        let revision: UInt64
    }
    struct Restoration: Sendable {
        let token: RestoreToken
        let notifications: [CachedContentRecord]
        let sms: [CachedContentRecord]
        let clipboard: [CachedContentRecord]
    }
    struct Storage: Sendable {
        var remove: @Sendable (Key, Bool) -> Bool
        var put: @Sendable (Key, Data) throws -> Void
        var contents: @Sendable (String, Namespace) throws -> [CachedContentRecord]
        var revoke: @Sendable (String) throws -> Void
    }
    private struct Slot {
        let token: UUID
        let generation: UUID
        var payload: Data?
        var isRemoval: Bool
        var attempts = 0
        var due: TimeInterval?
    }
    private struct RestoreRequest {
        let token: RestoreToken
        let completion: @Sendable (Restoration?) -> Void
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.content-cache", qos: .utility)
    private let storage: Storage
    private let report: @Sendable (Notice) -> Void
    private let maxSlots: Int
    private let maxBytes: Int
    private let maxKeyBytes: Int
    private let retryDelays: [TimeInterval]
    private let now: @Sendable () -> TimeInterval
    private let automatic: Bool
    private var slots: [Key: Slot] = [:]
    private var generations: [String: UUID] = [:]
    private var revisions: [String: UInt64] = [:]
    private var restores: [String: RestoreRequest] = [:]
    private var revocations: Set<String> = []
    private var disabled: Set<Namespace> = []
    private var drainScheduled = false
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var closing = false
    private let shutdownCompletion = ShutdownCompletion()

    final class ShutdownCompletion: @unchecked Sendable {
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var finished = false
        init() { group.enter() }
        fileprivate func finish() {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true; group.leave()
        }
        func wait() async {
            await withCheckedContinuation { continuation in
                group.notify(queue: .global(qos: .utility)) { continuation.resume() }
            }
        }
    }
    private var executingBytes = 0
    private var executingNamespace: Namespace?

    init(storage: Storage? = nil, maxSlots: Int = 512, maxBytes: Int = 8 * 1024 * 1024,
         maxKeyBytes: Int = 1024 * 1024, retryDelays: [TimeInterval] = [1, 2, 5, 10, 30],
         automatic: Bool = true, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         report: @escaping @Sendable (Notice) -> Void = { _ in }) {
        self.storage = storage ?? ContentCacheWorkerStorage().operations
        self.maxSlots = maxSlots; self.maxBytes = maxBytes; self.maxKeyBytes = maxKeyBytes
        self.retryDelays = retryDelays; self.automatic = automatic; self.now = now; self.report = report
    }

    func remove(_ key: Key) { admit(key, payload: nil, removal: true) }
    func store(_ key: Key, payload: Data) { admit(key, payload: payload, removal: false) }

    private func admit(_ key: Key, payload: Data?, removal: Bool) {
        lock.lock()
        guard !stopped, !closing else { lock.unlock(); return }
        guard !disabled.contains(key.namespace) else { lock.unlock(); return }
        if generations[key.deviceID] == nil && generations.count >= maxSlots {
            disabled.insert(key.namespace)
            slots = slots.filter { $0.key.namespace != key.namespace }
            scheduleLocked(); lock.unlock()
            report(Notice(namespace: key.namespace, outcome: .capacity)); return
        }
        let generation = generationLocked(key.deviceID)
        if removal, let old = slots[key], old.isRemoval, old.generation == generation {
            lock.unlock(); return // A replay does not reset an exhausted retry budget.
        }
        revisions[key.deviceID, default: 0] &+= 1
        guard !disabled.contains(key.namespace) else { lock.unlock(); return }
        let others = slots.filter { $0.key != key }
        if (slots[key] == nil && slots.count >= maxSlots)
            || others.reduce(0, { $0 + ($1.value.payload?.count ?? 0) }) + executingBytes + (payload?.count ?? 0) > maxBytes
            || others.reduce(0, { $0 + $1.key.byteCount }) + key.byteCount > maxKeyBytes {
            disabled.insert(key.namespace)
            // Namespace suppression replaces exact volatile state; queued payloads
            // are released and stale claimed commands cannot complete against it.
            slots = slots.filter { $0.key.namespace != key.namespace }
            scheduleLocked()
            lock.unlock()
            report(Notice(namespace: key.namespace, outcome: .capacity))
            return
        }
        slots[key] = Slot(token: UUID(), generation: generation, payload: payload,
                          isRemoval: removal, due: now())
        scheduleLocked()
        lock.unlock()
    }

    /// Called synchronously at promotion/revoke, including same-key re-pairing.
    /// An executing old mutation finishes before new writes on the serial owner.
    func invalidateDevice(_ deviceID: String, occurrence: UUID = UUID(), revoke: Bool = false) {
        lock.lock()
        guard !stopped, !closing else { lock.unlock(); return }
        if generations[deviceID] == nil && generations.count >= maxSlots {
            disabled.formUnion([.notifications, .sms]); slots.removeAll()
            lock.unlock(); report(Notice(namespace: .notifications, outcome: .capacity)); return
        }
        generations[deviceID] = occurrence
        revisions[deviceID, default: 0] &+= 1
        slots = slots.filter { $0.key.deviceID != deviceID }
        if revoke { revocations.insert(deviceID) }
        scheduleLocked()
        lock.unlock()
    }

    func restore(deviceID: String, completion: @escaping @Sendable (Restoration?) -> Void) {
        lock.lock()
        guard !stopped, !closing, restores[deviceID] == nil, restores.count < maxSlots, generations[deviceID] != nil || generations.count < maxSlots else { lock.unlock(); return }
        let token = RestoreToken(deviceID: deviceID, generation: generationLocked(deviceID), revision: revisions[deviceID, default: 0])
        restores[deviceID] = RestoreRequest(token: token, completion: completion)
        scheduleLocked()
        lock.unlock()
    }

    func isCurrent(_ token: RestoreToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentLocked(token)
    }

    func shouldRestore(_ key: Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && !disabled.contains(key.namespace) && slots[key] == nil
    }

    /// Close ingress synchronously, then settle admitted immediate disk work.
    /// Delayed retries never keep Quit alive. The deadline bounds unhealthy IO;
    /// reaching it reports uncertainty instead of claiming successful removal.
    func beginShutdown(timeout: TimeInterval = 2) -> ShutdownCompletion {
        lock.lock()
        guard !closing, !stopped else { lock.unlock(); return shutdownCompletion }
        closing = true
        timer?.cancel(); timer = nil
        restores.removeAll()
        for key in Array(slots.keys) where (slots[key]?.attempts ?? 0) > 0 {
            slots[key]?.due = nil
        }
        scheduleLocked()
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped else { self.lock.unlock(); return }
            var uncertain = Set(self.slots.keys.map(\.namespace))
            if let namespace = self.executingNamespace { uncertain.insert(namespace) }
            let revokePending = !self.revocations.isEmpty
            self.stopped = true; self.slots.removeAll(); self.revocations.removeAll()
            self.lock.unlock()
            for namespace in uncertain { self.report(Notice(namespace: namespace, outcome: .durabilityUnknown)) }
            if revokePending { self.report(Notice(namespace: .notifications, outcome: .durabilityUnknown)) }
            self.shutdownCompletion.finish()
        }
        return shutdownCompletion
    }

    private func generationLocked(_ deviceID: String) -> UUID {
        if let value = generations[deviceID] { return value }
        let value = UUID(); generations[deviceID] = value; return value
    }
    private func currentLocked(_ token: RestoreToken) -> Bool {
        !stopped && !closing && generations[token.deviceID] == token.generation && revisions[token.deviceID, default: 0] == token.revision
    }
    private func scheduleLocked() {
        guard automatic, !drainScheduled, !stopped else { return }
        drainScheduled = true
        queue.async { [weak self] in self?.drain() }
    }

    /// Internal deterministic test seam. Production uses only queue.async and
    /// one worker-wide timer; tests manually step this same production drain.
    func drain() {
        while true {
            lock.lock()
            guard !stopped else { drainScheduled = false; lock.unlock(); return }
            if let deviceID = revocations.first {
                revocations.remove(deviceID)
                executingNamespace = .notifications
                lock.unlock()
                do { try storage.revoke(deviceID) }
                catch { report(Notice(namespace: .notifications, outcome: .durabilityUnknown)) }
                lock.lock(); executingNamespace = nil; lock.unlock()
                continue
            }
            if let (key, claimed) = slots.first(where: { $0.value.due.map { $0 <= now() } ?? false }) {
                slots[key]?.due = nil // Claim linearizes before concurrent newer ingress.
                slots[key]?.payload = nil
                executingBytes = claimed.payload?.count ?? 0
                executingNamespace = key.namespace
                lock.unlock()
                let succeeded: Bool
                if claimed.isRemoval { succeeded = storage.remove(key, claimed.attempts == 0) }
                else {
                    do { try storage.put(key, claimed.payload ?? Data()); succeeded = true }
                    catch { succeeded = false }
                }
                lock.lock()
                executingBytes = 0
                executingNamespace = nil
                guard slots[key]?.token == claimed.token, generations[key.deviceID] == claimed.generation else {
                    lock.unlock(); continue
                }
                var notice: Notice?
                if succeeded {
                    slots.removeValue(forKey: key)
                    notice = Notice(namespace: key.namespace, outcome: .durable)
                } else if claimed.isRemoval {
                    var pending = claimed
                    pending.payload = nil
                    pending.attempts += 1
                    if !closing, claimed.attempts < retryDelays.count { pending.due = now() + retryDelays[claimed.attempts] }
                    else { pending.due = nil }
                    slots[key] = pending
                    if claimed.attempts == 0 { notice = Notice(namespace: key.namespace, outcome: .durabilityUnknown) }
                    if claimed.attempts == retryDelays.count { notice = Notice(namespace: key.namespace, outcome: .exhausted) }
                } else {
                    slots[key]?.payload = nil
                    notice = Notice(namespace: key.namespace, outcome: .durabilityUnknown)
                }
                lock.unlock()
                if let notice { report(notice) }
                continue
            }
            if let (deviceID, request) = restores.first {
                // Keep the request registered during I/O, coalescing more requests.
                guard currentLocked(request.token) else {
                    restores.removeValue(forKey: deviceID); lock.unlock(); request.completion(nil); continue
                }
                lock.unlock()
                var result: Restoration?
                do {
                    let notifications = try storage.contents(deviceID, .notifications)
                    let sms = try storage.contents(deviceID, .sms)
                    let clipboard = try storage.contents(deviceID, .clipboard)
                    lock.lock()
                    if currentLocked(request.token) {
                        let filter: (CachedContentRecord, Namespace) -> Bool = { record, namespace in
                            !self.disabled.contains(namespace) && self.slots[Key(deviceID: deviceID, namespace: namespace, itemID: record.itemID)] == nil
                        }
                        result = Restoration(token: request.token,
                            notifications: notifications.filter { filter($0, .notifications) },
                            sms: sms.filter { filter($0, .sms) }, clipboard: clipboard)
                    }
                    lock.unlock()
                } catch { report(Notice(namespace: .notifications, outcome: .durabilityUnknown)) }
                lock.lock(); restores.removeValue(forKey: deviceID); lock.unlock()
                request.completion(result)
                continue
            }
            drainScheduled = false
            if closing {
                stopped = true; slots.removeAll()
                lock.unlock(); shutdownCompletion.finish(); return
            }
            timer?.cancel(); timer = nil
            if automatic, let due = slots.values.compactMap(\.due).min() {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + max(0, due - now()))
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.timer?.cancel(); self.timer = nil
                    self.scheduleLocked(); self.lock.unlock()
                }
                self.timer = timer; timer.resume()
            }
            lock.unlock()
            return
        }
    }
}

/// Only accessed by the coordinator's serial queue. Cache/Keychain construction
/// and retries never run on MainActor; keyless removal never constructs a cache.
private final class ContentCacheWorkerStorage: @unchecked Sendable {
    private var cache: EncryptedContentCache?
    private var lastAttempt: TimeInterval?
    private func available() throws -> EncryptedContentCache {
        if let cache { return cache }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastAttempt, now - lastAttempt < 5 { throw CacheError.invalidKey }
        lastAttempt = now
        let value = try EncryptedContentCache(); cache = value; return value
    }
    var operations: ContentCacheMaintenanceCoordinator.Storage {
        .init(remove: { [self] key, initial in
            NotificationCacheRemovalAttempt.perform(
                live: initial ? cache.map { cache in { try cache.remove(deviceID: key.deviceID, namespace: key.namespace, itemID: key.itemID) } } : nil,
                keyless: { try EncryptedContentCache.removeStoredContent(deviceID: key.deviceID, namespace: key.namespace, itemID: key.itemID) })
        }, put: { [self] key, data in
            try available().put(deviceID: key.deviceID, namespace: key.namespace, itemID: key.itemID, payload: data)
        }, contents: { [self] device, namespace in
            try available().contents(deviceID: device, namespace: namespace)
        }, revoke: { device in _ = try EncryptedContentCache.revokeStoredContent(deviceID: device) })
    }
}
