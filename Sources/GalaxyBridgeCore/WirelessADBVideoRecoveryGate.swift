import Foundation

/// Bounds a reliable-stream overload episode without accepting dependent
/// frames across a deliberately dropped access unit.
public struct WirelessADBVideoRecoveryGate: Sendable {
    private var awaitingKeyFrame = false

    public init() {}

    public mutating func shouldAdmit(_ event: ScrcpyStreamEvent) -> Bool {
        guard awaitingKeyFrame else { return true }
        guard case let .packet(packet) = event else { return true }
        return packet.isConfiguration || packet.isKeyFrame
    }

    /// Returns true only when this pressure event starts a new recovery gap.
    @discardableResult
    public mutating func notePressure(on event: ScrcpyStreamEvent) -> Bool {
        guard case let .packet(packet) = event, !packet.isConfiguration else { return false }
        let opened = !awaitingKeyFrame
        awaitingKeyFrame = true
        return opened
    }

    public mutating func noteAdmitted(_ event: ScrcpyStreamEvent) {
        guard case let .packet(packet) = event, packet.isKeyFrame else { return }
        awaitingKeyFrame = false
    }
}
