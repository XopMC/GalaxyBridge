import Foundation
import OSLog
import CoreVideo

enum PrimaryMediaStream: Int, CaseIterable, Sendable { case video, audio, control }
enum PrimaryMediaStage: Int, CaseIterable, Sendable {
    case received, actor, decoder, submitted, callback, delivered, appModel, surface
}
enum PrimaryMediaQueue: String, CaseIterable, Sendable { case event, decoder, vt, output, control }
enum PrimaryMediaMetric: String, CaseIterable, Sendable {
    case receiveToActor, actorToDecoder, decoderToSubmit, submitToCallback
    case callbackToDelivery, deliveryToAppModel, appModelToSurface, surfaceToMetal, metalToPresented
    case inputToDispatch, dispatchToProcessed
    case inputToFrameReceived, frameReceivedToVisibleChange, inputToVisibleChange
    case interarrival, relativePTS, presentationInterval
    case ownerWork, ownerWait, ownerCadence
}
enum PrimaryMediaCounter: String, CaseIterable, Sendable {
    case parsedBytes, parsedPackets, rawBytes, configuration, keyFrames, correlationLost, missingCorrelation
    case invalidTimestamp, incomplete, dropped, failed, queueImbalance, clockDecisions
    case uncorrelatedControl, controlProcessed, controlFailed, inputProbeExpired
    case metalSubmitted, drawablePresented, drawableSkipped
}
enum PrimaryClockReason: String, CaseIterable, Sendable {
    case none, noPTS, epoch, regression, initialAnchor, futureReanchor, sustainedLateReanchor, lateDrop, reset
}
enum PrimaryClockAction: String, CaseIterable, Sendable { case immediate, schedule, drop }

/// Immutable context travels with existing work, never through a current-session lookup.
/// It contains no frame, payload, device identity, view or closure.
struct PrimaryMediaTrace: Sendable {
    let collector: PrimaryMediaDiagnostics
    let stream: PrimaryMediaStream
    let sequence: UInt64
}

struct PrimaryInputFrameSample: Equatable, Sendable {
    let inputSequence: UInt64
    let frameSequence: UInt64
    let videoPTSUs: UInt64
    let inputDispatchEpochMS: Double
    let relativeVideoArrivalMS: Double?
    let inputToFrameMS: Double
    let frameToVisibleMS: Double

    var logField: String {
        let relativeArrival = relativeVideoArrivalMS.map { String($0) } ?? "none"
        return "inputFrameSample=input:\(inputSequence),frame:\(frameSequence),pts_us:\(videoPTSUs),dispatch_epoch_ms:\(inputDispatchEpochMS),relative_video_arrival_ms:\(relativeArrival),to_frame_ms:\(inputToFrameMS),to_visible_ms:\(frameToVisibleMS)"
    }
}

/// Metadata only: absolute host uptime and source PTS permit correlation without
/// comparing clocks from different machines. Source sequence is absent on TCP.
struct PrimaryGapEndpoint: Sendable {
    let sequence: UInt64
    let sourceSequence: UInt64?
    let pts: UInt64?
    let epoch: UInt32?
    let time: Double
}

struct PrimaryMediaGapSample: Sendable {
    enum Stage: String, Sendable { case received, presented }
    let stage: Stage
    let stream: PrimaryMediaStream
    let before: PrimaryGapEndpoint
    let after: PrimaryGapEndpoint
    var seconds: Double { after.time - before.time }

    var logField: String {
        "frameGap=\(stage.rawValue),stream:\(stream.rawValue),gap_ms:\(seconds * 1_000)"
        + ",before_uptime_s:\(before.time),after_uptime_s:\(after.time)"
        + ",before_frame:\(before.sequence),after_frame:\(after.sequence)"
        + ",before_pts_us:\(before.pts.map(String.init) ?? "none"),after_pts_us:\(after.pts.map(String.init) ?? "none")"
        + ",before_epoch:\(before.epoch.map(String.init) ?? "none"),after_epoch:\(after.epoch.map(String.init) ?? "none")"
        + ",before_source_seq:\(before.sourceSequence.map(String.init) ?? "none"),after_source_seq:\(after.sourceSequence.map(String.init) ?? "none")"
    }
}

struct PrimaryOwnerSpan: Sendable {
    let metric: PrimaryMediaMetric
    let start: Double
    let end: Double
    var seconds: Double { end - start }
    var logField: String {
        "ownerSpan=\(metric.rawValue),start_uptime_s:\(start),end_uptime_s:\(end),duration_ms:\(seconds * 1_000)"
    }
}

struct PrimaryMediaHistogram: Sendable {
    // Inclusive upper bounds; first bin also contains negative relative PTS drift.
    // 80/150 ms are explicit USB/Wi-Fi release thresholds.
    static let upperBoundsMS: [Double] = [0, 1, 5, 10, 20, 50, 80, 100, 150, 250, 500, 1_000, .infinity]
    private(set) var counts = [UInt64](repeating: 0, count: upperBoundsMS.count)
    private(set) var sampleCount: UInt64 = 0
    private(set) var maximumMilliseconds: Double = -.infinity
    private(set) var minimumMilliseconds: Double = .infinity
    mutating func observe(seconds: Double) {
        let ms = seconds * 1_000
        let bin = Self.upperBoundsMS.firstIndex(where: { ms <= $0 }) ?? (counts.count - 1)
        counts[bin] = primarySaturatingAdd(counts[bin], 1)
        sampleCount = primarySaturatingAdd(sampleCount, 1)
        maximumMilliseconds = max(maximumMilliseconds, ms)
        minimumMilliseconds = min(minimumMilliseconds, ms)
    }

