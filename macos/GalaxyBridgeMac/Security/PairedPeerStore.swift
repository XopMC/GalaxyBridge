import Foundation

struct PairedPeer: Codable, Equatable, Sendable {
    let deviceID: String
    let displayName: String
    let identityPublicKey: Data
    let tlsCertificateSHA256: Data
    let pairedAt: Date
}

struct StagedPairingTrust: Codable, Equatable, Sendable {
    let peer: PairedPeer
    let hostID: String
    let sessionID: String
    let commitTranscript: Data
    let commitSignature: Data
    let expiresAt: Date
}

enum PairedPeerStoreError: Error {
    case stagedPairingNotFound
}

typealias PairedPeerPersistenceBackend = SecureRecordPersistenceBackend

private struct ActivePairingTrust: Codable {
    let peer: PairedPeer
    let committedSessionID: String
}

struct PairedPeerStore {
    private let backend: any PairedPeerPersistenceBackend
    private let servicePrefix: String?

    init(
        backend: (any PairedPeerPersistenceBackend)? = nil,
        servicePrefix: String? = nil
    ) {
        self.backend = backend ?? SecureRecordBackendFactory.make(
            keychainBackend: KeychainSecureRecordPersistenceBackend()
        )
        self.servicePrefix = servicePrefix
    }

    private var service: String {
        if let servicePrefix { return "\(servicePrefix).paired-peer" }
        if Bundle.main.bundleIdentifier == SecureRecordBackendFactory.internalBundleIdentifier {
            return "com.xopmc.GalaxyBridge.internal.local-v1.paired-peer"
        }
        return "com.xopmc.GalaxyBridge.paired-peer"
    }

    private var stagedService: String { "\(service).staged-v1" }

    /// Direct active storage is retained for migrations and explicit imports.
    /// The interactive pairing path must use stage/promote instead.
    func save(_ peer: PairedPeer) throws {
        try backend.upsert(
            service: service,
            account: peer.deviceID,
            data: try JSONEncoder().encode(peer)
        )
    }

    /// Persists a non-authorizing pairing candidate. `peers()` never enumerates this namespace.
    func stage(_ pairing: StagedPairingTrust) throws {
        try backend.upsert(
            service: stagedService,
            account: pairing.peer.deviceID,
            data: try JSONEncoder().encode(pairing)
        )
    }

    func staged(deviceID: String, sessionID: String) throws -> StagedPairingTrust? {
        guard let data = try backend.read(service: stagedService, account: deviceID),
              let pairing = try? JSONDecoder().decode(StagedPairingTrust.self, from: data),
              pairing.sessionID == sessionID
        else { return nil }
        return pairing
    }

    func stagedPairings() throws -> [StagedPairingTrust] {
        try backend.accounts(service: stagedService).compactMap { account in
            guard let data = try backend.read(service: stagedService, account: account) else { return nil }
            return try? JSONDecoder().decode(StagedPairingTrust.self, from: data)
        }
    }

    /// Promotes only the exact staged transaction after its signed Ack was validated.
    /// Repeating the same Ack is safe even when the first promotion response was lost.
    func promote(deviceID: String, sessionID: String) throws -> PairedPeer {
        if let pairing = try staged(deviceID: deviceID, sessionID: sessionID) {
            let active = ActivePairingTrust(peer: pairing.peer, committedSessionID: sessionID)
            try backend.upsert(
                service: service,
                account: deviceID,
                data: try JSONEncoder().encode(active)
            )
            try backend.delete(service: stagedService, account: deviceID)
            return pairing.peer
        }
        if let data = try backend.read(service: service, account: deviceID),
           let active = try? JSONDecoder().decode(ActivePairingTrust.self, from: data),
           active.committedSessionID == sessionID {
            return active.peer
        }
        throw PairedPeerStoreError.stagedPairingNotFound
    }

    func peers() throws -> [PairedPeer] {
        try backend.accounts(service: service).compactMap { account in
            guard let data = try backend.read(service: service, account: account) else { return nil }
            if let active = try? JSONDecoder().decode(ActivePairingTrust.self, from: data) {
                return active.peer
            }
            return try? JSONDecoder().decode(PairedPeer.self, from: data)
        }
    }

    func revoke(deviceID: String) throws {
        try backend.delete(service: service, account: deviceID)
        try backend.delete(service: stagedService, account: deviceID)
    }
}
