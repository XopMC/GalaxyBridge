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
    private var retryAttempts = 0
    private var retryGeneration: UInt64 = 0
    private var pendingRetry: UInt64?

    public init() {}

    public mutating func request() -> Bool {
        retryAttempts = 0
        guard !drawPending else { return false }
        drawPending = true
        return true
    }

    public mutating func didDraw() {
        drawPending = false
        pendingRetry = nil
        retryGeneration &+= 1
    }

    /// A transient drawable miss must not lose the latest static frame. Keep
    /// retries bounded even if Metal never supplies a drawable. The caller
    /// schedules the returned token after 33 ms, never synchronously.
    public mutating func retryAfterFailedDraw(isVisible: Bool) -> UInt64? {
        guard isVisible, !drawPending, retryAttempts < 3 else { return nil }
        retryAttempts += 1
        retryGeneration &+= 1
        pendingRetry = retryGeneration
        drawPending = true
        return retryGeneration
    }

    /// Tokens coalesce new frames and reject work retired by a draw or clear.
    /// Going offscreen ends the chain; AppKit exposure/resize can redraw later.
    public mutating func consumeRetry(_ token: UInt64, isVisible: Bool) -> Bool {
        guard pendingRetry == token else { return false }
        pendingRetry = nil
        if !isVisible { drawPending = false }
        return isVisible
    }

    public mutating func didSubmitDraw() {
        retryAttempts = 0
    }

    public mutating func cancelRetries() {
        didDraw()
        retryAttempts = 0
    }
}