    var percentile95UpperBoundMilliseconds: Double? {
        guard sampleCount > 0 else { return nil }
        let whole = (sampleCount / 100) * 95
        let remainder = sampleCount % 100
        let rank = max(UInt64(1), whole + ((remainder * 95 + 99) / 100))
        var cumulative: UInt64 = 0
        for (index, count) in counts.enumerated() {
            cumulative = primarySaturatingAdd(cumulative, count)
            if cumulative >= rank { return Self.upperBoundsMS[index] }
        }
        return .infinity
    }
}

struct PrimaryMediaSummary: Sendable {
    let generation: UInt64
    let terminal: Bool
    let elapsedSeconds: Double
    let retainedSlots: Int
    let counters: [PrimaryMediaCounter: UInt64]
    let histograms: [PrimaryMediaMetric: PrimaryMediaHistogram]
    let pending: [PrimaryMediaQueue: UInt64]
    let pendingHighWater: [PrimaryMediaQueue: UInt64]
    let oldestTrackedAgeMS: [PrimaryMediaQueue: Double]
    let parserHighWaterBytes: UInt64
    let streamBytes: [UInt64]
    let streamPackets: [UInt64]
    let clockReasons: [PrimaryClockReason: UInt64]
    let clockReasonTracks: [PrimaryClockReason: [UInt64]]
    let clockReanchorOffsets: [PrimaryClockReason: [PrimaryMediaHistogram]]
    let clockActions: [PrimaryClockAction: UInt64]
    let clockTracks: [UInt64]
    let lastClockGeneration: UInt64?
    let clockGenerationChanges: UInt64
    let streamInterarrival: [PrimaryMediaHistogram]
    let streamRelativePTS: [PrimaryMediaHistogram]
    let socketReceiveCalls: [UInt64]
    let socketReceiveBytes: [UInt64]
    let socketReceiveWait: [PrimaryMediaHistogram]
    let socketCallbackWork: [PrimaryMediaHistogram]
    let firstPresentedElapsedMS: Double?
    let inputFrameSamples: [PrimaryInputFrameSample]
    let frameGaps: [PrimaryMediaGapSample]
    let ownerSpans: [PrimaryOwnerSpan]

    private var logFields: [String] {
        let firstPresented = firstPresentedElapsedMS.map { String($0) } ?? "none"
        var fields = ["generation=\(generation)", "terminal=\(terminal ? 1 : 0)",
                      "elapsed_s=\(elapsedSeconds)", "slots=\(retainedSlots)",
                      "parser_high_bytes=\(parserHighWaterBytes)",
                      "stream_order=video,audio,control", "stream_bytes=\(streamBytes)", "stream_packets=\(streamPackets)",
                      "control_completion=contentProcessed_not_device_injection",
                      "input_metric=next_changed_frame_requires_static_response_fixture",
                      "presentation_interval=distinct_frames_requires_continuous_motion_fixture",
                      "oldest_age=tracked_only_if_correlation_lost", "hist_upper_ms=0,1,5,10,20,50,80,100,150,250,500,1000,inf",
                      "first_presented_ms=\(firstPresented)"]
        for key in PrimaryMediaCounter.allCases { fields.append("\(key.rawValue)=\(counters[key, default: 0])") }
        for key in PrimaryMediaQueue.allCases {
            fields.append("\(key.rawValue)_pending=\(pending[key, default: 0])")
            fields.append("\(key.rawValue)_high=\(pendingHighWater[key, default: 0])")
            fields.append("\(key.rawValue)_oldest_tracked_ms=\(oldestTrackedAgeMS[key, default: 0])")
        }
        for key in PrimaryMediaMetric.allCases {
            guard let histogram = histograms[key], histogram.sampleCount > 0 else { continue }
            fields.append("\(key.rawValue)_n=\(histogram.sampleCount),bins=\(histogram.counts),min_ms=\(histogram.minimumMilliseconds),max_ms=\(histogram.maximumMilliseconds)")
            if key == .inputToVisibleChange {
                let p95 = histogram.percentile95UpperBoundMilliseconds.map { String($0) } ?? "none"
                fields.append("inputToVisibleChange_p95_upper_ms=\(p95)")
            }
        }
        for key in PrimaryClockReason.allCases { fields.append("clock_\(key.rawValue)=\(clockReasons[key, default: 0])") }
        for key in [PrimaryClockReason.futureReanchor, .sustainedLateReanchor] {
            fields.append("clock_\(key.rawValue)_tracks_audio_video=\(clockReasonTracks[key] ?? [0, 0])")
            for (track, name) in [(0, "audio"), (1, "video")] {
                guard let values = clockReanchorOffsets[key], values.indices.contains(track) else { continue }
                let histogram = values[track]
                fields.append("clock_\(key.rawValue)_offset_\(name)_n=\(histogram.sampleCount),bins=\(histogram.counts),min_ms=\(histogram.minimumMilliseconds),max_ms=\(histogram.maximumMilliseconds)")
            }
        }
        for key in PrimaryClockAction.allCases { fields.append("clock_\(key.rawValue)=\(clockActions[key, default: 0])") }
        fields.append("clock_tracks_audio_video=\(clockTracks)")
        fields.append("clock_last_generation=\(lastClockGeneration.map(String.init) ?? "none")")
        fields.append("clock_generation_changes=\(clockGenerationChanges)")
        for stream in [PrimaryMediaStream.video, .audio] {
            fields.append("s\(stream.rawValue)_socket_calls=\(socketReceiveCalls[stream.rawValue])")
            fields.append("s\(stream.rawValue)_socket_bytes=\(socketReceiveBytes[stream.rawValue])")
            for (name, histogram) in [("socket_wait", socketReceiveWait[stream.rawValue]),
                                      ("callback_work", socketCallbackWork[stream.rawValue])] {
                fields.append("s\(stream.rawValue)_\(name)_n=\(histogram.sampleCount),bins=\(histogram.counts),min_ms=\(histogram.minimumMilliseconds),max_ms=\(histogram.maximumMilliseconds)")
            }
            for (name, histogram) in [("interarrival", streamInterarrival[stream.rawValue]), ("relativePTS", streamRelativePTS[stream.rawValue])] {
                fields.append("s\(stream.rawValue)_\(name)_n=\(histogram.sampleCount),bins=\(histogram.counts),min_ms=\(histogram.minimumMilliseconds),max_ms=\(histogram.maximumMilliseconds)")
            }
        }
        fields.append(contentsOf: inputFrameSamples.map(\.logField))
        fields.append(contentsOf: frameGaps.map(\.logField))
        fields.append(contentsOf: ownerSpans.map(\.logField))
        return fields
    }

