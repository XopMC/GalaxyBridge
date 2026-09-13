import Foundation

enum ScreenMediaTransportSource: Equatable, Sendable {
    case enhanced
    case companion
}

enum MediaTransportArbitrationPolicy {
    static func preferredSource(enhancedState: ScrcpySessionState?) -> ScreenMediaTransportSource {
        if case .streaming = enhancedState { return .enhanced }
        return .companion
    }

    static func shouldAccept(
        _ source: ScreenMediaTransportSource,
        enhancedState: ScrcpySessionState?
    ) -> Bool {
        source == preferredSource(enhancedState: enhancedState)
    }
}

/// A lock-backed snapshot used on the Network.framework receive queue.
///
/// Companion video and audio continue arriving while enhanced transport owns
/// presentation. Rejecting those packets here is important: scheduling a
/// MainActor task for every discarded 60 fps video packet creates an unbounded
/// task backlog, makes the UI stutter, and delays fallback behind stale work.
final class MediaTransportDispatchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var preferredSource: ScreenMediaTransportSource

    init(enhancedState: ScrcpySessionState?) {
        preferredSource = MediaTransportArbitrationPolicy.preferredSource(
            enhancedState: enhancedState
        )
    }

    /// True only when resuming LAN after dropping its interframe references.
    @discardableResult
    func update(enhancedState: ScrcpySessionState?) -> Bool {
        lock.lock()
        let previous = preferredSource
        preferredSource = MediaTransportArbitrationPolicy.preferredSource(
            enhancedState: enhancedState
        )
        let needsBootstrap = previous == .enhanced && preferredSource == .companion
        lock.unlock()
        return needsBootstrap
    }

    func shouldDispatch(
        _ source: ScreenMediaTransportSource,
        isConfiguration: Bool
    ) -> Bool {
        // Codec configuration is sparse and keeps the warm fallback decoder
        // ready without queueing the continuous media stream.
        if source == .companion, isConfiguration { return true }
        lock.lock()
        defer { lock.unlock() }
        return source == preferredSource
    }
}
