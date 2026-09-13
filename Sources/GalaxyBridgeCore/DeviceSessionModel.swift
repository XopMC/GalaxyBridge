import Foundation

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public let publicKeyFingerprint: Data
    public var pairedTransports: Set<TransportKind>

    public init(
        id: UUID,
        displayName: String,
        publicKeyFingerprint: Data,
        pairedTransports: Set<TransportKind>
    ) {
        self.id = id
        self.displayName = displayName
        self.publicKeyFingerprint = publicKeyFingerprint
        self.pairedTransports = pairedTransports
    }
}

public enum DeviceSessionModelError: Error, Equatable {
    case noConnectedTransport
}

public struct DeviceSessionModel: Sendable {
    public let identity: DeviceIdentity

    private var stateMachine = DeviceSessionStateMachine(initialState: .discovered)
    private var transports: [TransportKind: TransportSnapshot] = [:]
    private var capabilityRoutes: [Capability: TransportKind] = [:]

    public var state: DeviceSessionState {
        stateMachine.state
    }

    public init(identity: DeviceIdentity) {
        self.identity = identity
    }

    public mutating func connect(using snapshots: [TransportSnapshot]) throws {
        try stateMachine.transition(to: .connecting)
        transports = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.kind, $0) })
        capabilityRoutes = CapabilityResolver.routes(for: Array(transports.values))

        guard preferredConnectedTransport != nil else {
            try stateMachine.transition(to: .disconnected)
            throw DeviceSessionModelError.noConnectedTransport
        }

        try stateMachine.transition(to: .connected)
    }

    public mutating func updateTransport(_ snapshot: TransportSnapshot) throws {
        let previousPreferred = preferredConnectedTransport
        transports[snapshot.kind] = snapshot
        capabilityRoutes = CapabilityResolver.routes(for: Array(transports.values))
        let currentPreferred = preferredConnectedTransport

        guard currentPreferred != nil else {
            if state != .disconnected {
                try stateMachine.transition(to: .disconnected)
            }
            return
        }

        if state == .connected, previousPreferred != currentPreferred {
            try stateMachine.transition(to: .degraded)
        } else if state == .degraded,
                  currentPreferred == TransportSelector.preferred(from: identity.pairedTransports) {
            try stateMachine.transition(to: .connected)
        }
    }

    public func route(for capability: Capability) -> TransportKind? {
        capabilityRoutes[capability]
    }

    private var preferredConnectedTransport: TransportKind? {
        TransportSelector.preferred(
            from: transports.values.lazy.filter(\.isConnected).map(\.kind)
        )
    }
}
