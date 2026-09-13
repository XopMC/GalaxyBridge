#if !GALAXYBRIDGE_APP_STORE
import CryptoKit
import Foundation
import Security

struct ADBBindingRecord: Codable, Equatable, Sendable {
    let adbSerial: String
    let deviceID: String
    let identityPublicKeySHA256: Data
    let verifiedAt: Date
    let hardwareSerial: String?

    init(adbSerial: String, deviceID: String, identityPublicKeySHA256: Data, verifiedAt: Date, hardwareSerial: String? = nil) {
        self.adbSerial = adbSerial
        self.deviceID = deviceID
        self.identityPublicKeySHA256 = identityPublicKeySHA256
        self.verifiedAt = verifiedAt
        self.hardwareSerial = hardwareSerial
    }
}

struct ADBBindingStore {
    private let backend: any SecureRecordPersistenceBackend
    private let service: String

    init(
        backend: (any SecureRecordPersistenceBackend)? = nil,
        service: String? = nil
    ) {
        self.backend = backend ?? SecureRecordBackendFactory.make(
            keychainBackend: KeychainSecureRecordPersistenceBackend()
        )
        if let service {
            self.service = service
        } else if Bundle.main.bundleIdentifier == SecureRecordBackendFactory.internalBundleIdentifier {
            self.service = "com.xopmc.GalaxyBridge.internal.local-v1.adb-binding"
        } else {
            self.service = "com.xopmc.GalaxyBridge.adb-binding"
        }
    }

    func save(_ record: ADBBindingRecord) throws {
        let data = try JSONEncoder().encode(record)
        try backend.upsert(service: service, account: record.adbSerial, data: data)
    }

    func record(for serial: String) throws -> ADBBindingRecord? {
        guard let data = try backend.read(service: service, account: serial) else { return nil }
        return try JSONDecoder().decode(ADBBindingRecord.self, from: data)
    }

    func records() throws -> [ADBBindingRecord] {
        try backend.accounts(service: service).compactMap { try record(for: $0) }
    }

    func isVerified(serial: String, peer: PairedPeer) -> Bool {
        guard let record = try? record(for: serial) else { return false }
        return record.deviceID == peer.deviceID &&
            record.identityPublicKeySHA256 == Data(SHA256.hash(data: peer.identityPublicKey))
    }

    func revoke(deviceID: String) throws {
        for account in try backend.accounts(service: service) {
            guard let record = try record(for: account),
                  record.deviceID == deviceID
            else { continue }
            try backend.delete(service: service, account: account)
        }
    }
}
#endif
