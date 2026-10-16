import Foundation

@main
struct VideoSurfaceDrawableRetrySpec {
    static func main() {
        var state = VideoSurfaceRenderInvalidationState()
        precondition(state.request())
        state.didDraw()
        // Inject nil drawable, then success with NO successor video packet.
        guard let retry = state.retryAfterFailedDraw(isVisible: true) else {
            fatalError("a nil drawable lost the only changed frame instead of scheduling its retry")
        }
        precondition(state.consumeRetry(retry, isVisible: true))
        state.didDraw()
        state.didSubmitDraw()
        precondition(!state.consumeRetry(retry, isVisible: true), "successful draw left a stale retry")

        // Continuous nil drawables stop after the original attempt plus 3 retries.
        var unavailable = VideoSurfaceRenderInvalidationState()
        precondition(unavailable.request())
        for _ in 0 ..< 3 {
            unavailable.didDraw()
            guard let token = unavailable.retryAfterFailedDraw(isVisible: true) else {
                fatalError("transient failure exhausted retries prematurely")
            }
            precondition(unavailable.retryAfterFailedDraw(isVisible: true) == nil,
                         "a single miss scheduled duplicate work")
            precondition(unavailable.consumeRetry(token, isVisible: true))
            precondition(!unavailable.consumeRetry(token, isVisible: true), "token fired twice")
        }
        unavailable.didDraw()
        precondition(unavailable.retryAfterFailedDraw(isVisible: true) == nil,
                     "permanent drawable failure scheduled an unbounded loop")
        precondition(unavailable.request(), "exhausted retries blocked a new frame")
        unavailable.didDraw()
        precondition(unavailable.retryAfterFailedDraw(isVisible: true) != nil)

        for retireByDraw in [true, false] {
            var retired = VideoSurfaceRenderInvalidationState()
            precondition(retired.request())
            retired.didDraw()
            let token = retired.retryAfterFailedDraw(isVisible: true)!
            if retireByDraw { retired.didDraw() } else { retired.cancelRetries() }
            precondition(!retired.consumeRetry(token, isVisible: true), "retired retry ran")
            precondition(retired.request(), "retirement stranded the next frame")
        }

        var hidden = VideoSurfaceRenderInvalidationState()
        precondition(hidden.request())
        hidden.didDraw()
        precondition(hidden.retryAfterFailedDraw(isVisible: false) == nil,
                     "offscreen failure scheduled work")
        let hiddenToken = hidden.retryAfterFailedDraw(isVisible: true)!
        precondition(!hidden.consumeRetry(hiddenToken, isVisible: false))
        precondition(!hidden.consumeRetry(hiddenToken, isVisible: true), "hidden retry restarted itself")
        precondition(hidden.request(), "hidden cancellation blocked later frame")

        // A successor arriving during the delay coalesces into that draw. The
        // renderer snapshots its latest frame only when the delayed draw runs.
        var latest = VideoSurfaceRenderInvalidationState()
        precondition(latest.request())
        latest.didDraw()
        let token = latest.retryAfterFailedDraw(isVisible: true)!
        for _ in 0 ..< 120 { precondition(!latest.request()) }
        precondition(latest.consumeRetry(token, isVisible: true))
        latest.didDraw()
        latest.didSubmitDraw()
        precondition(latest.request())
        print("PASS static-frame nil-drawable recovery, 3-retry bound, token cancellation, visibility stop, and latest-frame coalescing")
    }
}
