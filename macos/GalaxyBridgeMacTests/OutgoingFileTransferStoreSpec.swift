import CryptoKit
import Darwin
import Foundation

@main struct OutgoingFileTransferStoreSpec {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("galaxybridge-outgoing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = OutgoingFileTransferStore(root: base.appendingPathComponent("transfers"))
        let original = base.appendingPathComponent("example.bin")
        let payload = Data((0..<2_100_123).map { UInt8($0 % 251) })
        try payload.write(to: original)
        let peer = Data(repeating: 7, count: 32)
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
