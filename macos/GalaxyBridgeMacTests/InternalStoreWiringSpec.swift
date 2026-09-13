import Foundation

private final class ForbiddenKeychainBackend: SecureRecordPersistenceBackend {
    init() { preconditionFailure("Internal routing constructed the Keychain backend") }
    func upsert(service: String, account: String, data: Data) throws {}
    func read(service: String, account: String) throws -> Data? { nil }
    func accounts(service: String) throws -> [String] { [] }
    func delete(service: String, account: String) throws {}
}

private final class RacingIdentityBackend: SecureRecordPersistenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var emptyReads = 0

    func upsert(service: String, account: String, data: Data) throws {
        lock.withLock { value = data }
    }

    func read(service: String, account: String) throws -> Data? {
        lock.lock()
        if let value {
            lock.unlock()
            return value
        }
        emptyReads += 1
        let shouldDelay = emptyReads == 1
        lock.unlock()
        if shouldDelay { Thread.sleep(forTimeInterval: 0.1) }
        return nil
    }

    func accounts(service: String) throws -> [String] { [] }
    func delete(service: String, account: String) throws { lock.withLock { value = nil } }
}

private final class FingerprintResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    func append(_ value: Data) { lock.withLock { values.append(value) } }
    func snapshot() -> [Data] { lock.withLock { values } }
}

@main
enum InternalStoreWiringSpec {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyBridgeInternalWiring-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = SecureRecordBackendFactory.make(
            bundleIdentifier: SecureRecordBackendFactory.internalBundleIdentifier,
            internalRootURL: root,
            keychainBackend: ForbiddenKeychainBackend()
        )

        let identityService = "test.identity"
        let fingerprint = try KeychainIdentityStore(
            backend: backend,
            service: identityService
        ).fingerprint()
        precondition(fingerprint.count == 32)
        let reopenedFingerprint = try KeychainIdentityStore(
            backend: backend,
            service: identityService
        ).fingerprint()
        precondition(
            reopenedFingerprint == fingerprint,
            "Internal identity must survive store reconstruction"
        )

        let peer = PairedPeer(
            deviceID: "s24",
            displayName: "Galaxy S24 Ultra",
            identityPublicKey: Data(repeating: 0x31, count: 65),
            tlsCertificateSHA256: Data(repeating: 0x32, count: 32),
            pairedAt: Date(timeIntervalSince1970: 100)
        )
        let pairing = StagedPairingTrust(
            peer: peer,
            hostID: "mac",
            sessionID: "session",
            commitTranscript: Data([1]),
            commitSignature: Data([2]),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        var peerStore = PairedPeerStore(backend: backend, servicePrefix: "test")
        try peerStore.stage(pairing)
        _ = try peerStore.promote(deviceID: peer.deviceID, sessionID: pairing.sessionID)
        peerStore = PairedPeerStore(backend: backend, servicePrefix: "test")
        let reopenedPeers = try peerStore.peers()
        precondition(reopenedPeers == [peer])

        let bindingService = "test.adb"
        let binding = ADBBindingRecord(
            adbSerial: "TESTPHONE01",
            deviceID: peer.deviceID,
            identityPublicKeySHA256: Data(repeating: 0x41, count: 32),
            verifiedAt: Date(timeIntervalSince1970: 300)
        )
        let adbStore = ADBBindingStore(backend: backend, service: bindingService)
        try adbStore.save(binding)
        let reopenedBinding = try ADBBindingStore(
            backend: backend,
            service: bindingService
        ).record(for: binding.adbSerial)
        precondition(reopenedBinding == binding)
        try adbStore.revoke(deviceID: peer.deviceID)
        let revokedBinding = try adbStore.record(for: binding.adbSerial)
        precondition(revokedBinding == nil)

        let racingBackend = RacingIdentityBackend()
        let results = FingerprintResults()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let fingerprint = try! KeychainIdentityStore(
                    backend: racingBackend,
                    service: "test.concurrent.identity"
                ).fingerprint()
                results.append(fingerprint)
            }
        }
        group.wait()
        let fingerprints = results.snapshot()
        precondition(
            fingerprints.count == 2 && fingerprints[0] == fingerprints[1],
            "Concurrent first use must not return two different host identities"
        )

        print("Internal identity, staged/active pairing, and ADB binding local persistence passed.")
    }
}
