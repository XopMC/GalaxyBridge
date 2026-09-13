import CryptoKit
import Foundation
import Security

enum IdentityStoreError: Error, LocalizedError, CustomNSError {
    case keychain(OSStatus)

    var errorDescription: String? { String(localized: "ERROR_KEYCHAIN") }

    static var errorDomain: String { "com.xopmc.GalaxyBridge.IdentityStore" }
    var errorCode: Int {
        switch self { case let .keychain(status): Int(status) }
    }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? String(localized: "ERROR_KEYCHAIN")]
    }
}

struct KeychainIdentityStore {
    private static let keyCreationLock = NSLock()
    private let backend: any SecureRecordPersistenceBackend
    private let service: String
    private let account = "p256-signing-key"

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
            // Intentionally do not migrate stable-v6 Keychain records: even a
            // read can launch SecurityAgent when the old ACL is inaccessible.
            self.service = "com.xopmc.GalaxyBridge.internal.local-v1.identity"
        } else {
            self.service = "com.xopmc.GalaxyBridge.identity"
        }
    }

    func privateKey() throws -> P256.Signing.PrivateKey {
        try Self.keyCreationLock.withLock {
            if let existing = try read() {
                return try P256.Signing.PrivateKey(rawRepresentation: existing)
            }
            let key = P256.Signing.PrivateKey()
            try save(Data(key.rawRepresentation))
            return key
        }
    }

    func fingerprint() throws -> Data {
        let publicKey = try privateKey().publicKey
        return Data(SHA256.hash(data: publicKey.x963Representation))
    }

    func sign(nonce: Data) throws -> Data {
        Data(try privateKey().signature(for: nonce).derRepresentation)
    }

    func revoke() throws {
        try backend.delete(service: service, account: account)
    }

    private func read() throws -> Data? {
        try backend.read(service: service, account: account)
    }

    private func save(_ data: Data) throws {
        try backend.upsert(service: service, account: account, data: data)
    }
}
