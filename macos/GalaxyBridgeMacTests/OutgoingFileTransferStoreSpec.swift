import CryptoKit
import Darwin
import Foundation

@main struct OutgoingFileTransferStoreSpec {
    static func check(_ value: Bool) { precondition(value) }
    static func mutateBytesRestoringModificationTime(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        precondition(fd >= 0)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat(); precondition(fstat(fd, &before) == 0)
        try file.write(contentsOf: Data([255]))
        let dates = [before.st_atimespec, before.st_mtimespec]
        precondition(dates.withUnsafeBufferPointer { futimens(fd, $0.baseAddress) } == 0)
        var after = stat(); precondition(fstat(fd, &after) == 0)
        precondition(before.st_ino == after.st_ino && before.st_size == after.st_size)
        precondition(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
    }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("galaxybridge-outgoing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OutgoingFileTransferStore(root: base.appendingPathComponent("transfers"), testingIOBoundary: { boundary in
            precondition(boundary != .sourceVerificationRead, "common path must not hash the full source again")
        })
        let original = base.appendingPathComponent("example.bin")
        let payload = Data((0..<2_100_123).map { UInt8($0 % 251) })
        try payload.write(to: original)
        let peer = Data(repeating: 7, count: 32)
        let metadataSource = base.appendingPathComponent("metadata.bin")
        let smallPayload = Data((0..<67_584).map { UInt8($0 % 251) })
        try smallPayload.write(to: metadataSource)
        let metadataStore = OutgoingFileTransferStore(root: base.appendingPathComponent("metadata-transfers"), testingIOBoundary: { boundary in
            if boundary == .snapshotCreated { precondition(chmod(metadataSource.path, 0o600) == 0) }
        })
        let metadataTransfer = try metadataStore.prepare(deviceID: "device:A", peerFingerprint: peer, sourceURL: metadataSource)
        try Data("replacement".utf8).write(to: metadataSource, options: .atomic)
        check(try metadataTransfer.read(offset: 0, maximumLength: smallPayload.count) == smallPayload)
        try metadataStore.remove(metadataTransfer)
        let contentSource = base.appendingPathComponent("content-change.bin")
        try smallPayload.write(to: contentSource)
        let changingStore = OutgoingFileTransferStore(root: base.appendingPathComponent("changed-transfers"), testingIOBoundary: { boundary in
            if boundary == .snapshotCreated { try! mutateBytesRestoringModificationTime(contentSource) }
        })
        do {
            _ = try changingStore.prepare(deviceID: "device:A", peerFingerprint: peer, sourceURL: contentSource)
            fatalError("same-size changed content with restored mtime admitted")
        } catch OutgoingFileTransferError.changed {}
        let racingSource = base.appendingPathComponent("during-verification.bin")
        try smallPayload.write(to: racingSource)
        let racingStore = OutgoingFileTransferStore(root: base.appendingPathComponent("racing-transfers"), testingIOBoundary: { boundary in
            if boundary == .snapshotCreated { precondition(chmod(racingSource.path, 0o600) == 0) }
            if boundary == .sourceVerificationRead { try! mutateBytesRestoringModificationTime(racingSource) }
        })
        do {
            _ = try racingStore.prepare(deviceID: "device:A", peerFingerprint: peer, sourceURL: racingSource)
            fatalError("source mutation during verification admitted")
        } catch OutgoingFileTransferError.changed {}
        let transfer = try store.prepare(deviceID: "device:A", peerFingerprint: peer, sourceURL: original)
        precondition(transfer.relativeName == "example.bin" && transfer.sha256 == Data(SHA256.hash(data: payload)))
        // Replacement and in-place edits of the user's source cannot change
        // retransmitted bytes, including after process-local state is lost.
        try Data("replacement".utf8).write(to: original, options: .atomic)
        let reopenedStore = OutgoingFileTransferStore(root: store.root)
        let resumedResult = try reopenedStore.pending(deviceID: "device:A", peerFingerprint: peer)
        let resumed = resumedResult.transfers
        precondition(resumedResult.rejectedCount == 0)
        precondition(resumed.count == 1 && resumed[0].id == transfer.id)
        check(try resumed[0].read(offset: 1_048_576, maximumLength: 1_048_576) == payload.subdata(in: 1_048_576..<2_097_152))
        check(try resumed[0].read(offset: UInt64(payload.count), maximumLength: 1) == Data())
        check(try reopenedStore.pending(deviceID: "device:A", peerFingerprint: Data(repeating: 8, count: 32)).transfers.isEmpty)
        check(try reopenedStore.pending(deviceID: "device:B", peerFingerprint: peer).transfers.isEmpty)
        let symlink = base.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        do { _ = try store.prepare(deviceID: "device:A", peerFingerprint: peer, sourceURL: symlink); fatalError("symlink source admitted") }
        catch OutgoingFileTransferError.invalid {}
        // Detect a damaged saved payload before resuming onto the phone.
        precondition(chmod(transfer.url.path, 0o600) == 0)
        let damaged = try FileHandle(forWritingTo: transfer.url)
        try damaged.write(contentsOf: Data([255])); try damaged.close()
        let damagedResult = try reopenedStore.pending(deviceID: "device:A", peerFingerprint: peer)
        precondition(damagedResult.transfers.isEmpty && damagedResult.rejectedCount == 1)
        precondition(FileManager.default.fileExists(atPath: transfer.url.path)) // Never silently delete rejected evidence.
        try store.remove(transfer)
        try store.remove(transfer) // exact cleanup is idempotent
        check(try reopenedStore.pending(deviceID: "device:A", peerFingerprint: peer).transfers.isEmpty)
        check(try Data(contentsOf: original) == Data("replacement".utf8))
        let empty = base.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        let zero = try store.prepare(deviceID: "device:A", peerFingerprint: peer, sourceURL: empty)
        precondition(zero.size == 0 && zero.sha256 == Data(SHA256.hash(data: Data())))
        try store.remove(zero)
        let foreign = try store.prepare(deviceID: "device:B", peerFingerprint: Data(repeating: 8, count: 32), sourceURL: empty)
        let invalidManifest = Data("incomplete-json".utf8)
        try invalidManifest.write(to: foreign.directory.appendingPathComponent("manifest.json"))
        let good = try store.prepare(deviceID: "device:A", peerFingerprint: peer, sourceURL: original)
        let mixed = try store.pending(deviceID: "device:A", peerFingerprint: peer)
        precondition(mixed.transfers.map(\.id) == [good.id] && mixed.rejectedCount == 1)
        check(try Data(contentsOf: foreign.directory.appendingPathComponent("manifest.json")) == invalidManifest)
        try store.remove(good)
        // A pre-field manifest remains readable and defaults to active sending.
        let legacy = try store.prepare(deviceID: "device:C", peerFingerprint: peer, sourceURL: original)
        let legacyURL = legacy.directory.appendingPathComponent("manifest.json")
        var oldJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
        oldJSON.removeValue(forKey: "cancelRequested")
        try JSONSerialization.data(withJSONObject: oldJSON).write(to: legacyURL, options: .atomic)
        let oldTransfer = try store.pending(deviceID: "device:C", peerFingerprint: peer).transfers[0]
        precondition(!oldTransfer.cancelRequested)
        let cancelled = try store.requestCancellation(oldTransfer)
        precondition(cancelled.cancelRequested)
        // Cancellation recovery does not depend on payload integrity: it must still be
        // able to cancel a remote partial after the local snapshot becomes unavailable.
        try FileManager.default.removeItem(at: cancelled.url)
        let recoveredCancel = try OutgoingFileTransferStore(root: store.root)
            .pending(deviceID: "device:C", peerFingerprint: peer).transfers[0]
        precondition(recoveredCancel.cancelRequested && recoveredCancel.id == legacy.id)
        do { _ = try recoveredCancel.read(offset: 0, maximumLength: 1); fatalError("cancelled snapshot read admitted") }
        catch is CancellationError { }
        check(try store.requestCancellation(recoveredCancel).cancelRequested)
        try store.remove(recoveredCancel)
        print("Outgoing snapshots PASS: immutable source, restart/resume, peer fence, symlink rejection, tamper detection, exact cleanup, empty file")
    }
}
