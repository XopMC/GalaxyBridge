import CryptoKit
import Foundation

private final class IncomingBoundaryBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    private var calls = 0
    var hitCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func stopOnce() {
        lock.lock()
        calls += 1
        if used { lock.unlock(); return }
        used = true; lock.unlock()
        entered.signal()
        precondition(resume.wait(timeout: .now() + 15) == .success, "Boundary test must resume")
    }
    func wait() { precondition(entered.wait(timeout: .now() + 15) == .success, "Boundary must be reached") }
    func release() { resume.signal() }
}

@main struct IncomingFileTransferStoreSpec {
    static func main() async throws {
        let downloads = FileManager.default.temporaryDirectory.appendingPathComponent("gb-incoming-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: downloads) }
        let owner = IncomingFileOwner(deviceID: "device:" + UUID().uuidString.lowercased(), fingerprint: Data(repeating: 7, count: 32))
        let profile = "Fixture"
        func store() -> IncomingFileTransferStore { IncomingFileTransferStore(downloads: downloads, profile: profile) }
        func manifest(_ name: String, _ data: Data) -> IncomingFileManifest {
            IncomingFileManifest(id: UUID().uuidString.lowercased(), name: name,
                size: UInt64(data.count), sha256: Data(SHA256.hash(data: data)))
        }
        func stage(_ id: String) -> URL {
            downloads.appendingPathComponent(".Fixture-Incoming").appendingPathComponent(owner.storageKey).appendingPathComponent(id)
        }
        let payload = Data((0..<200_019).map { UInt8($0 % 251) })
        let m = manifest("sample.bin", payload)
        func verifyOriginal() throws {
            let actual = try Data(contentsOf: downloads.appendingPathComponent(m.name))
            precondition(actual == payload)
        }
        let receiver = store()
        var r = await receiver.manifest(owner: owner, manifest: m)
        precondition(r.offset == 0 && r.failureReason.isEmpty && !r.complete)
        r = await receiver.chunk(owner: owner, id: m.id, offset: 0, bytes: payload.prefix(100_000))
        precondition(r.offset == 100_000 && r.failureReason.isEmpty)
        r = await receiver.chunk(owner: owner, id: m.id, offset: 0, bytes: payload.prefix(100_000))
        precondition(r.offset == 100_000 && r.failureReason.isEmpty, "Repeated chunk must be idempotent")
        r = await receiver.chunk(owner: owner, id: m.id, offset: 0, bytes: Data(repeating: 0, count: 100))
        precondition(r.failureReason == "conflicting_duplicate")
        await receiver.shutdown()
        // A process can die after writing bytes but before checkpointing them.
        let handle = try FileHandle(forWritingTo: stage(m.id).appendingPathComponent("payload"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 99, count: 81)); try handle.close()
        let restarted = store()
        r = await restarted.manifest(owner: owner, manifest: m)
        precondition(r.offset == 100_000 && r.failureReason.isEmpty)
        let restoredSize = try FileManager.default.attributesOfItem(atPath: stage(m.id).appendingPathComponent("payload").path)[.size] as! NSNumber
        precondition(restoredSize.intValue == 100_000)
        r = await restarted.chunk(owner: owner, id: m.id, offset: 100_000, bytes: payload.dropFirst(100_000))
        precondition(r.complete && r.offset == UInt64(payload.count) && r.publishedName == m.name)
        try verifyOriginal()
        r = await store().manifest(owner: owner, manifest: m)
        precondition(r.complete, "Lost final ACK must recover its receipt")
        r = await restarted.cancel(owner: owner, id: m.id)
        precondition(r.complete && FileManager.default.fileExists(atPath: downloads.appendingPathComponent(m.name).path))
        let collision = manifest(m.name, Data("second content".utf8))
        _ = await restarted.manifest(owner: owner, manifest: collision)
        r = await restarted.chunk(owner: owner, id: collision.id, offset: 0, bytes: Data("second content".utf8))
        precondition(r.complete && r.publishedName == "sample (1).bin")
        try verifyOriginal()
        print("PASS actual filesystem checkpoint/restart/tail truncation, duplicates, final ACK replay and collision-safe publication")

        let early = manifest("cancel.bin", payload)
        r = await restarted.cancel(owner: owner, id: early.id)
        precondition(r.failureReason == "transfer_cancelled")
        r = await restarted.manifest(owner: owner, manifest: early)
        precondition(r.failureReason == "transfer_cancelled")
        r = await restarted.chunk(owner: owner, id: early.id, offset: 0, bytes: payload.prefix(10))
        precondition(r.failureReason == "transfer_cancelled")
        let cancelled = manifest("pending.bin", payload)
        _ = await restarted.manifest(owner: owner, manifest: cancelled)
        _ = await restarted.chunk(owner: owner, id: cancelled.id, offset: 0, bytes: payload.prefix(100))
        r = await restarted.cancel(owner: owner, id: cancelled.id)
        precondition(r.failureReason == "transfer_cancelled")
        precondition(!FileManager.default.fileExists(atPath: stage(cancelled.id).appendingPathComponent("payload").path))
        r = await store().manifest(owner: owner, manifest: cancelled)
        precondition(r.failureReason == "transfer_cancelled")
        let stranger = IncomingFileOwner(deviceID: owner.deviceID, fingerprint: Data(repeating: 8, count: 32))
        r = await restarted.chunk(owner: stranger, id: m.id, offset: 0, bytes: payload.prefix(10))
        precondition(!r.complete && r.failureReason == "unknown_transfer")
        let empty = manifest("empty.dat", Data())
        r = await restarted.manifest(owner: owner, manifest: empty)
        precondition(r.complete && r.offset == 0)
        print("PASS durable early/partial cancel, late publication wins, exact owner and zero-byte file")

        let corrupt = manifest("corrupt.bin", payload)
        _ = await restarted.manifest(owner: owner, manifest: corrupt)
        _ = await restarted.chunk(owner: owner, id: corrupt.id, offset: 0, bytes: payload.prefix(20))
        try Data(repeating: 3, count: 20).write(to: stage(corrupt.id).appendingPathComponent("payload"))
        r = await store().manifest(owner: owner, manifest: corrupt)
        precondition(r.failureReason == "checkpoint_prefix_mismatch" || r.failureReason == "transfer_document_missing")
        let unsafe = IncomingFileManifest(id: UUID().uuidString.lowercased(), name: "../outside", size: 0, sha256: Data(SHA256.hash(data: Data())))
        r = await restarted.manifest(owner: owner, manifest: unsafe)
        precondition(r.failureReason == "invalid_manifest")
        let symlinked = manifest("link.bin", payload)
        _ = await restarted.manifest(owner: owner, manifest: symlinked)
        let stagePayload = stage(symlinked.id).appendingPathComponent("payload")
        try FileManager.default.removeItem(at: stagePayload)
        try FileManager.default.createSymbolicLink(at: stagePayload, withDestinationURL: downloads.appendingPathComponent(m.name))
        r = await restarted.chunk(owner: owner, id: symlinked.id, offset: 0, bytes: payload.prefix(10))
        precondition(!r.failureReason.isEmpty)
        try verifyOriginal()
        print("PASS damaged checkpoint, traversal and replaced/symlink payload cannot publish or overwrite another file")

        let inPlace = manifest("in-place.bin", payload)
        let sameProcess = store()
        _ = await sameProcess.manifest(owner: owner, manifest: inPlace)
        _ = await sameProcess.chunk(owner: owner, id: inPlace.id, offset: 0, bytes: payload.prefix(100))
        let modified = try FileHandle(forWritingTo: stage(inPlace.id).appendingPathComponent("payload"))
        try modified.write(contentsOf: Data([255])); try modified.close()
        r = await sameProcess.chunk(owner: owner, id: inPlace.id, offset: 100, bytes: payload.dropFirst(100))
        precondition(!r.complete && r.failureReason == "checkpoint_prefix_mismatch")
        precondition(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent(inPlace.name).path))
        print("PASS final full-file hash detects in-place corruption of an acknowledged prefix in the same process")

        // Simulate a crash after link publication but before its completion receipt.
        let publishing = manifest("publishing.bin", Data("publish crash".utf8))
        _ = await restarted.manifest(owner: owner, manifest: publishing)
        let bytes = Data("publish crash".utf8)
        let staged = stage(publishing.id).appendingPathComponent("payload")
        let file = try FileHandle(forWritingTo: staged); try file.write(contentsOf: bytes); try file.synchronize(); try file.close()
        let recordURL = stage(publishing.id).appendingPathComponent("record.json")
        var record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
        record["offset"] = bytes.count; record["prefixHash"] = Data(SHA256.hash(data: bytes)).base64EncodedString()
        record["phase"] = "publishing"; record["publishedName"] = publishing.name
        try JSONSerialization.data(withJSONObject: record).write(to: recordURL, options: .atomic)
        try FileManager.default.linkItem(at: staged, to: downloads.appendingPathComponent(publishing.name))
        r = await store().manifest(owner: owner, manifest: publishing)
        precondition(r.complete && r.publishedName == publishing.name)
        precondition(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent("publishing (1).bin").path))
        print("PASS post-link crash recovers the exact published inode without a duplicate file")