    /// Fixed-size scalar fields, split below the unified-log string limit. Parts
    /// are one summary, not independently scheduled observations.
    var logLines: [String] {
        var chunks: [String] = []
        var chunk = ""
        for field in logFields {
            if !chunk.isEmpty, chunk.utf8.count + field.utf8.count > 650 {
                chunks.append(chunk); chunk = ""
            }
            chunk += (chunk.isEmpty ? "" : " ") + field
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks.enumerated().map { index, value in
            "generation=\(generation) elapsed_s=\(elapsedSeconds) terminal=\(terminal ? 1 : 0) part=\(index + 1)/\(chunks.count) \(value)"
        }
    }
}

/// Opt-in, fixed-capacity scalar accounting. No timers and no per-observation log.
/// The sole sink receives a bounded aggregate outside the lock, at most every 5 s
/// on existing receive activity, and once on the owner's terminal transition.
final class PrimaryMediaDiagnostics: @unchecked Sendable {
    static let capacity = 128
    static let inputProbeCapacity = 128
    static let inputProbeMaximumAge: TimeInterval = 2
    typealias Sink = @Sendable (PrimaryMediaSummary) -> Void
    private struct Entry {
        let sequence: UInt64
        var sourceSequence: UInt64?
        var epoch: UInt32?
        var presentationTimeUs: UInt64?
        var relativeArrivalMS: Double?
        var times: [Double?] = Array(repeating: nil, count: PrimaryMediaStage.allCases.count)
        var queues: [PrimaryMediaQueue: Double] = [:]
        var finished = false
    }
    private struct Reference {
        let epoch: UInt32
        let arrival: Double
        let pts: UInt64
        var lastPTS: UInt64
        var lastArrival: Double
        var lastSequence: UInt64
        var lastSourceSequence: UInt64?
    }
    private struct InputProbe {
        let sequence: UInt64
        let dispatchedAt: Double
        let dispatchEpochMS: Double
    }
    let generation: UInt64
    private let now: @Sendable () -> Double
    private let sink: Sink
    private let lock = NSLock()
    private let started: Double
    private var lastSummary: Double
    private var terminal = false
    private var nextSequence: UInt64 = 0
    private var entries = Array(repeating: Array<Entry?>(repeating: nil, count: capacity), count: 3)
    private var references: [Reference?] = Array(repeating: nil, count: 3)
    private var counters = Dictionary(uniqueKeysWithValues: PrimaryMediaCounter.allCases.map { ($0, UInt64(0)) })
    private var histograms = Dictionary(uniqueKeysWithValues: PrimaryMediaMetric.allCases.map { ($0, PrimaryMediaHistogram()) })
    private var pending = Dictionary(uniqueKeysWithValues: PrimaryMediaQueue.allCases.map { ($0, UInt64(0)) })
    private var high = Dictionary(uniqueKeysWithValues: PrimaryMediaQueue.allCases.map { ($0, UInt64(0)) })
    private var parserHigh: UInt64 = 0
    private var streamBytes = [UInt64](repeating: 0, count: 3)
    private var streamPackets = [UInt64](repeating: 0, count: 3)
    private var clockReasons = Dictionary(uniqueKeysWithValues: PrimaryClockReason.allCases.map { ($0, UInt64(0)) })
    private var clockReasonTracks = Dictionary(uniqueKeysWithValues: PrimaryClockReason.allCases.map {
        ($0, [UInt64](repeating: 0, count: 2))
    })
    private var clockReanchorOffsets = Dictionary(uniqueKeysWithValues:
        [PrimaryClockReason.futureReanchor, .sustainedLateReanchor].map {
            ($0, [PrimaryMediaHistogram](repeating: PrimaryMediaHistogram(), count: 2))
        })
    private var clockActions = Dictionary(uniqueKeysWithValues: PrimaryClockAction.allCases.map { ($0, UInt64(0)) })
    private var clockTracks = [UInt64](repeating: 0, count: 2)
    private var lastClockGeneration: UInt64?
    private var clockGenerationChanges: UInt64 = 0
    private var streamInterarrival = [PrimaryMediaHistogram](repeating: PrimaryMediaHistogram(), count: 3)
    private var streamRelativePTS = [PrimaryMediaHistogram](repeating: PrimaryMediaHistogram(), count: 3)
    private var socketReceiveCalls = [UInt64](repeating: 0, count: 3)
    private var socketReceiveBytes = [UInt64](repeating: 0, count: 3)
    private var socketReceiveWait = [PrimaryMediaHistogram](repeating: PrimaryMediaHistogram(), count: 3)
    private var socketCallbackWork = [PrimaryMediaHistogram](repeating: PrimaryMediaHistogram(), count: 3)
    private var inputProbes: [InputProbe] = []
    private var inputFrameSamples: [PrimaryInputFrameSample] = []
    private var lastPresentedSignature: PrimaryFrameSignature?
    private var firstPresentedAt: Double?
    private var lastPresentedFrame: PrimaryGapEndpoint?
    // Whole-run top eight in each of three boundaries: video receipt, audio
    // receipt and distinct video presentation. No per-frame logging/timers.
    private var frameGaps: [PrimaryMediaGapSample] = []
    private var ownerSpans: [PrimaryOwnerSpan] = []

