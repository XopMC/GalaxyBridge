enum ScrcpySessionState: Equatable, Sendable {
    case idle
    case preparing
    case connecting
    case streaming(String)
    case failed(String)
    case stopped
}

/// A screen session and its underlying ADB transport have independent
/// lifetimes. Stopping or failing capture must not make an otherwise connected
/// USB/Wireless ADB route disappear from the canonical device row: clipboard,
/// application discovery and a user-initiated screen retry still use that
/// route while screen recovery is in progress.
enum EnhancedADBRouteAvailabilityPolicy {
    static func blocksRoute(for state: ScrcpySessionState?) -> Bool {
        _ = state
        return false
    }
}

/// The pinned server artifact is shared by concurrent screen, application,
/// and clipboard owners. Resource retirement is scoped on the Mac side, so no
/// individual server process may perform process-global cleanup.
enum ScrcpySharedResourceOwnershipPolicy {
    static let serverCleanupEnabled = false
}

/// Owns only diagnostics produced by enhanced transport failures. This lets a
/// recovered scrcpy stream clear its stale message without hiding an unrelated
/// camera, pairing, or Companion LAN failure which happened afterwards.
struct EnhancedSessionDiagnostics {
    private var failuresByDevice: [String: String] = [:]

    mutating func transition(
        deviceID: String,
        state: ScrcpySessionState,
        currentDiagnostic: String?
    ) -> String? {
        switch state {
        case let .failed(message):
            failuresByDevice[deviceID] = message
            return message
        case .streaming:
            guard let ownedFailure = failuresByDevice.removeValue(forKey: deviceID),
                  currentDiagnostic == ownedFailure
            else { return currentDiagnostic }
            return nil
        default:
            return currentDiagnostic
        }
    }

    mutating func migrate(from oldID: String, to newID: String) {
        guard oldID != newID, let message = failuresByDevice.removeValue(forKey: oldID) else { return }
        failuresByDevice[newID] = message
    }

    mutating func remove(deviceID: String) {
        failuresByDevice.removeValue(forKey: deviceID)
    }
}