        let appended = manifest("user-appended.bin", bytes)
        _ = await restarted.manifest(owner: owner, manifest: appended)
        let appendedStage = stage(appended.id).appendingPathComponent("payload")
        let beforeLink = try FileHandle(forWritingTo: appendedStage)
        try beforeLink.write(contentsOf: bytes); try beforeLink.close()
        let appendedRecordURL = stage(appended.id).appendingPathComponent("record.json")
        var appendedRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: appendedRecordURL)) as! [String: Any]
        appendedRecord["offset"] = bytes.count
        appendedRecord["prefixHash"] = Data(SHA256.hash(data: bytes)).base64EncodedString()
        appendedRecord["phase"] = "publishing"; appendedRecord["publishedName"] = appended.name
        try JSONSerialization.data(withJSONObject: appendedRecord).write(to: appendedRecordURL, options: .atomic)
        let visible = downloads.appendingPathComponent(appended.name)
        try FileManager.default.linkItem(at: appendedStage, to: visible)
        let userEdit = try FileHandle(forWritingTo: visible)
        try userEdit.seekToEnd(); try userEdit.write(contentsOf: Data(" user tail".utf8)); try userEdit.close()
        r = await store().manifest(owner: owner, manifest: appended)
        precondition(!r.complete && r.failureReason == "checkpoint_prefix_mismatch")
        let preserved = try Data(contentsOf: visible)
        precondition(preserved == bytes + Data(" user tail".utf8))
        print("PASS publishing recovery cannot truncate a user-visible file after a post-link crash")

        let intent = manifest("unpublished-intent.bin", bytes)
        _ = await restarted.manifest(owner: owner, manifest: intent)
        let intentStage = stage(intent.id).appendingPathComponent("payload")
        let intentHandle = try FileHandle(forWritingTo: intentStage)
        try intentHandle.write(contentsOf: bytes); try intentHandle.close()
        let intentURL = stage(intent.id).appendingPathComponent("record.json")
        var intentRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: intentURL)) as! [String: Any]
        intentRecord["offset"] = bytes.count; intentRecord["prefixHash"] = Data(SHA256.hash(data: bytes)).base64EncodedString()
        intentRecord["phase"] = "publishing"; intentRecord["publishedName"] = intent.name
        try JSONSerialization.data(withJSONObject: intentRecord).write(to: intentURL, options: .atomic)
        r = await store().cancel(owner: owner, id: intent.id)
        precondition(r.failureReason == "transfer_cancelled" && !r.complete)
        precondition(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent(intent.name).path))
        print("PASS cancellation after a pre-link crash does not publish the cancelled file")

        let falseComplete = manifest("false-complete.bin", payload)
        _ = await restarted.manifest(owner: owner, manifest: falseComplete)
        let falseRecordURL = stage(falseComplete.id).appendingPathComponent("record.json")
        var falseRecord = try JSONSerialization.jsonObject(with: Data(contentsOf: falseRecordURL)) as! [String: Any]
        falseRecord["phase"] = "complete"
        try JSONSerialization.data(withJSONObject: falseRecord).write(to: falseRecordURL, options: .atomic)
        r = await store().manifest(owner: owner, manifest: falseComplete)
        precondition(!r.complete && r.failureReason == "checkpoint_unavailable")
        print("PASS corrupt phase cannot manufacture a complete receipt")

        let limitedRoot = downloads.appendingPathComponent("capacity")
        try FileManager.default.createDirectory(at: limitedRoot, withIntermediateDirectories: true)
        let limited = IncomingFileTransferStore(downloads: limitedRoot, profile: profile)
        var active: [IncomingFileManifest] = []
        for index in 0..<8 {
            let value = manifest("active-\(index).bin", payload); active.append(value)
            r = await limited.manifest(owner: owner, manifest: value)
            precondition(r.failureReason.isEmpty)
        }
        let ninth = manifest("ninth.bin", payload)
        r = await limited.manifest(owner: owner, manifest: ninth)
        precondition(r.failureReason == "transfer_capacity_exceeded")
        _ = await limited.cancel(owner: owner, id: active[0].id)
        r = await limited.manifest(owner: owner, manifest: ninth)
        precondition(r.failureReason.isEmpty)
        print("PASS eight active transfers are bounded and cancellation releases capacity")

        try await restarted.revoke(owner: owner)
        r = await restarted.manifest(owner: owner, manifest: m)
        precondition(r.failureReason == "owner_revoked" && !r.complete)
        try verifyOriginal()
        precondition(!FileManager.default.fileExists(atPath: stage(m.id).deletingLastPathComponent().path))
        print("PASS revocation removes only private staging/receipts and fences already-queued old-owner work")

        // Deterministic requests from outside the actor while real file hashing
        // or publication is in progress. No terminal ACK may precede the journal.
        for scenario in ["hash-cancel", "hash-revoke", "prelink-cancel", "postlink-cancel"] {
            let raceRoot = downloads.appendingPathComponent(scenario)
            try FileManager.default.createDirectory(at: raceRoot, withIntermediateDirectories: true)
            let barrier = IncomingBoundaryBarrier()
            let racePayload = scenario.hasPrefix("hash-") ? Data(repeating: 71, count: 2 * 1024 * 1024 + 37) : payload
            let raceManifest = manifest("race.bin", racePayload)
            let raceStore = IncomingFileTransferStore(downloads: raceRoot, profile: profile) { event in
                switch event {
                case .hashedChunk(let id) where id == raceManifest.id && scenario.hasPrefix("hash-"):
                    barrier.stopOnce()
                case .beforePublication(let id) where id == raceManifest.id && scenario == "prelink-cancel":
                    barrier.stopOnce()
                case .didPublish(let id) where id == raceManifest.id && scenario == "postlink-cancel":
                    barrier.stopOnce()
                default: break
                }
            }
            _ = await raceStore.manifest(owner: owner, manifest: raceManifest)
            var finalOffset = 0
            while racePayload.count - finalOffset > 1024 * 1024 {
                let chunk = racePayload.subdata(in: finalOffset..<(finalOffset + 1024 * 1024))
                let partial = await raceStore.chunk(owner: owner, id: raceManifest.id, offset: UInt64(finalOffset), bytes: chunk)
                precondition(partial.failureReason.isEmpty && !partial.complete)
                finalOffset += chunk.count
            }
            let remaining = racePayload.subdata(in: finalOffset..<racePayload.count), offset = UInt64(finalOffset)
            let completing = Task.detached { await raceStore.chunk(owner: owner, id: raceManifest.id, offset: offset, bytes: remaining) }
            await Task.detached { barrier.wait() }.value
            if scenario == "hash-revoke" { raceStore.requestRevocation(owner: owner) }
            else { raceStore.requestCancellation(owner: owner, id: raceManifest.id) }
            barrier.release()
            let result = await completing.value
            precondition(barrier.hitCount == 1, "A hash fence stops before reading the next MiB")
            let destination = raceRoot.appendingPathComponent(raceManifest.name)
            if scenario == "postlink-cancel" {
                precondition(result.complete && result.publishedNow)
                let cancelled = await raceStore.cancel(owner: owner, id: raceManifest.id)
                precondition(cancelled.complete)
                let publishedBytes = try Data(contentsOf: destination)
                precondition(publishedBytes == racePayload)
            } else {
                precondition(!result.complete && !FileManager.default.fileExists(atPath: destination.path))
                let recordURL = raceRoot.appendingPathComponent(".Fixture-Incoming")
                    .appendingPathComponent(owner.storageKey).appendingPathComponent(raceManifest.id).appendingPathComponent("record.json")
                let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as! [String: Any]
                precondition(journal["phase"] as? String != "cancelled", "A fence is not a durable tombstone")
                if scenario == "hash-revoke" {
                    precondition(result.failureReason == "owner_revocation_pending")
                    try await raceStore.revoke(owner: owner)
                    let rejected = await raceStore.manifest(owner: owner, manifest: raceManifest)
                    precondition(rejected.failureReason == "owner_revoked")
                } else {
                    precondition(result.failureReason == "transfer_cancel_pending")
                    let cancelled = await raceStore.cancel(owner: owner, id: raceManifest.id)
                    precondition(cancelled.failureReason == "transfer_cancelled")
                    let replay = await IncomingFileTransferStore(downloads: raceRoot, profile: profile)
                        .manifest(owner: owner, manifest: raceManifest)
                    precondition(replay.failureReason == "transfer_cancelled")
                }
            }
        }
        print("PASS cancellation/revocation during real hash and before link prevent publication; only durable cancellation is terminal; post-link publication wins")

        let namesRoot = downloads.appendingPathComponent("names")
        try FileManager.default.createDirectory(at: namesRoot, withIntermediateDirectories: true)
        let namesStore = IncomingFileTransferStore(downloads: namesRoot, profile: profile)
        let names = [".hidden", String(repeating: "a", count: 251) + ".txt",
                     String(repeating: "界", count: 83) + ".txt", "x." + String(repeating: "a", count: 253)]
        for name in names {
            let original = manifest(name, Data())
            let first = await namesStore.manifest(owner: owner, manifest: original)
            precondition(first.complete && first.publishedName == name)
            let second = await namesStore.manifest(owner: owner, manifest: manifest(name, Data()))
            precondition(second.complete && second.publishedName != name && second.publishedName.utf8.count <= 255)
            precondition(second.publishedName.contains(" (1)"))
            let third = await namesStore.manifest(owner: owner, manifest: manifest(name, Data()))
            precondition(third.complete && third.publishedName.contains(" (2)"))
        }
        for name in [".", "..", " ", "a/b", "a\\b", String(repeating: "a", count: 256)] {
            let invalid = await namesStore.manifest(owner: owner, manifest: manifest(name, Data()))
            precondition(invalid.failureReason == "invalid_manifest")
        }
        for name in [".Fixture-Incoming", ".GalaxyBridge-Incoming", ".GalaxyBridgeInternal-Incoming"] {
            let reserved = await namesStore.manifest(owner: owner, manifest: manifest(name, Data()))
            precondition(reserved.complete && reserved.publishedName != name)
        }
        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: namesRoot.appendingPathComponent(".Fixture-Incoming").path, isDirectory: &isDirectory) && isDirectory.boolValue)
        // Identical UUIDs remain independent when a different trust owner is cancelled.
        let scoped = manifest("owner.bin", payload)
        _ = await namesStore.manifest(owner: owner, manifest: scoped)
        namesStore.requestCancellation(owner: stranger, id: scoped.id)
        let unaffected = await namesStore.chunk(owner: owner, id: scoped.id, offset: 0, bytes: payload)
        precondition(unaffected.complete)
        print("PASS dotfiles/255-byte names, Unicode/long-extension collision truncation, reserved private root and exact-owner fences")

        let gate = CompanionFileIngressGate()
        for _ in 0..<8 { precondition(gate.admit(bytes: 1024 * 1024)) }
        precondition(!gate.admit(bytes: 1))
        precondition(gate.shouldReportRejection() && !gate.shouldReportRejection())
        for _ in 0..<8 { gate.finish(bytes: 1024 * 1024) }
        precondition(!gate.admit(bytes: 0), "Overload remains closed until a new socket generation")
        let messages = CompanionFileIngressGate()
        for _ in 0..<16 { precondition(messages.admit(bytes: 0)) }
        precondition(!messages.admit(bytes: 0))
        print("PASS pre-main-actor admission bounds bytes/tasks and reports overload exactly once")
    }
}