    static func isEnabled(arguments: [String], bundleID: String?) -> Bool {
#if GALAXYBRIDGE_APP_STORE
        return false
#else
        return bundleID == "com.xopmc.GalaxyBridge.internal" && arguments.contains("--primary-media-diagnostics")
#endif
    }

    static func make(enabled: Bool, factory: () -> PrimaryMediaDiagnostics) -> PrimaryMediaDiagnostics? {
        enabled ? factory() : nil
    }

    init(generation: UInt64, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         startedAt explicitStart: Double? = nil,
         sink: @escaping Sink) {
        self.generation = generation
        self.now = now
        self.sink = sink
        let current = now()
        let candidate = explicitStart ?? current
        let start = candidate.isFinite && candidate >= 0 ? candidate : (current.isFinite ? current : 0)
        started = start
        lastSummary = started
    }

    static func logging(generation: UInt64, bundleID: String, startedAt: Double? = nil) -> PrimaryMediaDiagnostics {
        let logger = Logger(subsystem: bundleID, category: "PrimaryMediaDiagnostics")
        return PrimaryMediaDiagnostics(generation: generation, startedAt: startedAt) { summary in
            for line in summary.logLines { logger.info("\(line, privacy: .public)") }
        }
    }

    func received(stream: PrimaryMediaStream, bytes: Int, pts: UInt64?, epoch: UInt32?,
                  now explicitNow: Double? = nil, isPacket: Bool = true,
                  sourceSequence: UInt64? = nil) -> PrimaryMediaTrace? {
        let time = explicitNow ?? now()
        return lock.withLock {
            guard !terminal else { return nil }
            guard time.isFinite, time >= 0, bytes >= 0 else { bump(.invalidTimestamp); return nil }
            guard nextSequence < UInt64.max else { bump(.correlationLost); return nil }
            nextSequence += 1
            let index = Int(nextSequence % UInt64(Self.capacity))
            if let old = entries[stream.rawValue][index], !old.finished { bump(.correlationLost) }
            var entry = Entry(sequence: nextSequence)
            entry.sourceSequence = sourceSequence
            entry.epoch = epoch
            entry.presentationTimeUs = pts
            entry.times[PrimaryMediaStage.received.rawValue] = time
            if stream != .control && isPacket {
                bump(.parsedBytes, by: UInt64(bytes)); bump(.parsedPackets)
                streamBytes[stream.rawValue] = primarySaturatingAdd(streamBytes[stream.rawValue], UInt64(bytes))
                streamPackets[stream.rawValue] = primarySaturatingAdd(streamPackets[stream.rawValue], 1)
            }
            if let pts, let epoch {
                if var reference = references[stream.rawValue], reference.epoch == epoch {
                    if pts < reference.lastPTS || time < reference.lastArrival {
                        bump(.invalidTimestamp)
                    } else {
                        observe(.interarrival, time - reference.lastArrival)
                        let relativeArrival = (time - reference.arrival) - Double(pts - reference.pts) / 1_000_000
                        observe(.relativePTS, relativeArrival)
                        entry.relativeArrivalMS = relativeArrival * 1_000
                        streamInterarrival[stream.rawValue].observe(seconds: time - reference.lastArrival)
                        streamRelativePTS[stream.rawValue].observe(seconds: (time - reference.arrival) - Double(pts - reference.pts) / 1_000_000)
                        retainGap(stage: .received, stream: stream,
                            before: PrimaryGapEndpoint(sequence: reference.lastSequence,
                                sourceSequence: reference.lastSourceSequence, pts: reference.lastPTS,
                                epoch: epoch, time: reference.lastArrival),
                            after: PrimaryGapEndpoint(sequence: nextSequence, sourceSequence: sourceSequence,
                                pts: pts, epoch: epoch, time: time))
                        reference.lastPTS = pts; reference.lastArrival = time
                        reference.lastSequence = nextSequence; reference.lastSourceSequence = sourceSequence
                        references[stream.rawValue] = reference
                    }
                } else {
                    references[stream.rawValue] = Reference(epoch: epoch, arrival: time, pts: pts, lastPTS: pts,
                        lastArrival: time, lastSequence: nextSequence, lastSourceSequence: sourceSequence)
                    entry.relativeArrivalMS = 0
                }
            }
            entries[stream.rawValue][index] = entry
            return PrimaryMediaTrace(collector: self, stream: stream, sequence: nextSequence)
        }
    }

