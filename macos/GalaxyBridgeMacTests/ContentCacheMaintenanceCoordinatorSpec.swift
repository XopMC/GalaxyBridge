import Foundation

@main
enum ContentCacheMaintenanceCoordinatorSpec {
    typealias Owner = ContentCacheMaintenanceCoordinator
    enum Fault: Error { case unavailable }
    final class Fixture: @unchecked Sendable {
        var time: TimeInterval = 0
        var deletionSucceeds = false
        var writeFails = false
        var deletes: [Owner.Key] = []
        var writes: [Data] = []
        var notices: [Owner.Notice] = []
        var restoreResults: [Owner.Restoration?] = []
        var onDelete: (() -> Void)?
        var onContents: (() -> Void)?
        var disk: [Owner.Key: Data] = [:]
        var operations: Owner.Storage {
            .init(remove: { [self] key, _ in
                deletes.append(key); onDelete?()
                if deletionSucceeds { disk.removeValue(forKey: key) }
                return deletionSucceeds
            }, put: { [self] key, payload in
                writes.append(payload)
                if writeFails { throw Fault.unavailable }
                disk[key] = payload
            }, contents: { [self] device, namespace in
                onContents?()
                return disk.filter { $0.key.deviceID == device && $0.key.namespace == namespace }.map {
                    CachedContentRecord(itemID: $0.key.itemID, payload: $0.value, createdAt: Date(), expiresAt: .distantFuture)
                }
            }, revoke: { [self] device in disk = disk.filter { $0.key.deviceID != device } })
        }
        func owner(maxSlots: Int = 512, maxBytes: Int = 8 * 1024 * 1024) -> Owner {
            Owner(storage: operations, maxSlots: maxSlots, maxBytes: maxBytes, automatic: false,
                  now: { [self] in time }, report: { [self] in notices.append($0) })
        }
    }
    static let a = Owner.Key(deviceID: "fixture", namespace: .notifications, itemID: "A")
    static func main() async throws {
        try await gracefulShutdownPersistsAdmittedRemoval()
        await gracefulShutdownDrainsImmediateWorkOnly()
        try fallbackAndReconstruction()
        retryBudgetAndTruthfulness()
        supersessionAndTrust()
        backpressure()
        restoreFences()
        claimedDeleteThenNewWrite()
        print("PASS notification cache: fallback, reconstruction, bounded retries, supersession, trust, capacity, restore fences, concurrent claim ordering")
    }

