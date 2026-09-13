import CryptoKit
import Darwin
import Foundation

@main
enum ResumableADBFileDeliverySpec {
    static let peer = ADBFileDeliveryPeer(identitySHA256: String(repeating: "a", count: 64), androidUserID: 0)
    final class Fixture {
        let root: URL, source: URL, hostState: URL, destination: URL, remoteState: URL, helper: URL
        init(helper: URL) throws {
            self.helper = helper
            root = FileManager.default.temporaryDirectory.appendingPathComponent("file-delivery-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            source = root.appendingPathComponent("input.bin")
            hostState = root.appendingPathComponent("host", isDirectory: true)
            destination = root.appendingPathComponent("destination", isDirectory: true)
            remoteState = root.appendingPathComponent("remote-state", isDirectory: true)
            for path in [destination, remoteState] {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func channel() throws -> ADBFileDeliveryProcessChannel {
            try ADBFileDeliveryProcessChannel(executableURL: helper,
                arguments: ["--destination", destination.path, "--state", remoteState.path, "--owner", peer.owner], idleTimeout: 5)
        }
        func prepare(_ data: Data, name: String = "output.bin") throws -> PreparedADBFileDelivery {
            try data.write(to: source)
            return try ResumableADBFileDelivery.prepare(sourceURL: source, stateDirectory: hostState, peer: peer,
                destinationName: name, cancellation: .init())
        }
        func final(_ prepared: PreparedADBFileDelivery) -> URL { destination.appendingPathComponent(prepared.manifest.name) }
        func part(_ prepared: PreparedADBFileDelivery) -> URL {
            remoteState.appendingPathComponent(prepared.manifest.transferID).appendingPathComponent("payload.part")
        }
    }
    final class LostAckChannel: ADBFileDeliveryChannel {
        let base: any ADBFileDeliveryChannel
        let dropOperation: String
        var operation = ""
        var dropped = false
        var awaitingPayload = false
        var payloadBytes = 0
        let truncatePayload: Bool
        init(_ base: any ADBFileDeliveryChannel, dropOperation: String, truncatePayload: Bool = false) {
            self.base = base; self.dropOperation = dropOperation; self.truncatePayload = truncatePayload
        }
        func write(_ data: Data, cancellation: ADBFileDeliveryCancellation) throws {
            if awaitingPayload {
                awaitingPayload = false; payloadBytes += data.count
                if truncatePayload {
                    try base.write(data.prefix(data.count / 2), cancellation: cancellation)
                    base.close(); throw ADBFileDeliveryFailure.interrupted
                }
            } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let op = object["op"] as? String {
                operation = op; awaitingPayload = op == "append"
            }
            try base.write(data, cancellation: cancellation)
        }
        func readLine(cancellation: ADBFileDeliveryCancellation) throws -> Data {
            let line = try base.readLine(cancellation: cancellation)
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
            if !dropped && operation == dropOperation && object?["kind"] as? String == "ack" {
                dropped = true; base.close(); throw ADBFileDeliveryFailure.interrupted
            }
            return line
        }
        func close() { base.close() }
    }
    final class InvalidCompletionChannel: ADBFileDeliveryChannel {
        var request: [String: Any] = [:]
        func write(_ data: Data, cancellation: ADBFileDeliveryCancellation) throws {
            request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func readLine(cancellation: ADBFileDeliveryCancellation) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["kind": "ack", "session_id": request["session_id"]!,
                "request_id": request["request_id"]!, "status": ["offset": 0, "prefix_sha256": String(repeating: "0", count: 64),
                "complete": true, "cancelled": false]])
        }
        func close() {}
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("helper path required") }
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        try knownVector(helper)
        try interruptionAndResume(helper)
        try truncatedChunk(helper)
        try lostCommitAck(helper)
        try collisionAndCancel(helper)
        try invalidPeerAndCompletion(helper)
        try cancelledPreparation(helper)
        print("PASS real helper process: SHA vector, confirmed-offset resume, immutable source view, mid-chunk loss, commit ACK loss, no-clobber collision, exact cancellation, peer and ACK fences")
    }
    static func knownVector(_ helper: URL) throws {
        let f = try Fixture(helper: helper); let p = try f.prepare(Data("hello world".utf8))
        precondition(p.manifest.sha256 == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        try ResumableADBFileDelivery.deliver(p, peer: peer, cancellation: .init(), openChannel: f.channel)
        let bytes = try Data(contentsOf: f.final(p)); precondition(bytes == Data("hello world".utf8))
    }
    static func interruptionAndResume(_ helper: URL) throws {
        let f = try Fixture(helper: helper)
        let bytes = Data((0..<(3 * ResumableADBFileDelivery.chunkSize + 13)).map { UInt8(truncatingIfNeeded: $0) })
        let prepared = try f.prepare(bytes)
        let lost = LostAckChannel(try f.channel(), dropOperation: "append")
        do {
            try ResumableADBFileDelivery.deliver(prepared, peer: peer, cancellation: .init(), openChannel: { lost })
            preconditionFailure("lost ACK must pause")
        } catch ADBFileDeliveryFailure.interrupted {}
        precondition(!FileManager.default.fileExists(atPath: f.final(prepared).path))
        let checkpointSize = try FileManager.default.attributesOfItem(atPath: f.part(prepared).path)[.size] as! NSNumber
        precondition(checkpointSize.uint64Value == UInt64(ResumableADBFileDelivery.chunkSize))
        // Replacement of the original source cannot change the prepared snapshot.
        try Data(repeating: 0xff, count: bytes.count).write(to: f.source, options: .atomic)
        let loaded = try ResumableADBFileDelivery.load(recordURL: prepared.recordURL)
        var firstConfirmed: UInt64?
        try ResumableADBFileDelivery.deliver(loaded, peer: peer, cancellation: .init(), openChannel: f.channel) { event in
            if case let .sending(offset, _) = event, firstConfirmed == nil { firstConfirmed = offset }
        }
        precondition(firstConfirmed == UInt64(ResumableADBFileDelivery.chunkSize))
        let final = try Data(contentsOf: f.final(prepared)); precondition(final == bytes)
    }
    static func truncatedChunk(_ helper: URL) throws {
        let f = try Fixture(helper: helper); let bytes = Data(repeating: 0x5a, count: 2 * ResumableADBFileDelivery.chunkSize)
        let p = try f.prepare(bytes)
        let broken = LostAckChannel(try f.channel(), dropOperation: "none", truncatePayload: true)
        do {
            try ResumableADBFileDelivery.deliver(p, peer: peer, cancellation: .init(), openChannel: { broken })
            preconditionFailure("mid-chunk disconnect must pause")
        } catch ADBFileDeliveryFailure.interrupted {}
        precondition(!FileManager.default.fileExists(atPath: f.final(p).path))
        try ResumableADBFileDelivery.deliver(p, peer: peer, cancellation: .init(), openChannel: f.channel)
        let final = try Data(contentsOf: f.final(p)); precondition(final == bytes)
    }
    static func lostCommitAck(_ helper: URL) throws {
        let f = try Fixture(helper: helper); let p = try f.prepare(Data("finished".utf8))
        let lost = LostAckChannel(try f.channel(), dropOperation: "commit")
        do {
            try ResumableADBFileDelivery.deliver(p, peer: peer, cancellation: .init(), openChannel: { lost })
            preconditionFailure("lost final ACK must remain unconfirmed at sender")
        } catch ADBFileDeliveryFailure.interrupted {}
        precondition(FileManager.default.fileExists(atPath: f.final(p).path))
        try FileManager.default.removeItem(at: p.snapshotURL)
        // Durable remote receipt settles ACK loss even if the local snapshot is gone.
        try ResumableADBFileDelivery.deliver(p, peer: peer, cancellation: .init(), openChannel: f.channel)
        let cancelled = try ResumableADBFileDelivery.cancelRemote(p, peer: peer, cancellation: .init(), openChannel: f.channel)
        precondition(!cancelled)
        let final = try Data(contentsOf: f.final(p)); precondition(final == Data("finished".utf8))
    }
    static func collisionAndCancel(_ helper: URL) throws {
        let f = try Fixture(helper: helper); let p = try f.prepare(Data("user upload".utf8))
        let sentinel = Data("existing customer file".utf8); try sentinel.write(to: f.final(p))
        do {
            try ResumableADBFileDelivery.deliver(p, peer: peer, cancellation: .init(), openChannel: f.channel)
            preconditionFailure("existing final must not be replaced")
        } catch ADBFileDeliveryFailure.remote("destination_exists") {}
        let final = try Data(contentsOf: f.final(p)); precondition(final == sentinel)
        let other = try Fixture(helper: helper); let q = try other.prepare(Data(repeating: 3, count: 2 * ResumableADBFileDelivery.chunkSize))
        let lost = LostAckChannel(try other.channel(), dropOperation: "append")
        do { try ResumableADBFileDelivery.deliver(q, peer: peer, cancellation: .init(), openChannel: { lost }) }
        catch ADBFileDeliveryFailure.interrupted {}
        let cancelled = try ResumableADBFileDelivery.cancelRemote(q, peer: peer, cancellation: .init(), openChannel: other.channel)
        precondition(cancelled && !FileManager.default.fileExists(atPath: other.part(q).path))
        precondition(!FileManager.default.fileExists(atPath: other.final(q).path))
    }
    static func invalidPeerAndCompletion(_ helper: URL) throws {
        let f = try Fixture(helper: helper); let p = try f.prepare(Data("abc".utf8))
        let wrong = ADBFileDeliveryPeer(identitySHA256: String(repeating: "b", count: 64), androidUserID: 0)
        do {
            try ResumableADBFileDelivery.deliver(p, peer: wrong, cancellation: .init(), openChannel: { preconditionFailure("wrong peer must not start process") })
            preconditionFailure("wrong peer admitted")
        } catch ADBFileDeliveryFailure.peerChanged {}
        do {
            try ResumableADBFileDelivery.deliver(p, peer: peer, cancellation: .init(), openChannel: { InvalidCompletionChannel() })
            preconditionFailure("incomplete bytes cannot be accepted as complete")
        } catch ADBFileDeliveryFailure.invalidResponse {}
    }
    static func cancelledPreparation(_ helper: URL) throws {
        let f = try Fixture(helper: helper); try Data("abc".utf8).write(to: f.source)
        let cancel = ADBFileDeliveryCancellation(); cancel.cancel()
        do {
            _ = try ResumableADBFileDelivery.prepare(sourceURL: f.source, stateDirectory: f.hostState, peer: peer, cancellation: cancel)
            preconditionFailure("cancelled preparation must not publish manifest")
        } catch ADBFileDeliveryFailure.cancelled {}
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: f.hostState.path)) ?? []
        precondition(entries.isEmpty)
    }
}
