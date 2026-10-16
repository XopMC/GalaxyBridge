import Foundation

struct NotificationActionIdentity: Hashable, Sendable {
    let deviceID: String
    let notificationID: String
    let actionID: String
    // Local draft identity only; never sent on the wire.
    let composeID: String

    init(deviceID: String, notificationID: String, actionID: String, composeID: String = "") {
        self.deviceID = deviceID
        self.notificationID = notificationID
        self.actionID = actionID
        self.composeID = composeID
    }
}

enum NotificationActionPhase: Equatable, Sendable {
    case idle, pending, accepted, failed, unknown, legacy
}

struct NotificationActionEntry: Equatable, Sendable {
    var draft = ""
    var draftRevision: UInt64 = 0
    var phase: NotificationActionPhase = .idle
    var errorCode = ""
}

struct PendingNotificationAction: Equatable, Sendable {
    let requestID: String
    let identity: NotificationActionIdentity
    let companionID: String
    let generation: UInt64
    let sentDraft: String
    let draftRevision: UInt64
}

/// In-memory drafts and one-shot requests. Never retries or persists reply content to disk.
struct NotificationActionState: Sendable {
    private(set) var entries: [NotificationActionIdentity: NotificationActionEntry] = [:]
    private(set) var pending: [String: PendingNotificationAction] = [:]
    private var orphanDeadlines: [NotificationActionIdentity: TimeInterval] = [:]
    static let orphanRetention: TimeInterval = 600
    private let maximumEntries = 512
    private let maximumPending = 32

    func entry(_ identity: NotificationActionIdentity) -> NotificationActionEntry {
        entries[identity] ?? NotificationActionEntry()
    }

    @discardableResult
    mutating func setDraft(_ draft: String, for identity: NotificationActionIdentity) -> Bool {
        guard entries[identity] != nil || makeRoom() else { return false }
        var value = entry(identity)
        if value.draft != draft {
            value.draftRevision += 1
            value.draft = draft
        }
        entries[identity] = value
        pruneEmptyOrphan(identity)
        return true
    }

    mutating func begin(identity: NotificationActionIdentity, companionID: String, generation: UInt64,
                        requestID: String, draft: String, supportsResults: Bool) -> PendingNotificationAction? {
        guard !pending.values.contains(where: { $0.identity.deviceID == identity.deviceID && $0.identity.notificationID == identity.notificationID }),
              pending.count < maximumPending,
              pending[requestID] == nil, entries[identity] != nil || makeRoom() else { return nil }
        var value = entry(identity)
        if value.draft != draft {
            value.draftRevision += 1
            value.draft = draft
        }
        let request = PendingNotificationAction(requestID: requestID, identity: identity,
            companionID: companionID, generation: generation, sentDraft: draft, draftRevision: value.draftRevision)
        value.phase = supportsResults ? .pending : .legacy
        value.errorCode = ""
        entries[identity] = value
        if supportsResults { pending[requestID] = request }
        return request
    }

    @discardableResult
    mutating func resolve(requestID: String, notificationID: String, actionID: String,
                          companionID: String, generation: UInt64, accepted: Bool, errorCode: String) -> Bool {
        guard let request = pending[requestID], request.companionID == companionID,
              request.generation == generation, request.identity.notificationID == notificationID,
              request.identity.actionID == actionID,
              accepted ? errorCode.isEmpty : !errorCode.isEmpty else { return false }
        pending.removeValue(forKey: requestID)
        var value = entry(request.identity)
        value.phase = accepted ? .accepted : .failed
        value.errorCode = errorCode
        // Do not erase a newer draft typed while waiting for the phone.
        if accepted && value.draftRevision == request.draftRevision && value.draft == request.sentDraft {
            if !value.draft.isEmpty { value.draftRevision += 1 }
            value.draft = ""
        }
        entries[request.identity] = value
        pruneEmptyOrphan(request.identity)
        return true
    }

    @discardableResult
    mutating func fail(requestID: String, unknown: Bool) -> Bool {
        guard let request = pending.removeValue(forKey: requestID) else { return false }
        var value = entry(request.identity)
        value.phase = unknown ? .unknown : .failed
        entries[request.identity] = value
        pruneEmptyOrphan(request.identity)
        return true
    }

    mutating func disconnect(companionID: String, generation: UInt64) -> [String] {
        let ids = pending.values.filter { $0.companionID == companionID && $0.generation == generation }.map(\.requestID)
        ids.forEach { _ = fail(requestID: $0, unknown: true) }
        return ids
    }

    mutating func forget(deviceID: String) {
        entries = entries.filter { $0.key.deviceID != deviceID }
        pending = pending.filter { $0.value.identity.deviceID != deviceID }
        orphanDeadlines = orphanDeadlines.filter { $0.key.deviceID != deviceID }
    }

    mutating func localFailure(identity: NotificationActionIdentity) {
        var value = entry(identity)
        value.phase = .failed
        entries[identity] = value
    }

    mutating func observe(deviceID: String, notificationID: String, removed: Bool, now: TimeInterval) {
        let identities = entries.keys.filter { $0.deviceID == deviceID && $0.notificationID == notificationID }
        for identity in identities {
            if removed {
                if orphanDeadlines[identity] == nil { orphanDeadlines[identity] = now + Self.orphanRetention }
                pruneEmptyOrphan(identity)
            } else { orphanDeadlines.removeValue(forKey: identity) }
        }
    }

    mutating func reconcile(deviceID: String, activeNotificationIDs: Set<String>, now: TimeInterval) {
        let ids = Set(entries.keys.filter { $0.deviceID == deviceID }.map(\.notificationID))
        for id in ids { observe(deviceID: deviceID, notificationID: id, removed: !activeNotificationIDs.contains(id), now: now) }
    }

    mutating func expireOrphans(now: TimeInterval) {
        for (identity, deadline) in orphanDeadlines where deadline <= now && entry(identity).phase != .pending {
            entries.removeValue(forKey: identity)
            orphanDeadlines.removeValue(forKey: identity)
        }
    }

    var nextOrphanDeadline: TimeInterval? {
        orphanDeadlines.filter { entry($0.key).phase != .pending }.values.min()
    }

    func isOrphan(_ identity: NotificationActionIdentity) -> Bool { orphanDeadlines[identity] != nil }

    private mutating func pruneEmptyOrphan(_ identity: NotificationActionIdentity) {
        if orphanDeadlines[identity] != nil && entry(identity).draft.isEmpty && entry(identity).phase != .pending {
            entries.removeValue(forKey: identity)
            orphanDeadlines.removeValue(forKey: identity)
        }
    }

    private mutating func makeRoom() -> Bool {
        if entries.count < maximumEntries { return true }
        if let key = entries.first(where: { $0.value.draft.isEmpty && $0.value.phase != .pending })?.key {
            entries.removeValue(forKey: key)
            orphanDeadlines.removeValue(forKey: key)
            return true
        }
        return false
    }
}
