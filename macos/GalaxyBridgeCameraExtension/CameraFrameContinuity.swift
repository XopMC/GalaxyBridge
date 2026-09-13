import Foundation

enum CameraFrameContinuityDecision: Equatable {
    case fresh
    case cached
    case placeholder
}

struct CameraFrameContinuityPolicy {
    let staleAfterNanoseconds: UInt64
    private var lastFreshFrameAtNanoseconds: UInt64?

    init(staleAfterNanoseconds: UInt64 = 750_000_000) {
        self.staleAfterNanoseconds = staleAfterNanoseconds
    }

    mutating func decide(
        hasFreshFrame: Bool,
        hasCachedFrame: Bool,
        nowNanoseconds: UInt64
    ) -> CameraFrameContinuityDecision {
        if hasFreshFrame {
            lastFreshFrameAtNanoseconds = nowNanoseconds
            return .fresh
        }

        guard hasCachedFrame,
              let lastFreshFrameAtNanoseconds,
              nowNanoseconds >= lastFreshFrameAtNanoseconds,
              nowNanoseconds - lastFreshFrameAtNanoseconds <= staleAfterNanoseconds
        else { return .placeholder }

        return .cached
    }
}