    func parser(rawBytes: Int, retainedBytes: Int) {
        lock.withLock {
            guard !terminal else { return }
            bump(.rawBytes, by: UInt64(max(0, rawBytes)))
            parserHigh = max(parserHigh, UInt64(max(0, retainedBytes)))
        }
    }

    /// Measures only scalar socket timing. `armedAt → callbackAt` excludes the
    /// previous callback's parser work; `callbackAt → completedAt` contains the
    /// local parser and synchronous event admission. This cleanly separates an
    /// upstream/ADB stall from a local receive-loop stall without changing the
    /// media bytes or their scheduling.
    func socketReceived(stream: PrimaryMediaStream, bytes: Int, armedAt: Double, callbackAt: Double) {
        lock.withLock {
            guard !terminal, bytes >= 0, armedAt.isFinite, callbackAt.isFinite,
                  armedAt >= 0, callbackAt >= armedAt else {
                if !terminal { bump(.invalidTimestamp) }
                return
            }
            socketReceiveCalls[stream.rawValue] = primarySaturatingAdd(socketReceiveCalls[stream.rawValue], 1)
            socketReceiveBytes[stream.rawValue] = primarySaturatingAdd(socketReceiveBytes[stream.rawValue], UInt64(bytes))
            socketReceiveWait[stream.rawValue].observe(seconds: callbackAt - armedAt)
        }
    }

    func socketCallbackCompleted(stream: PrimaryMediaStream, callbackAt: Double, completedAt: Double) {
        lock.withLock {
            guard !terminal, callbackAt.isFinite, completedAt.isFinite,
                  callbackAt >= 0, completedAt >= callbackAt else {
                if !terminal { bump(.invalidTimestamp) }
                return
            }
            socketCallbackWork[stream.rawValue].observe(seconds: completedAt - callbackAt)
        }
    }

    func count(_ counter: PrimaryMediaCounter) { lock.withLock { if !terminal { bump(counter) } } }

    func enter(_ queue: PrimaryMediaQueue, trace: PrimaryMediaTrace, now explicitNow: Double? = nil) {
        let time = explicitNow ?? now()
        lock.withLock {
            guard accepts(trace), time.isFinite else { return }
            if entry(trace)?.queues[queue] != nil { bump(.queueImbalance); return }
            pending[queue] = primarySaturatingAdd(pending[queue, default: 0], 1)
            high[queue] = max(high[queue, default: 0], pending[queue, default: 0])
            update(trace) { $0.queues[queue] = time }
        }
    }

    func leave(_ queue: PrimaryMediaQueue, trace: PrimaryMediaTrace, now explicitNow: Double? = nil) {
        lock.withLock {
            guard accepts(trace) else { return }
            if let entry = entry(trace), entry.queues[queue] == nil { bump(.queueImbalance); return }
            if pending[queue, default: 0] > 0 { pending[queue, default: 0] -= 1 } else { bump(.queueImbalance) }
            update(trace) { $0.queues.removeValue(forKey: queue) }
        }
    }

    func mark(_ stage: PrimaryMediaStage, trace: PrimaryMediaTrace, now explicitNow: Double? = nil) {
        let time = explicitNow ?? now()
        lock.withLock {
            guard accepts(trace), time.isFinite, time >= 0 else { return }
            let previous: PrimaryMediaStage
            let metric: PrimaryMediaMetric
            switch stage {
            case .received: return
            case .actor: previous = .received; metric = .receiveToActor
            case .decoder: previous = .actor; metric = .actorToDecoder
            case .submitted: previous = .decoder; metric = .decoderToSubmit
            case .callback: previous = .submitted; metric = .submitToCallback
            case .delivered: previous = .callback; metric = .callbackToDelivery
            case .appModel: previous = .delivered; metric = .deliveryToAppModel
            case .surface: previous = .appModel; metric = .appModelToSurface
            }
            guard var entry = entry(trace) else { bump(.missingCorrelation); return }
            if let start = entry.times[previous.rawValue] { observe(metric, time - start) }
            entry.times[stage.rawValue] = time
            entries[trace.stream.rawValue][slot(trace)] = entry
        }
    }

