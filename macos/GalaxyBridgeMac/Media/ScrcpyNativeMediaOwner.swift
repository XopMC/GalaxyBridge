import Foundation
import GalaxyBridgeCore

typealias NativeFrameDelivery = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

/// One actual native bundle per preparation, never reset into a successor.
final class ScrcpyNativeMediaOwner: @unchecked Sendable {
    let attempt: NativeMediaAttempt
    // scrcpy audio and video timestamps are monotonic per track, but their
    // first PTS values are not guaranteed to share one origin.  A single
    // clock therefore lets an audio discontinuity invalidate already decoded
    // video (and vice versa), which presents as severe Wi-Fi stutter even
    // while the producer and decoder remain healthy.
    let videoClock: MediaPlayoutClock
    let audioClock: MediaPlayoutClock
    let video: VideoToolboxDecoder
    let audio: AACAudioPlayer
    private let bindingLock = NSLock()
    private var binding: NativeFrameBinding

    init(id: NativeMediaAttemptID, binding: NativeFrameBinding,
         videoQueue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.owned-video"),
         audioQueue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.owned-audio"),
         playoutQueue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.owned-playout"),
         videoClock: MediaPlayoutClock = MediaPlayoutClock(),
         immediateVideoPlayout: Bool = false,
         recoverCorruptVideoFrames: Bool = false,
         audioClock: MediaPlayoutClock = MediaPlayoutClock(),
         frameDelivery: @escaping NativeFrameDelivery = { action in Task { @MainActor in action() } },
         failureHandler: @escaping @Sendable (NativeMediaAttemptID, NativeMediaFailure) -> Void) {
        self.binding = binding
        let attempt = NativeMediaAttempt(id: id) { failureHandler(id, $0) }
        self.attempt = attempt
        self.videoClock = videoClock
        self.audioClock = audioClock
        video = VideoToolboxDecoder(playoutClock: videoClock, immediateVideoPlayout: immediateVideoPlayout,
            recoverCorruptFrames: recoverCorruptVideoFrames,
            queue: videoQueue, playoutQueue: playoutQueue,
            nativeAttempt: attempt, ownedFrameHandler: { Self.deliver($0, using: frameDelivery) },
            frameHandler: { _, _, _ in }, failureHandler: { attempt.fail(.codec($0.localizedDescription)) })
        audio = AACAudioPlayer(playoutClock: audioClock, queue: audioQueue, nativeAttempt: attempt,
            failureHandler: { attempt.fail(.codec($0.localizedDescription)) })
    }

    func replaceBinding(_ next: NativeFrameBinding) {
        let previous = bindingLock.withLock { let previous = binding; binding = next; return previous }
        previous.revoke()
    }

    func admit(_ event: ScrcpyStreamEvent, audio: Bool = false, trace: PrimaryMediaTrace? = nil, externalRetention: NativeMediaLease? = nil, sourceIdentity: NativeMediaSourceIdentity? = nil) -> NativeMediaWork? {
        let original = bindingLock.withLock { binding }
        return attempt.admit(event, audio: audio, binding: original, trace: trace, externalRetention: externalRetention, sourceIdentity: sourceIdentity)
    }
    func admitMedia(_ event: ScrcpyStreamEvent, audio: Bool, trace: PrimaryMediaTrace?, externalRetention: NativeMediaLease?, sourceIdentity: NativeMediaSourceIdentity) -> NativeMediaAdmission<NativeMediaWork> {
        let original = bindingLock.withLock { binding }
        return attempt.admitMedia(event, audio: audio, binding: original, trace: trace, externalRetention: externalRetention, sourceIdentity: sourceIdentity)
    }

    /// Reliable wireless ADB has already consumed a complete framed packet
    /// before this boundary. A transient decoder burst may shed only that
    /// non-configuration video packet without retiring the whole scrcpy owner.
    func admitRecoverableRealtime(_ event: ScrcpyStreamEvent, audio: Bool,
                                  trace: PrimaryMediaTrace?) -> NativeMediaAdmission<NativeMediaWork> {
        let original = bindingLock.withLock { binding }
        return attempt.admitMedia(event, audio: audio, binding: original, trace: trace,
                                  externalRetention: nil, sourceIdentity: nil,
                                  pressurePolicy: .recoverableRealtime)
    }

    @discardableResult func retire() -> NativeMediaRetirement {
        bindingLock.withLock { binding }.revoke()
        return attempt.retire()
    }

    func reuseInstalledConfiguration(_ event: ScrcpyStreamEvent, identity: NativeMediaSourceIdentity,
                                     trace: PrimaryMediaTrace?) -> NativeMediaWork? {
        let original = bindingLock.withLock { binding }
        return video.reuseInstalledConfiguration(event, identity: identity, binding: original, trace: trace)
    }

    static func deliver(_ frame: NativeDecodedFrame, using delivery: NativeFrameDelivery) {
        if let trace = frame.trace { trace.collector.enter(.event, trace: trace) }
        delivery {
            if let trace = frame.trace { trace.collector.leave(.event, trace: trace) }
            guard frame.isAdmitted, let operation = frame.context.attempt.operation(), let binding = frame.context.binding else {
                if let trace = frame.trace { trace.collector.finish(trace, reason: .dropped) }
                return
            }
            defer { withExtendedLifetime(operation) {}; withExtendedLifetime(frame) {} }
            binding.handler(frame)
        }
    }
}
