import Foundation
import Security

enum IdentityStoreError: Error { case keychain(OSStatus) }
enum StagingSpecError: Error { case failed(String); case injected }

func stagingExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw StagingSpecError.failed(message) }
}

final class MemoryPairedPeerBackend: PairedPeerPersistenceBackend {
    private var values: [String: Data] = [:]
    var failNextWrite = false

    func upsert(service: String, account: String, data: Data) throws {
        if failNextWrite {
            failNextWrite = false
            throw StagingSpecError.injected
        }
        values["\(service)|\(account)"] = data
    }

    func read(service: String, account: String) throws -> Data? {
        values["\(service)|\(account)"]
    }

    func accounts(service: String) throws -> [String] {
        let prefix = "\(service)|"
        return values.keys.compactMap { key in
            key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        }
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: "\(service)|\(account)")
    }
}

@main
enum PairedPeerStagingSpec {
    static func main() throws {
        let backend = MemoryPairedPeerBackend()
        let peer = PairedPeer(
            deviceID: "galaxy-s24",
            displayName: "Galaxy S24 Ultra",
            identityPublicKey: Data(repeating: 0x41, count: 65),
            tlsCertificateSHA256: Data(repeating: 0x42, count: 32),
            pairedAt: Date(timeIntervalSince1970: 10)
        )
        let pending = StagedPairingTrust(
            peer: peer,
            hostID: "mac-host",
            sessionID: "pair-session",
            commitTranscript: Data([1, 2, 3]),
            commitSignature: Data([4, 5, 6]),
            expiresAt: Date(timeIntervalSince1970: 120)
        )

        var store = PairedPeerStore(backend: backend, servicePrefix: "test.galaxybridge")
        try store.stage(pending)
        try stagingExpect(try store.peers().isEmpty,
                          "staged trust must never be exposed by peers() before signed Ack")
        try stagingExpect(try store.staged(deviceID: peer.deviceID, sessionID: pending.sessionID) == pending,
                          "commit loss must preserve the durable staged candidate")

        // Reconstructing the store simulates process loss after commit or Ack loss.
        store = PairedPeerStore(backend: backend, servicePrefix: "test.galaxybridge")
        try stagingExpect(try store.peers().isEmpty,
                          "restart must not promote an unacknowledged candidate")
        try stagingExpect(try store.stagedPairings() == [pending],
                          "restart must enumerate durable state needed to recover a lost Ack")
        do {
            _ = try store.promote(deviceID: peer.deviceID, sessionID: "substituted-session")
            throw StagingSpecError.failed("a substituted Ack session must not promote trust")
        } catch PairedPeerStoreError.stagedPairingNotFound {
            // Expected.
        }
        try stagingExpect(try store.peers().isEmpty,
                          "failed validation must leave active trust empty")

        backend.failNextWrite = true
        do {
            _ = try store.promote(deviceID: peer.deviceID, sessionID: pending.sessionID)
            throw StagingSpecError.failed("injected promotion write must fail")
        } catch StagingSpecError.injected {
            // Expected.
        }
        try stagingExpect(try store.peers().isEmpty,
                          "failed active persistence must not expose one-sided trust")
        try stagingExpect(try store.staged(deviceID: peer.deviceID, sessionID: pending.sessionID) != nil,
                          "failed promotion must retain staged recovery state")

        let promoted = try store.promote(deviceID: peer.deviceID, sessionID: pending.sessionID)
        try stagingExpect(promoted == peer, "valid signed Ack must promote the staged peer")
        try stagingExpect(try store.peers() == [peer], "promoted peer must become active")
        try stagingExpect(try store.staged(deviceID: peer.deviceID, sessionID: pending.sessionID) == nil,
                          "successful promotion must remove pending material")

        let duplicate = try store.promote(deviceID: peer.deviceID, sessionID: pending.sessionID)
        try stagingExpect(duplicate == peer,
                          "a duplicate Ack after lost response must recover idempotently")

        print("PASS staged Mac trust is hidden until signed Ack and promotion is durable/idempotent")
    }
}