    func finish(_ trace: PrimaryMediaTrace, reason: PrimaryMediaCounter? = nil) {
        lock.withLock {
            guard accepts(trace) else { return }
            if let reason { bump(reason) }
            update(trace) { $0.finished = true }
        }
    }

    func duration(_ metric: PrimaryMediaMetric, seconds: Double) {
        lock.withLock { if !terminal { observe(metric, seconds) } }
    }

    /// Whole-run scheduler observations on the same host clock as frame gaps.
    /// Work includes callbacks/FFI; wait includes condition-lock acquisition.
    /// Cadence also includes the time outside either measured span. These are
    /// elapsed durations (including descheduling), not CPU-time measurements.
    func ownerSpan(_ metric: PrimaryMediaMetric, start: Double, end: Double) {
        lock.withLock {
            guard !terminal else { return }
            guard metric == .ownerWork || metric == .ownerWait || metric == .ownerCadence,
                  start.isFinite, end.isFinite, start >= 0, end >= start else {
                bump(.invalidTimestamp); return
            }
            let span = PrimaryOwnerSpan(metric: metric, start: start, end: end)
            observe(metric, span.seconds)
            guard span.seconds >= 0.100 else { return }
            let group = ownerSpans.indices.filter { ownerSpans[$0].metric == metric }
            if group.count < 8 {
                ownerSpans.append(span)
            } else if let smallest = group.min(by: { ownerSpans[$0].seconds < ownerSpans[$1].seconds }),
                      span.seconds > ownerSpans[smallest].seconds {
                ownerSpans[smallest] = span
            }
        }
    }

    func inputDispatched(
        trace: PrimaryMediaTrace,
        at time: Double,
        epochMS: Double = Date().timeIntervalSince1970 * 1_000
    ) {
        lock.withLock {
            guard accepts(trace), time.isFinite, time >= 0, epochMS.isFinite, epochMS >= 0 else { return }
            let expirationThreshold = time - Self.inputProbeMaximumAge
            let expired = inputProbes.reduce(into: UInt64(0)) { count, probe in
                if probe.dispatchedAt < expirationThreshold { count = primarySaturatingAdd(count, 1) }
            }
            inputProbes.removeAll { $0.dispatchedAt < expirationThreshold }
            bump(.inputProbeExpired, by: expired)
            if inputProbes.count == Self.inputProbeCapacity {
                inputProbes.removeFirst()
                bump(.inputProbeExpired)
            }
            inputProbes.append(InputProbe(sequence: trace.sequence, dispatchedAt: time, dispatchEpochMS: epochMS))
        }
    }

    func cancelInputProbe(trace: PrimaryMediaTrace) {
        lock.withLock { inputProbes.removeAll { $0.sequence == trace.sequence } }
    }

    func drawablePresented(
        trace: PrimaryMediaTrace,
        submittedAt: Double,
        presentedAt: Double,
        signature: PrimaryFrameSignature?
    ) {
        lock.withLock {
            guard accepts(trace), trace.stream == .video,
                  submittedAt.isFinite, presentedAt.isFinite, presentedAt >= submittedAt else {
                if !terminal { bump(.drawableSkipped) }
                return
            }
            bump(.drawablePresented)
            observe(.metalToPresented, presentedAt - submittedAt)
            if firstPresentedAt == nil { firstPresentedAt = presentedAt }
            // The time to present a single submitted drawable does not reveal
            // a stall before submission. Count distinct source frames at the
            // actual display boundary. Redrawing a retained frame must not
            // hide a pause; late/out-of-order callbacks must not move the anchor.
            let metadata = entry(trace)
            let endpoint = PrimaryGapEndpoint(sequence: trace.sequence, sourceSequence: metadata?.sourceSequence,
                pts: metadata?.presentationTimeUs, epoch: metadata?.epoch, time: presentedAt)
            if let previous = lastPresentedFrame {
                if trace.sequence > previous.sequence, presentedAt >= previous.time {
                    observe(.presentationInterval, presentedAt - previous.time)
                    retainGap(stage: .presented, stream: .video, before: previous, after: endpoint)
                    lastPresentedFrame = endpoint
                }
            } else {
                lastPresentedFrame = endpoint
            }
            guard let signature else { return }
            defer { lastPresentedSignature = signature }
            guard let previous = lastPresentedSignature,
                  signature.isVisiblyDifferent(from: previous),
                  let frameEntry = entry(trace),
                  let receivedAt = frameEntry.times[PrimaryMediaStage.received.rawValue]
            else { return }
            var retained: [InputProbe] = []
            retained.reserveCapacity(inputProbes.count)
            var latestEligible: InputProbe?
            for probe in inputProbes {
                if presentedAt - probe.dispatchedAt > Self.inputProbeMaximumAge {
                    bump(.inputProbeExpired)
                } else if probe.dispatchedAt <= receivedAt {
                    // A frame can prove only one input-to-visible sample. A
                    // drag produces many coalescible move events before the
                    // next decoded frame; recording all of them assigns the
                    // same visual response to stale intermediate positions
                    // and turns gesture duration into apparent latency.
                    if latestEligible.map({ probe.dispatchedAt > $0.dispatchedAt }) ?? true {
                        latestEligible = probe
                    }
                } else {
                    // This input was dispatched after the frame reached the
                    // Mac and cannot have caused it. Keep it for a later
                    // visibly changed frame.
                    retained.append(probe)
                }
            }
            if let latestEligible {
                observe(.inputToFrameReceived, receivedAt - latestEligible.dispatchedAt)
                observe(.frameReceivedToVisibleChange, presentedAt - receivedAt)
                observe(.inputToVisibleChange, presentedAt - latestEligible.dispatchedAt)
                if let videoPTSUs = frameEntry.presentationTimeUs {
                    if inputFrameSamples.count == Self.inputProbeCapacity {
                        inputFrameSamples.removeFirst()
                    }
                    inputFrameSamples.append(PrimaryInputFrameSample(
                        inputSequence: latestEligible.sequence,
                        frameSequence: frameEntry.sequence,
                        videoPTSUs: videoPTSUs,
                        inputDispatchEpochMS: latestEligible.dispatchEpochMS,
                        relativeVideoArrivalMS: frameEntry.relativeArrivalMS,
                        inputToFrameMS: (receivedAt - latestEligible.dispatchedAt) * 1_000,
                        frameToVisibleMS: (presentedAt - receivedAt) * 1_000
                    ))
                }
            }
            inputProbes = retained
        }
    }