    static func gracefulShutdownPersistsAdmittedRemoval() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-quit-\(UUID()).sqlite3")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let encryptionKey = Data(repeating: 0x5a, count: 32)
        let cache = try EncryptedContentCache(url: url, keyData: encryptionKey)
        try cache.put(deviceID: a.deviceID, namespace: a.namespace, itemID: a.itemID, payload: Data([1]))
        let storage = Owner.Storage(remove: { key, _ in
            NotificationCacheRemovalAttempt.perform(live: nil, keyless: {
                try EncryptedContentCache.removeStoredContent(deviceID: key.deviceID, namespace: key.namespace, itemID: key.itemID, url: url)
            })
        }, put: { key, data in try cache.put(deviceID: key.deviceID, namespace: key.namespace, itemID: key.itemID, payload: data) },
        contents: { device, ns in try cache.contents(deviceID: device, namespace: ns) }, revoke: { _ in })
        // Hold the production owner before its queued initial delete. Normal
        // Quit must close ingress without discarding this accepted operation.
        let owner = Owner(storage: storage, automatic: false)
        owner.remove(a)
        let completion = owner.beginShutdown()
        owner.store(a, payload: Data([9])) // post-shutdown admission is closed
        await Task.detached { owner.drain() }.value
        await completion.wait()
        let reopened = try EncryptedContentCache(url: url, keyData: encryptionKey)
        let value = try reopened.content(deviceID: a.deviceID, namespace: a.namespace, itemID: a.itemID)
        precondition(value == nil, "Normal Quit must persist the queued removal")
    }

    static func gracefulShutdownDrainsImmediateWorkOnly() async {
        let fixture = Fixture(); let owner = fixture.owner()
        let b = Owner.Key(deviceID: "other", namespace: .sms, itemID: "B")
        fixture.disk[a] = Data([1])
        owner.invalidateDevice(a.deviceID, revoke: true)
        owner.store(b, payload: Data([2]))
        let completion = owner.beginShutdown()
        await Task.detached { owner.drain() }.value
        await completion.wait()
        precondition(fixture.disk[a] == nil && fixture.disk[b] == Data([2]))

        let retries = Fixture(); let retryOwner = retries.owner()
        retryOwner.remove(a); retryOwner.drain()
        let retryCompletion = retryOwner.beginShutdown()
        retryOwner.drain(); await retryCompletion.wait()
        precondition(retries.deletes.count == 1, "Future retries must not delay Quit")

        let stalled = Fixture(); let stalledOwner = stalled.owner()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        stalled.onDelete = { entered.signal(); release.wait() }
        stalledOwner.remove(a)
        let worker = Task.detached { stalledOwner.drain() }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        let bounded = stalledOwner.beginShutdown(timeout: 0.02)
        await bounded.wait() // Deadline settles without waiting for blocked IO.
        release.signal(); await worker.value
        precondition(stalled.notices.contains(where: { $0.outcome == .durabilityUnknown }))
    }

    static func fallbackAndReconstruction() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cache-regression-\(UUID()).sqlite3")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let encryptionKey = Data(repeating: 0x5a, count: 32)
        let cache = try EncryptedContentCache(url: url, keyData: encryptionKey)
        try cache.put(deviceID: a.deviceID, namespace: a.namespace, itemID: a.itemID, payload: Data([1]))
        var fallbackCalls = 0
        let success = NotificationCacheRemovalAttempt.perform(live: { throw Fault.unavailable }, keyless: {
            fallbackCalls += 1
            return try EncryptedContentCache.removeStoredContent(deviceID: a.deviceID, namespace: a.namespace, itemID: a.itemID, url: url)
        })
        let reopened = try EncryptedContentCache(url: url, keyData: encryptionKey)
        precondition(success && fallbackCalls == 1)
        let removed = try reopened.content(deviceID: a.deviceID, namespace: a.namespace, itemID: a.itemID)
        precondition(removed == nil)
        precondition(NotificationCacheRemovalAttempt.perform(live: { 0 }, keyless: { preconditionFailure("Zero is durable success") }))
        precondition(!NotificationCacheRemovalAttempt.perform(live: nil, keyless: { throw Fault.unavailable }))

        let fixture = Fixture()
        let storage = Owner.Storage(remove: { key, initial in
            NotificationCacheRemovalAttempt.perform(live: nil, keyless: {
                if !fixture.deletionSucceeds { throw Fault.unavailable }
                return try EncryptedContentCache.removeStoredContent(deviceID: key.deviceID, namespace: key.namespace, itemID: key.itemID, url: url)
            })
        }, put: { key, data in try cache.put(deviceID: key.deviceID, namespace: key.namespace, itemID: key.itemID, payload: data) },
        contents: { device, ns in try cache.contents(deviceID: device, namespace: ns) }, revoke: { _ in })
        try cache.put(deviceID: a.deviceID, namespace: a.namespace, itemID: a.itemID, payload: Data([2]))
        let owner = Owner(storage: storage, automatic: false, now: { fixture.time }, report: { fixture.notices.append($0) })
        owner.remove(a); owner.drain()
        precondition(!owner.shouldRestore(a))
        // A process crash after total failure leaves the old row. No volatile
        // suppression is misrepresented as a committed deletion.
        let unchanged = try reopened.content(deviceID: a.deviceID, namespace: a.namespace, itemID: a.itemID)
        precondition(unchanged != nil)
        precondition(fixture.notices.map(\.outcome) == [.durabilityUnknown])
        fixture.deletionSucceeds = true; fixture.time = 1; owner.drain()
        let reconstructed = try EncryptedContentCache(url: url, keyData: encryptionKey)
        let committed = try reconstructed.content(deviceID: a.deviceID, namespace: a.namespace, itemID: a.itemID)
        precondition(committed == nil)
        precondition(fixture.notices.last?.outcome == .durable)
    }

    static func retryBudgetAndTruthfulness() {
        let fixture = Fixture(); let owner = fixture.owner()
        owner.remove(a); owner.drain()
        for delay in [1.0, 2, 5, 10, 30] {
            owner.remove(a) // duplicate never resets budget
            fixture.time += delay; owner.drain()
        }
        precondition(fixture.deletes.count == 6)
        precondition(fixture.notices.map(\.outcome) == [.durabilityUnknown, .exhausted])
        fixture.time += 1000; owner.remove(a); owner.drain()
        precondition(fixture.deletes.count == 6 && !owner.shouldRestore(a))
        _ = owner.beginShutdown(); owner.drain()
        precondition(fixture.deletes.count == 6)
    }

    static func supersessionAndTrust() {
        for failedWrite in [false, true] {
            let fixture = Fixture(); let owner = fixture.owner()
            owner.remove(a); owner.drain()
            fixture.writeFails = failedWrite
            owner.store(a, payload: Data([9])); owner.drain()
            fixture.time = 100; owner.drain() // stale worker-wide timer wake
            precondition(fixture.deletes.count == 1 && fixture.writes == [Data([9])])
            precondition(owner.shouldRestore(a) == !failedWrite)
            owner.remove(a); owner.drain()
            fixture.time += 1; owner.drain()
            precondition(fixture.deletes.count == 3) // C owns a fresh budget
        }
        let fixture = Fixture(); let owner = fixture.owner()
        owner.remove(a) // superseded before claimed: no disk delete at all
        owner.store(a, payload: Data([3])); owner.drain()
        precondition(fixture.deletes.isEmpty && fixture.disk[a] == Data([3]))
        owner.remove(a); owner.drain()
        owner.invalidateDevice(a.deviceID, occurrence: UUID())
        owner.invalidateDevice(a.deviceID, occurrence: UUID()) // same metadata, distinct promotion
        owner.store(a, payload: Data([4])); fixture.time = 100; owner.drain()
        precondition(fixture.deletes.count == 1 && fixture.disk[a] == Data([4]))
        let other = Owner.Key(deviceID: "other", namespace: .notifications, itemID: a.itemID)
        owner.remove(a); owner.store(other, payload: Data([7])); owner.drain()
        precondition(fixture.disk[other] == Data([7]))
        owner.invalidateDevice(a.deviceID, revoke: true)
        owner.store(a, payload: Data([8])); owner.drain()
        precondition(fixture.disk[a] == Data([8]) && fixture.disk[other] == Data([7]))
    }

    static func backpressure() {
        let fixture = Fixture(); let owner = fixture.owner(maxSlots: 2, maxBytes: 4)
        owner.store(a, payload: Data([1, 2, 3, 4, 5]))
        for index in 0..<1000 {
            owner.store(.init(deviceID: "fixture", namespace: .notifications, itemID: "\(index)"), payload: Data([1]))
        }
        owner.drain()
        precondition(fixture.writes.isEmpty && fixture.notices.map(\.outcome) == [.capacity])
        precondition(!owner.shouldRestore(a))
        let slots = Fixture(); let slotOwner = slots.owner(maxSlots: 2)
        for index in 0..<1000 { slotOwner.remove(.init(deviceID: "fixture", namespace: .notifications, itemID: "\(index)")) }
        slotOwner.drain()
        precondition(slots.deletes.isEmpty && slots.notices.map(\.outcome) == [.capacity])
    }

    static func restoreFences() {
        let fixture = Fixture(); let owner = fixture.owner()
        fixture.disk[a] = Data([1])
        owner.restore(deviceID: a.deviceID) { fixture.restoreResults.append($0) }
        owner.store(a, payload: Data([2])); owner.drain()
        precondition(fixture.restoreResults.count == 1 && fixture.restoreResults[0] == nil)
        owner.restore(deviceID: a.deviceID) { fixture.restoreResults.append($0) }; owner.drain()
        let result = fixture.restoreResults.last!!
        precondition(result.notifications.first?.payload == Data([2]) && owner.isCurrent(result.token))
        owner.remove(a)
        precondition(!owner.isCurrent(result.token)) // callback already queued for UI
        owner.drain()
        owner.restore(deviceID: a.deviceID) { fixture.restoreResults.append($0) }; owner.drain()
        precondition(fixture.restoreResults.last!!.notifications.isEmpty)
        owner.invalidateDevice(a.deviceID)
        precondition(!owner.isCurrent(result.token))
        // Admit a newer event inside a held enumeration, before candidate delivery.
        fixture.onContents = { owner.store(a, payload: Data([4])) }
        owner.restore(deviceID: a.deviceID) { fixture.restoreResults.append($0) }; owner.drain()
        precondition(fixture.restoreResults.last! == nil && fixture.disk[a] == Data([4]))
    }

    static func claimedDeleteThenNewWrite() {
        let fixture = Fixture(); let owner = fixture.owner()
        let claimed = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        fixture.deletionSucceeds = true
        fixture.onDelete = {
            precondition(!Thread.isMainThread)
            claimed.signal(); precondition(release.wait(timeout: .now() + 5) == .success)
        }
        owner.remove(a)
        DispatchQueue.global().async { owner.drain(); done.signal() }
        precondition(claimed.wait(timeout: .now() + 5) == .success)
        owner.invalidateDevice(a.deviceID, occurrence: UUID())
        owner.store(a, payload: Data([5]))
        release.signal(); precondition(done.wait(timeout: .now() + 5) == .success)
        precondition(fixture.disk[a] == Data([5]))
        precondition(fixture.notices.map(\.outcome) == [.durable]) // only B's completion
    }
}
