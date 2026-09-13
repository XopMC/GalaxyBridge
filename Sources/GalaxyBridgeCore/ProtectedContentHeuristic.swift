import Foundation

/// A conservative fallback for platforms that do not expose whether MediaProjection
/// redacted a secure window. It consumes only a uniform-black boolean derived from a
/// sparse luma sample; no pixels or screen content are retained.
public struct ProtectedContentHeuristic: Sendable {
    public let minimumBlackDuration: TimeInterval
    private var blackSince: TimeInterval?
    private var observedEpoch: UInt32?

    public init(minimumBlackDuration: TimeInterval = 1.5) {
        self.minimumBlackDuration = max(0, minimumBlackDuration)
    }

    public mutating func observe(
        uniformlyBlack: Bool,
        presentationTime: TimeInterval,
        epoch: UInt32
    ) -> Bool {
        guard presentationTime.isFinite else {
            blackSince = nil
            observedEpoch = epoch
            return false
        }
        if observedEpoch != epoch {
            observedEpoch = epoch
            blackSince = nil
        }
        guard uniformlyBlack else {
            blackSince = nil
            return false
        }
        guard let blackSince else {
            self.blackSince = presentationTime
            return minimumBlackDuration == 0
        }
        guard presentationTime >= blackSince else {
            self.blackSince = presentationTime
            return false
        }
        return presentationTime - blackSince >= minimumBlackDuration
    }
}