    func stageTime(_ stage: PrimaryMediaStage, trace: PrimaryMediaTrace) -> Double? {
        lock.withLock {
            guard accepts(trace) else { return nil }
            guard let entry = entry(trace) else { bump(.missingCorrelation); return nil }
            return entry.times[stage.rawValue]
        }
    }

    func clock(
        reason: PrimaryClockReason,
        action: PrimaryClockAction,
        audio: Bool,
        generation: UInt64,
        offsetSeconds: TimeInterval? = nil
    ) {
        lock.withLock {
            guard !terminal else { return }
            let track = audio ? 0 : 1
            bump(.clockDecisions)
            clockReasons[reason] = primarySaturatingAdd(clockReasons[reason, default: 0], 1)
            var reasonTracks = clockReasonTracks[reason] ?? [0, 0]
            reasonTracks[track] = primarySaturatingAdd(reasonTracks[track], 1)
            clockReasonTracks[reason] = reasonTracks
            if let offsetSeconds, offsetSeconds.isFinite,
               reason == .futureReanchor || reason == .sustainedLateReanchor,
               var offsets = clockReanchorOffsets[reason] {
                offsets[track].observe(seconds: offsetSeconds)
                clockReanchorOffsets[reason] = offsets
            }
            clockActions[action] = primarySaturatingAdd(clockActions[action, default: 0], 1)
            clockTracks[track] = primarySaturatingAdd(clockTracks[track], 1)
            if let lastClockGeneration, lastClockGeneration != generation {
                clockGenerationChanges = primarySaturatingAdd(clockGenerationChanges, 1)
            }
            lastClockGeneration = generation
        }
    }

    func snapshot(now time: Double) -> PrimaryMediaSummary { lock.withLock { summary(now: time, terminal: terminal) } }

    func emitIfDue(now explicitNow: Double? = nil) {
        let time = explicitNow ?? now()
        let value: PrimaryMediaSummary? = lock.withLock {
            guard !terminal, time.isFinite, time - lastSummary >= 5 else { return nil }
            lastSummary = time
            return summary(now: time, terminal: false)
        }
        if let value { sink(value) }
    }

    func terminate(now explicitNow: Double? = nil) {
        let time = explicitNow ?? now()
        let value: PrimaryMediaSummary? = lock.withLock {
            guard !terminal else { return nil }
            terminal = true
            for count in pending.values { bump(.incomplete, by: count) }
            let value = summary(now: time, terminal: true)
            for key in PrimaryMediaQueue.allCases { pending[key] = 0 }
            inputProbes.removeAll(keepingCapacity: false)
            lastPresentedSignature = nil
            for stream in 0..<3 { entries[stream] = Array(repeating: nil, count: Self.capacity) }
            return value
        }
        if let value { sink(value) }
    }

