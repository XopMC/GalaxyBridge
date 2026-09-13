public enum DeviceSessionState: String, CaseIterable, Codable, Sendable {
    case discovered
    case pairing
    case connecting
    case connected
    case degraded
    case reconnecting
    case disconnected
    case revoked
}

public enum DeviceSessionStateError: Error, Equatable {
    case invalidTransition(from: DeviceSessionState, to: DeviceSessionState)
}

public struct DeviceSessionStateMachine: Sendable {
    public private(set) var state: DeviceSessionState

    public init(initialState: DeviceSessionState) {
        state = initialState
    }

    public mutating func transition(to nextState: DeviceSessionState) throws {
        guard Self.allowsTransition(from: state, to: nextState) else {
            throw DeviceSessionStateError.invalidTransition(from: state, to: nextState)
        }
        state = nextState
    }

    private static func allowsTransition(
        from currentState: DeviceSessionState,
        to nextState: DeviceSessionState
    ) -> Bool {
        switch (currentState, nextState) {
        case (.discovered, .pairing),
             (.discovered, .connecting),
             (.discovered, .disconnected),
             (.discovered, .revoked),
             (.pairing, .connecting),
             (.pairing, .disconnected),
             (.pairing, .revoked),
             (.connecting, .connected),
             (.connecting, .reconnecting),
             (.connecting, .disconnected),
             (.connecting, .revoked),
             (.connected, .degraded),
             (.connected, .reconnecting),
             (.connected, .disconnected),
             (.connected, .revoked),
             (.degraded, .connected),
             (.degraded, .reconnecting),
             (.degraded, .disconnected),
             (.degraded, .revoked),
             (.reconnecting, .connected),
             (.reconnecting, .degraded),
             (.reconnecting, .disconnected),
             (.reconnecting, .revoked),
             (.disconnected, .discovered),
             (.disconnected, .connecting),
             (.disconnected, .revoked),
             (.revoked, .pairing):
            true
        default:
            false
        }
    }
}
