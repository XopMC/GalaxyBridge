import Foundation

enum MediaPlayoutTrack: Hashable, Sendable {
    case audio
    case video
}

enum MediaPlayoutAction: Equatable, Sendable {
    case immediate
    case schedule(TimeInterval)
    case drop
}

struct MediaPlayoutDecision: Equatable, Sendable {
    let action: MediaPlayoutAction
    let generation: UInt64
}

/// One monotonic PTS-to-host-time mapping for a media track or for sources
/// whose tracks explicitly guarantee a common PTS origin. The lock is
/// intentionally internal so concurrent decoder callbacks cannot create
/// competing anchors during startup.
final class MediaPlayoutClock: @unchecked Sendable {
    static let defaultLeadTime: TimeInterval = 0.060
    static let maximumLateTime: TimeInterval = 0.100
    /// Interactive mirroring must never queue a long tail of future frames.
    /// A timestamp jump beyond this small jitter window is a discontinuity,
    /// so re-anchor it to the normal 60 ms lead instead of displaying an old
    /// gesture hundreds of milliseconds later.
    static let maximumFutureTime: TimeInterval = 0.150

    private let lock = NSLock()
    private var anchorPresentationTimeUs: UInt64?
    private var anchorHostTime: TimeInterval?
    private var lastPresentationTimeUs: [MediaPlayoutTrack: UInt64] = [:]
    private var lateSince: [MediaPlayoutTrack: TimeInterval] = [:]
    private var epoch: UInt32?
    private var generation: UInt64 = 0
    private let diagnostics: PrimaryMediaDiagnostics?
    private let leadTime: TimeInterval

    init(
        diagnostics: PrimaryMediaDiagnostics? = nil,
        leadTime: TimeInterval = MediaPlayoutClock.defaultLeadTime
    ) {
        precondition(leadTime >= 0 && leadTime <= Self.maximumFutureTime)
        self.diagnostics = diagnostics
        self.leadTime = leadTime
    }

    func decision(
        track: MediaPlayoutTrack,
        presentationTimeUs: UInt64?,
        epoch requestedEpoch: UInt32?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        diagnosticTrace: PrimaryMediaTrace? = nil,
        allowLateIndependentVideo: Bool = false
    ) -> MediaPlayoutDecision {
        lock.lock()
        defer { lock.unlock() }
        var diagnosticReason = PrimaryClockReason.none
        var diagnosticOffset: TimeInterval?
        func observed(_ decision: MediaPlayoutDecision) -> MediaPlayoutDecision {
            let action: PrimaryClockAction = switch decision.action {
            case .immediate: .immediate
            case .schedule: .schedule
            case .drop: .drop
            }
            (diagnosticTrace?.collector ?? diagnostics)?.clock(
                reason: diagnosticReason,
                action: action,
                audio: track == .audio,
                generation: decision.generation,
                offsetSeconds: diagnosticOffset
            )
            return decision
        }

        if let requestedEpoch, requestedEpoch != epoch {
            diagnosticReason = .epoch
            beginNewGeneration(epoch: requestedEpoch)
        }

        guard let presentationTimeUs else {
            diagnosticReason = .noPTS
            return observed(MediaPlayoutDecision(action: .immediate, generation: generation))
        }

        if let previous = lastPresentationTimeUs[track], presentationTimeUs < previous {
            diagnosticReason = .regression
            beginNewGeneration(epoch: requestedEpoch ?? epoch)
        }

        if anchorPresentationTimeUs == nil || anchorHostTime == nil {
            if diagnosticReason == .none { diagnosticReason = .initialAnchor }
            if generation == 0 { generation = 1 }
            self.anchorPresentationTimeUs = presentationTimeUs
            self.anchorHostTime = now + leadTime
        }

        guard let anchorPresentationTimeUs, let anchorHostTime else {
            return observed(MediaPlayoutDecision(action: .immediate, generation: generation))
        }

        let deltaMicroseconds: Double
        if presentationTimeUs >= anchorPresentationTimeUs {
            deltaMicroseconds = Double(presentationTimeUs - anchorPresentationTimeUs)
        } else {
            deltaMicroseconds = -Double(anchorPresentationTimeUs - presentationTimeUs)
        }
        let target = anchorHostTime + deltaMicroseconds / 1_000_000
        diagnosticOffset = target - now
        if target > now + Self.maximumFutureTime {
            diagnosticReason = .futureReanchor
            beginNewGeneration(epoch: requestedEpoch ?? epoch)
            self.anchorPresentationTimeUs = presentationTimeUs
            self.anchorHostTime = now + leadTime
            lastPresentationTimeUs[track] = presentationTimeUs
            return observed(MediaPlayoutDecision(
                action: .schedule(now + leadTime),
                generation: generation
            ))
        }

        lastPresentationTimeUs[track] = presentationTimeUs
        if target < now - Self.maximumLateTime {
            // A newly decoded, current-owned QUIC independent frame may be
            // the only static image after recovery. Present it once without
            // moving the shared AAC/PTS anchor or reviving queued old work.
            if track == .video && allowLateIndependentVideo {
                lateSince.removeValue(forKey: track)
                return observed(MediaPlayoutDecision(action: .immediate, generation: generation))
            }
            // A Wi-Fi path can settle at a different delay after congestion.
            // Dropping against the old anchor forever leaves a frozen screen.
            // Preserve the normal jitter/drop policy, but rebase a sustained
            // late track and invalidate both tracks' stale scheduled buffers.
            let started = lateSince[track] ?? now
            lateSince[track] = started
            if now - started >= 0.250 {
                diagnosticReason = .sustainedLateReanchor
                beginNewGeneration(epoch: requestedEpoch ?? epoch)
                self.anchorPresentationTimeUs = presentationTimeUs
                self.anchorHostTime = now + leadTime
                lastPresentationTimeUs[track] = presentationTimeUs
                return observed(MediaPlayoutDecision(action: .schedule(now + leadTime), generation: generation))
            }
            diagnosticReason = .lateDrop
            return observed(MediaPlayoutDecision(action: .drop, generation: generation))
        }
        lateSince.removeValue(forKey: track)
        if target <= now {
            return observed(MediaPlayoutDecision(action: .immediate, generation: generation))
        }
        return observed(MediaPlayoutDecision(action: .schedule(target), generation: generation))
    }

    func reset(epoch: UInt32? = nil) {
        lock.lock()
        beginNewGeneration(epoch: epoch)
        lock.unlock()
    }

    func isCurrent(generation candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == generation
    }

    private func beginNewGeneration(epoch: UInt32?) {
        generation &+= 1
        if generation == 0 { generation = 1 }
        self.epoch = epoch
        anchorPresentationTimeUs = nil
        anchorHostTime = nil
        lastPresentationTimeUs.removeAll(keepingCapacity: true)
        lateSince.removeAll(keepingCapacity: true)
    }
}