    private func accepts(_ trace: PrimaryMediaTrace) -> Bool { !terminal && trace.collector === self }
    private func slot(_ trace: PrimaryMediaTrace) -> Int { Int(trace.sequence % UInt64(Self.capacity)) }
    private func entry(_ trace: PrimaryMediaTrace) -> Entry? {
        let value = entries[trace.stream.rawValue][slot(trace)]
        return value?.sequence == trace.sequence ? value : nil
    }
    private func update(_ trace: PrimaryMediaTrace, body: (inout Entry) -> Void) {
        guard var value = entry(trace) else { bump(.missingCorrelation); return }
        body(&value)
        entries[trace.stream.rawValue][slot(trace)] = value
    }
    private func bump(_ key: PrimaryMediaCounter, by value: UInt64 = 1) {
        counters[key] = primarySaturatingAdd(counters[key, default: 0], value)
    }
    private func observe(_ key: PrimaryMediaMetric, _ seconds: Double) {
        guard seconds.isFinite, abs(seconds) <= Double.greatestFiniteMagnitude / 1_000,
              seconds >= 0 || key == .relativePTS else { bump(.invalidTimestamp); return }
        histograms[key]?.observe(seconds: seconds)
    }
    private func retainGap(stage: PrimaryMediaGapSample.Stage, stream: PrimaryMediaStream,
                           before: PrimaryGapEndpoint, after: PrimaryGapEndpoint) {
        let gap = PrimaryMediaGapSample(stage: stage, stream: stream, before: before, after: after)
        guard stream != .control, gap.seconds.isFinite, gap.seconds >= 0.100 else { return }
        let group = frameGaps.indices.filter { frameGaps[$0].stage == stage && frameGaps[$0].stream == stream }
        if group.count < 8 {
            frameGaps.append(gap)
        } else if let smallest = group.min(by: { frameGaps[$0].seconds < frameGaps[$1].seconds }),
                  gap.seconds > frameGaps[smallest].seconds {
            frameGaps[smallest] = gap
        }
    }
    private func summary(now time: Double, terminal: Bool) -> PrimaryMediaSummary {
        var oldest: [PrimaryMediaQueue: Double] = [:]
        var retained = 0
        for stream in entries {
            for case let entry? in stream {
                retained += 1
                for (queue, start) in entry.queues where time.isFinite {
                    oldest[queue] = max(oldest[queue, default: 0], max(0, time - start) * 1_000)
                }
            }
        }
        return PrimaryMediaSummary(generation: generation, terminal: terminal,
            elapsedSeconds: time.isFinite ? max(0, time - started) : 0, retainedSlots: retained,
            counters: counters, histograms: histograms, pending: pending, pendingHighWater: high,
            oldestTrackedAgeMS: oldest, parserHighWaterBytes: parserHigh, streamBytes: streamBytes,
            streamPackets: streamPackets, clockReasons: clockReasons, clockReasonTracks: clockReasonTracks,
            clockReanchorOffsets: clockReanchorOffsets, clockActions: clockActions, clockTracks: clockTracks,
            lastClockGeneration: lastClockGeneration, clockGenerationChanges: clockGenerationChanges,
            streamInterarrival: streamInterarrival, streamRelativePTS: streamRelativePTS,
            socketReceiveCalls: socketReceiveCalls, socketReceiveBytes: socketReceiveBytes,
            socketReceiveWait: socketReceiveWait, socketCallbackWork: socketCallbackWork,
            firstPresentedElapsedMS: firstPresentedAt.map { max(0, $0 - started) * 1_000 },
            inputFrameSamples: inputFrameSamples, frameGaps: frameGaps, ownerSpans: ownerSpans)
    }
}

/// A tiny in-memory luma sample used only by opt-in Internal latency diagnostics.
/// No pixel values leave the process or appear in logs.
struct PrimaryFrameSignature: Equatable, Sendable {
    // A 12x12 grid detects full-screen scrolling well, but can miss a keypad
    // digit or a compact toggle completely. 24x24 is still only 576 luma
    // reads per presented frame and remains Internal-diagnostics-only.
    static let side = 24
    let luma: [UInt8]

    static func sample(_ pixelBuffer: CVPixelBuffer) -> PrimaryFrameSignature? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) > 0,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) > 0
        else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var values: [UInt8] = []
        values.reserveCapacity(side * side)
        for row in 0..<side {
            let y = side == 1 ? 0 : row * (height - 1) / (side - 1)
            for column in 0..<side {
                let x = side == 1 ? 0 : column * (width - 1) / (side - 1)
                values.append(bytes[y * bytesPerRow + x])
            }
        }
        return PrimaryFrameSignature(luma: values)
    }

    func isVisiblyDifferent(from other: PrimaryFrameSignature) -> Bool {
        guard luma.count == other.luma.count, !luma.isEmpty else { return true }
        var localizedChanges = 0
        let total = zip(luma, other.luma).reduce(0) { partial, pair in
            let difference = abs(Int(pair.0) - Int(pair.1))
            if difference >= 12 { localizedChanges += 1 }
            return partial + difference
        }
        return total >= luma.count * 2 || localizedChanges >= 3
    }
}

/// A scalar context held by Metal's existing drawable lifetime, not the collector.
struct PrimaryDrawableMeasurement: Sendable {
    let trace: PrimaryMediaTrace
    let submittedAt: Double
    let signature: PrimaryFrameSignature?

    init(trace: PrimaryMediaTrace, pixelBuffer: CVPixelBuffer? = nil,
         submittedAt: Double = ProcessInfo.processInfo.systemUptime) {
        self.trace = trace
        self.submittedAt = submittedAt
        signature = pixelBuffer.flatMap(PrimaryFrameSignature.sample)
        trace.collector.count(.metalSubmitted)
        if let surfaceAt = trace.collector.stageTime(.surface, trace: trace) {
            trace.collector.duration(.surfaceToMetal, seconds: submittedAt - surfaceAt)
        }
    }

    func presented(at presentedTime: Double) {
        guard presentedTime.isFinite, presentedTime > 0 else {
            trace.collector.count(.drawableSkipped)
            return
        }
        trace.collector.drawablePresented(
            trace: trace,
            submittedAt: submittedAt,
            presentedAt: presentedTime,
            signature: signature
        )
    }
}

private func primarySaturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : value
}
