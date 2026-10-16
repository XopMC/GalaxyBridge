import Foundation
import CoreGraphics

struct InputPhase: OptionSet, Sendable {
    let rawValue: Int
    static let began = Self(rawValue: 1)
    static let changed = Self(rawValue: 2)
    static let ended = Self(rawValue: 4)
    static let cancelled = Self(rawValue: 8)
}
struct NSEvent {
    var phase: InputPhase = []
    var momentumPhase: InputPhase = []
    var hasPreciseScrollingDeltas = true
    var scrollingDeltaX: CGFloat = 0
    var scrollingDeltaY: CGFloat = 8
    var locationInWindow = CGPoint(x: 0.5, y: 0.5)
}
enum ScrcpyMotionAction: Equatable { case down, move, up, cancel }
struct PrimaryMediaTrace {}
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
// ACTUAL_MOTION_FILTER

@MainActor final class SyntheticWindow {
    func makeFirstResponder(_ view: TrackpadGestureProbe) {}
}
@MainActor final class TrackpadGestureProbe {
    var window: SyntheticWindow?
    var preciseScrollUsesTouch = true
    var trackpadSequenceActive = false
    var trackpadTouchActive = false
    var trackpadTouchPosition = CGPoint(x: 0.5, y: 0.5)
    var trackpadMotionFilter = TrackpadMotionFilter()
    var trackpadReleaseWorkItem: DispatchWorkItem?
    var onTouch: ((ScrcpyMotionAction, Double, Double) -> Void)?
    var onTrackpadTouch: ((ScrcpyMotionAction, Double, Double) -> Void)?
    var onScroll: ((Double, Double, Double, Double) -> Void)?
    var primaryInputReceipt: ((Double) -> PrimaryMediaTrace?)?
    var primaryTouch: ((ScrcpyMotionAction, Double, Double, PrimaryMediaTrace?) -> Void)?
    var primaryTrackpadTouch: ((ScrcpyMotionAction, Double, Double, PrimaryMediaTrace?) -> Void)?
    var touches: [ScrcpyMotionAction] = []
    init() { onTrackpadTouch = { [weak self] action, _, _ in self?.touches.append(action) } }
    func normalized(_ point: CGPoint) -> CGPoint { point }
    func renderedRect() -> CGRect { CGRect(x: 0, y: 0, width: 400, height: 800) }
    // ACTUAL_TRACKPAD_METHODS
}

@main enum TrackpadGestureLifecycleSpec {
    @MainActor static func main() async throws {
        let probe = TrackpadGestureProbe()
        probe.scrollWheel(with: NSEvent())
        precondition(probe.trackpadTouchActive && probe.trackpadReleaseWorkItem != nil)
        try await Task.sleep(for: .milliseconds(20))
        probe.scrollWheel(with: NSEvent(phase: .began))
        try await Task.sleep(for: .milliseconds(40))
        probe.scrollWheel(with: NSEvent(phase: .changed))
        try await Task.sleep(for: .milliseconds(65))
        precondition(probe.trackpadTouchActive && !probe.touches.contains(.up) && !probe.touches.contains(.cancel),
            "A prior phase-less release interrupted the new phased gesture after 80 ms")
        probe.scrollWheel(with: NSEvent(phase: .ended, scrollingDeltaY: 0))
        precondition(probe.touches.last == .up && !probe.trackpadTouchActive,
            "A phased gesture must release immediately on its actual end")

        let fallback = TrackpadGestureProbe()
        fallback.scrollWheel(with: NSEvent())
        try await Task.sleep(for: .milliseconds(125))
        precondition(fallback.touches.last == .up && !fallback.trackpadTouchActive,
            "A truly phase-less gesture still needs its bounded fallback release")

        let momentum = TrackpadGestureProbe()
        momentum.scrollWheel(with: NSEvent(phase: .began))
        momentum.scrollWheel(with: NSEvent(momentumPhase: .began))
        precondition(momentum.touches.last == .up && !momentum.trackpadTouchActive,
            "Native momentum must retain the existing immediate touch-release policy")
        print("PASS actual trackpad lifecycle: old phase-less timer cannot end a new phased gesture; explicit end, bounded phase-less fallback and momentum semantics preserved")
    }
}
