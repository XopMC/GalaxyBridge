public struct VideoSurfacePublicationUpdate: Equatable, Sendable {
    public let hasFrame: Bool?
    public let protectedContentSuspected: Bool?

    public init(hasFrame: Bool?, protectedContentSuspected: Bool?) {
        self.hasFrame = hasFrame
        self.protectedContentSuspected = protectedContentSuspected
    }
}

/// Keeps high-frequency decoded frames out of SwiftUI invalidation. The Metal
/// renderer still receives every frame; observable state changes only when a
/// placeholder-relevant value actually transitions.
public struct VideoSurfacePublicationState: Sendable {
    private var hasFrame = false
    private var protectedContentSuspected = false

    public init() {}

    public mutating func consume(
        protectedContentSuspected nextProtectedContentSuspected: Bool
    ) -> VideoSurfacePublicationUpdate {
        let nextHasFrame: Bool?
        if hasFrame {
            nextHasFrame = nil
        } else {
            hasFrame = true
            nextHasFrame = true
        }

        let nextProtectedContent: Bool?
        if protectedContentSuspected == nextProtectedContentSuspected {
            nextProtectedContent = nil
        } else {
            protectedContentSuspected = nextProtectedContentSuspected
            nextProtectedContent = nextProtectedContentSuspected
        }
        return VideoSurfacePublicationUpdate(
            hasFrame: nextHasFrame,
            protectedContentSuspected: nextProtectedContent
        )
    }
}

public struct VideoSurfaceRenderInvalidationState: Sendable {
    private var drawPending = false

    public init() {}

    public mutating func request() -> Bool {
        guard !drawPending else { return false }
        drawPending = true
        return true
    }

    public mutating func didDraw() {
        drawPending = false
    }
}
