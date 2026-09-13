import Foundation
import CoreMedia
import CoreVideo
import GalaxyBridgeCore
import Testing
import AppKit
@testable import GalaxyBridgeMac

@Suite(.serialized)
struct PrimaryMediaDiagnosticsTests {
    @Test func ownerWorkAndWaitRemainSeparateWithLateBoundedOutliers() {
        let meter = PrimaryMediaDiagnostics(generation: 12, now: { 0 }, sink: { _ in })
        for index in 0..<1_000 {
            let start = Double(index)
            meter.ownerSpan(.ownerWork, start: start, end: start + 0.001)
            meter.ownerSpan(.ownerWait, start: start + 0.001, end: start + 0.002)
        }
        for index in 1...20 {
            let start = 1_000 + Double(index)
            meter.ownerSpan(.ownerWait, start: start, end: start + Double(index) / 10)
        }
        meter.ownerSpan(.ownerWork, start: 1_100, end: 1_100.5)
        meter.ownerSpan(.ownerCadence, start: 1_100, end: 1_100.502)
        let summary = meter.snapshot(now: 1_101)
        #expect(summary.histograms[.ownerWork]?.sampleCount == 1_001)
        #expect(summary.histograms[.ownerWait]?.sampleCount == 1_020)
        #expect(summary.histograms[.ownerWork]?.maximumMilliseconds == 500)
        #expect(summary.histograms[.ownerWait]?.maximumMilliseconds == 2_000)
        #expect(summary.ownerSpans.filter { $0.metric == .ownerWait }.count == 8)
        #expect(summary.ownerSpans.count == 10)
        #expect(summary.ownerSpans.contains { $0.metric == .ownerWait && $0.start == 1_020 })
        #expect(!summary.ownerSpans.contains { $0.metric == .ownerWait && $0.start == 1_001 })
        #expect(summary.logLines.joined().contains("ownerSpan=ownerWork,start_uptime_s:1100.0,end_uptime_s:1100.5"))
        #expect(summary.logLines.allSatisfy { $0.utf8.count < 900 })
    }

    @Test func ownerSpanRejectsInvalidClockAndCannotReviveTerminalCollector() {
        let meter = PrimaryMediaDiagnostics(generation: 13, now: { 0 }, sink: { _ in })
        meter.ownerSpan(.ownerWait, start: .nan, end: 2)
        meter.ownerSpan(.ownerWait, start: 1, end: .infinity)
        meter.ownerSpan(.ownerWait, start: 2, end: 1)
        meter.ownerSpan(.ownerWait, start: -1, end: 0)
        meter.ownerSpan(.interarrival, start: 0, end: 1)
        #expect(meter.snapshot(now: 2).counters[.invalidTimestamp] == 5)
        #expect(meter.snapshot(now: 2).histograms[.ownerWait]?.sampleCount == 0)
        #expect(meter.snapshot(now: 2).ownerSpans.isEmpty)
        meter.terminate(now: 2)
        meter.ownerSpan(.ownerWait, start: 3, end: 4)
        #expect(meter.snapshot(now: 4).ownerSpans.isEmpty)
    }

    @Test func lateWholeRunGapRetainsItsFrameAndClockBoundaries() throws {
        let meter = PrimaryMediaDiagnostics(generation: 7, now: { 0 }, sink: { _ in })
        for index in 0..<20_000 {
            let time = Double(index) * 0.02
            let frame = try #require(meter.received(stream: .video, bytes: 1,
                pts: UInt64(index) * 20_000, epoch: 3, now: time))
            meter.drawablePresented(trace: frame, submittedAt: time, presentedAt: time + 0.005, signature: nil)
        }
        let late = try #require(meter.received(stream: .video, bytes: 1,
            pts: 400_000_000, epoch: 3, now: 401.48))
        meter.drawablePresented(trace: late, submittedAt: 401.48, presentedAt: 401.485, signature: nil)
        let text = meter.snapshot(now: 402).logLines.joined(separator: " ")
        #expect(text.contains("frameGap=received,stream:0"))
        #expect(text.contains("frameGap=presented,stream:0"))
        #expect(text.contains("before_frame:20000,after_frame:20001"))
        #expect(text.contains("before_pts_us:399980000,after_pts_us:400000000"))
        #expect(text.contains("before_epoch:3,after_epoch:3"))
    }

    @Test func wholeRunGapsAreBoundedKeepLargestAndSeparateAudioFromVideo() throws {
        let meter = PrimaryMediaDiagnostics(generation: 8, now: { 0 }, sink: { _ in })
        for index in 0..<30 {
            for stream in [PrimaryMediaStream.video, .audio] {
                _ = meter.received(stream: stream, bytes: 1, pts: UInt64(index), epoch: 1,
                    now: Double(index * index))
            }
        }
        let text = meter.snapshot(now: 900).logLines.joined(separator: " ")
        // Eight largest intervals in each independent boundary, not the first eight.
        #expect(text.components(separatedBy: "frameGap=received,stream:0").count - 1 == 8)
        #expect(text.components(separatedBy: "frameGap=received,stream:1").count - 1 == 8)
        #expect(text.contains("before_frame:57,after_frame:59"))
        #expect(!text.contains("before_frame:1,after_frame:3"))
        #expect(meter.snapshot(now: 900).logLines.allSatisfy { $0.utf8.count < 900 })
    }

    @Test func gapCorrelationKeepsNativeSequenceWithoutTreatingRedrawAsProgress() throws {
        let meter = PrimaryMediaDiagnostics(generation: 9, now: { 0 }, sink: { _ in })
        let first = try #require(meter.received(stream: .video, bytes: 1, pts: 100, epoch: 1,
            now: 1, sourceSequence: 300))
        meter.drawablePresented(trace: first, submittedAt: 1, presentedAt: 1.01, signature: nil)
        meter.drawablePresented(trace: first, submittedAt: 2, presentedAt: 2.01, signature: nil)
        let second = try #require(meter.received(stream: .video, bytes: 1, pts: 200, epoch: 1,
            now: 2.5, sourceSequence: 390))
        meter.drawablePresented(trace: second, submittedAt: 2.5, presentedAt: 2.51, signature: nil)
        let snapshot = meter.snapshot(now: 3)
        #expect(snapshot.frameGaps.count == 2)
        #expect(snapshot.frameGaps.allSatisfy {
            $0.before.sourceSequence == 300 && $0.after.sourceSequence == 390 && abs($0.seconds - 1.5) < 0.001
        })
        meter.terminate(now: 3)
        #expect(meter.received(stream: .video, bytes: 1, pts: 500, epoch: 1, now: 10) == nil)
        #expect(meter.snapshot(now: 10).frameGaps.count == 2)
    }

    @Test func presentationIntervalDetectsPauseWithoutConfusingFastDecodeWithSmoothPlayback() throws {
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        for time in [10.0, 10.02, 11.52] {
            let frame = try #require(meter.received(stream: .video, bytes: 1,
                pts: UInt64(time * 1_000_000), epoch: 1, now: time - 0.01))
            meter.drawablePresented(trace: frame, submittedAt: time - 0.005,
                presentedAt: time, signature: nil)
        }
        let snapshot = meter.snapshot(now: 12)
        let gap = try #require(snapshot.histograms.first { $0.key.rawValue == "presentationInterval" }?.value)
        #expect(gap.sampleCount == 2) // Startup delay is not an inter-frame pause.
        #expect(abs(gap.maximumMilliseconds - 1_500) < 0.001)
        #expect(snapshot.histograms[.metalToPresented]?.maximumMilliseconds ?? 0 < 6)
    }

    @Test func redisplayingOldFrameCannotConcealPresentationPause() throws {
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        let first = try #require(meter.received(stream: .video, bytes: 1, pts: 1, epoch: 1, now: 1))
        let second = try #require(meter.received(stream: .video, bytes: 1, pts: 2, epoch: 1, now: 1.02))
        meter.drawablePresented(trace: first, submittedAt: 1, presentedAt: 1.01, signature: nil)
        meter.drawablePresented(trace: first, submittedAt: 2, presentedAt: 2.01, signature: nil)
        meter.drawablePresented(trace: second, submittedAt: 2, presentedAt: 2.02, signature: nil)
        // An older drawable callback may be delivered late: it must not reset the clock.
        meter.drawablePresented(trace: first, submittedAt: 1, presentedAt: 1.005, signature: nil)
        let third = try #require(meter.received(stream: .video, bytes: 1, pts: 3, epoch: 1, now: 2.02))
        meter.drawablePresented(trace: third, submittedAt: 2.02, presentedAt: 2.04, signature: nil)
        let gap = try #require(meter.snapshot(now: 3).histograms.first {
            $0.key.rawValue == "presentationInterval"
        }?.value)
        #expect(gap.sampleCount == 2)
        #expect(abs(gap.maximumMilliseconds - 1_010) < 0.001)
    }

    @Test func clockGenerationAndBoundedLogRecords() {
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        let clock = MediaPlayoutClock(diagnostics: meter)
        _ = clock.decision(track: .video, presentationTimeUs: 1, epoch: 1, now: 0)
        _ = clock.decision(track: .audio, presentationTimeUs: 1, epoch: 2, now: 0)
        for metric in PrimaryMediaMetric.allCases { meter.duration(metric, seconds: 0.01) }
        let summary = meter.snapshot(now: 5)
        #expect(summary.clockGenerationChanges == 1)
        #expect(summary.lastClockGeneration == 2)
        #expect(summary.logLines.allSatisfy { $0.utf8.count < 900 })
        #expect(summary.logLines.joined().contains("metalToPresented_n=1"))
    }

    @Test func customVideoLeadChangesOnlyTheInitialSchedule() {
        let standard = MediaPlayoutClock()
        let interactive = MediaPlayoutClock(leadTime: 0.010)
        #expect(standard.decision(track: .video, presentationTimeUs: 1_000_000, epoch: 1, now: 2)
            == MediaPlayoutDecision(action: .schedule(2.060), generation: 1))
        #expect(interactive.decision(track: .video, presentationTimeUs: 1_000_000, epoch: 1, now: 2)
            == MediaPlayoutDecision(action: .schedule(2.010), generation: 1))
    }

    @Test func missingVideoPTSIsImmediateButStillHonorsEpochOwnership() {
        let clock = MediaPlayoutClock()
        let first = clock.decision(track: .video, presentationTimeUs: nil, epoch: 7, now: 2)
        let sameEpoch = clock.decision(track: .video, presentationTimeUs: nil, epoch: 7, now: 3)
        let nextEpoch = clock.decision(track: .video, presentationTimeUs: nil, epoch: 8, now: 4)
        #expect(first.action == .immediate)
        #expect(sameEpoch.action == .immediate && sameEpoch.generation == first.generation)
        #expect(nextEpoch.action == .immediate && nextEpoch.generation > first.generation)
    }

    @Test func socketWaitAndLocalCallbackWorkAreMeasuredSeparatelyPerStream() {
        let meter = PrimaryMediaDiagnostics(generation: 91, now: { 0 }, sink: { _ in })
        meter.socketReceived(stream: .video, bytes: 4_096, armedAt: 1, callbackAt: 1.250)
        meter.socketCallbackCompleted(stream: .video, callbackAt: 1.250, completedAt: 1.255)
        meter.socketReceived(stream: .audio, bytes: 512, armedAt: 2, callbackAt: 2.010)
        meter.socketCallbackCompleted(stream: .audio, callbackAt: 2.010, completedAt: 2.090)

        let summary = meter.snapshot(now: 3)
        #expect(summary.socketReceiveCalls == [1, 1, 0])
        #expect(summary.socketReceiveBytes == [4_096, 512, 0])
        #expect(summary.socketReceiveWait[PrimaryMediaStream.video.rawValue].maximumMilliseconds == 250)
        #expect(summary.socketCallbackWork[PrimaryMediaStream.video.rawValue].maximumMilliseconds > 4.9)
        #expect(summary.socketReceiveWait[PrimaryMediaStream.audio.rawValue].maximumMilliseconds > 9.9)
        #expect(summary.socketCallbackWork[PrimaryMediaStream.audio.rawValue].maximumMilliseconds > 79.9)
        let record = summary.logLines.joined(separator: " ")
        #expect(record.contains("s0_socket_calls=1"))
        #expect(record.contains("s1_callback_work_n=1"))
    }

    @Test func clockReanchorDiagnosticsSeparateTrackAndOffsetWithoutPayload() {
        let meter = PrimaryMediaDiagnostics(generation: 2, now: { 0 }, sink: { _ in })
        meter.clock(reason: .futureReanchor, action: .schedule, audio: true, generation: 2, offsetSeconds: 0.240)
        meter.clock(reason: .sustainedLateReanchor, action: .schedule, audio: false, generation: 3, offsetSeconds: -0.310)
        let summary = meter.snapshot(now: 1)
        #expect(summary.clockReasonTracks[.futureReanchor] == [1, 0])
        #expect(summary.clockReasonTracks[.sustainedLateReanchor] == [0, 1])
        #expect(summary.clockReanchorOffsets[.futureReanchor]?[0].maximumMilliseconds == 240)
        #expect(summary.clockReanchorOffsets[.sustainedLateReanchor]?[1].minimumMilliseconds == -310)
        let text = summary.logLines.joined(separator: " ")
        #expect(text.contains("clock_futureReanchor_tracks_audio_video=[1, 0]"))
        #expect(text.contains("clock_sustainedLateReanchor_offset_video_n=1"))
    }

    @Test func scrcpyOwnerKeepsTrackGenerationsIndependent() {
        let videoClock = MediaPlayoutClock()
        let audioClock = MediaPlayoutClock()
        let owner = ScrcpyNativeMediaOwner(
            id: .init(),
            binding: NativeFrameBinding { _ in },
            videoClock: videoClock,
            audioClock: audioClock,
            failureHandler: { _, _ in }
        )
        #expect(owner.videoClock === videoClock)
        #expect(owner.audioClock === audioClock)
        #expect(owner.videoClock !== owner.audioClock)

        let video = videoClock.decision(
            track: .video,
            presentationTimeUs: 1_000_000,
            epoch: 1,
            now: 10
        )
        _ = audioClock.decision(
            track: .audio,
            presentationTimeUs: 1_000_000,
            epoch: 1,
            now: 10
        )
        _ = audioClock.decision(
            track: .audio,
            presentationTimeUs: 2_000_000,
            epoch: 1,
            now: 10.01
        )
        #expect(videoClock.isCurrent(generation: video.generation))
        #expect(!audioClock.isCurrent(generation: video.generation))
        withExtendedLifetime(owner) {}
    }

    @Test func realControlErrorAndOwnerLossBalancePending() throws {
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        let queue = DispatchQueue(label: "diagnostics.control-error")
        let failed = try #require(meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: 0))
        let dropped = try #require(meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: 0))
        ScrcpyPrimaryControlDelivery.send(Data(), queue: queue, trace: failed, correlated: false) { _, completion in
            completion(NSError(domain: "synthetic", code: 1)); return true
        }
        ScrcpyPrimaryControlDelivery.send(Data(), queue: queue, trace: dropped, correlated: false) { _, _ in false }
        queue.sync {}
        let summary = meter.snapshot(now: 1)
        #expect(summary.pending[.control] == 0)
        #expect(summary.counters[.controlFailed] == 1 && summary.counters[.dropped] == 1)
        #expect(summary.counters[.queueImbalance] == 0)
    }

    @Test func actualControlDispatchPreservesBytesAndAccountsCompletion() throws {
        let meter = PrimaryMediaDiagnostics(generation: 5, now: { 0 }, sink: { _ in })
        let trace = try #require(meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: 1))
        let queue = DispatchQueue(label: "diagnostics.control-fixture")
        let sent = DiagnosticTransportSink()
        ScrcpyPrimaryControlDelivery.send(Data([1, 2, 3]), queue: queue, trace: trace, correlated: true, now: { 1.020 }, sender: sent.send)
        ScrcpyPrimaryControlDelivery.send(Data([4]), queue: queue, trace: nil, correlated: false, now: { 1.020 }, sender: sent.send)
        queue.sync {}
        #expect(sent.bytes == [Data([1, 2, 3]), Data([4])])
        #expect(meter.snapshot(now: 2).pending[.control] == 1)
        sent.complete()
        #expect(meter.snapshot(now: 2).pending[.control] == 0)
        #expect(meter.snapshot(now: 2).counters[.controlProcessed] == 1)
        #expect(meter.snapshot(now: 2).histograms[.inputToDispatch]?.maximumMilliseconds ?? 0 > 19.9)
    }

    @Test func synchronousControlFailureCannotLeaveAVisibleLatencyProbe() throws {
        let meter = PrimaryMediaDiagnostics(generation: 6, now: { 1.3 }, sink: { _ in })
        let baseline = try #require(meter.received(stream: .video, bytes: 1, pts: 1, epoch: 1, now: 1))
        meter.drawablePresented(trace: baseline, submittedAt: 1, presentedAt: 1.01,
                                signature: PrimaryFrameSignature(luma: Array(repeating: 1, count: 144)))
        let failed = try #require(meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: 1.1))
        let queue = DispatchQueue(label: "diagnostics.synchronous-control-failure")
        ScrcpyPrimaryControlDelivery.send(Data(), queue: queue, trace: failed, correlated: true, now: { 1.1 }) {
            _, completion in
            completion(NSError(domain: "synthetic", code: 1))
            return true
        }
        queue.sync {}
        let changed = try #require(meter.received(stream: .video, bytes: 1, pts: 2, epoch: 1, now: 1.2))
        meter.drawablePresented(trace: changed, submittedAt: 1.21, presentedAt: 1.22,
                                signature: PrimaryFrameSignature(luma: Array(repeating: 20, count: 144)))
        let snapshot = meter.snapshot(now: 1.3)
        #expect(snapshot.counters[.controlFailed] == 1)
        #expect(snapshot.histograms[.inputToVisibleChange]?.sampleCount == 0)
    }

    @Test @MainActor func pointerEffectsAreIdenticalWithScalarReceipt() throws {
        let plain = DeviceInputNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let measured = DeviceInputNSView(frame: plain.frame)
        var plainActions: [ScrcpyMotionAction] = []
        var measuredActions: [ScrcpyMotionAction] = []
        let meter = PrimaryMediaDiagnostics(generation: 3, now: { 0 }, sink: { _ in })
        var traced = 0
        plain.onTouch = { action, _, _ in plainActions.append(action) }
        measured.primaryInputReceipt = { time in meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: time) }
        measured.primaryTouch = { action, _, _, trace in
            measuredActions.append(action)
            if trace != nil { traced += 1 }
        }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        for view in [plain, measured] {
            view.mouseDown(with: event); view.mouseDragged(with: event); view.mouseUp(with: event)
        }
        #expect(plainActions == [.down, .move, .up])
        #expect(measuredActions == plainActions && traced == 2)
    }

    @Test @MainActor func preciseTrackpadEffectsAndOrderAreIdentical() throws {
        let plain = DeviceInputNSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let measured = DeviceInputNSView(frame: plain.frame)
        let meter = PrimaryMediaDiagnostics(generation: 3, sink: { _ in })
        var plainActions: [ScrcpyMotionAction] = []
        var measuredActions: [ScrcpyMotionAction] = []
        var traces = 0
        plain.preciseScrollUsesTouch = true; measured.preciseScrollUsesTouch = true
        plain.onTrackpadTouch = { action, _, _ in plainActions.append(action) }
        measured.primaryInputReceipt = { time in meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: time) }
        measured.primaryTrackpadTouch = { action, _, _, trace in
            measuredActions.append(action)
            if trace != nil { traces += 1 }
        }
        for phase: Int64 in [1, 2, 4] {
            let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                               wheel1: phase == 4 ? 0 : 12, wheel2: 0, wheel3: 0))
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            let event = try #require(NSEvent(cgEvent: cgEvent))
            #expect(event.hasPreciseScrollingDeltas)
            plain.scrollWheel(with: event); measured.scrollWheel(with: event)
        }
        #expect(plainActions == [.down, .move, .move, .up])
        #expect(measuredActions == plainActions && traces == 3)
    }

    @Test func outOfOrderCompletionsAndEvictedPendingAreAccounted() throws {
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        var traces: [PrimaryMediaTrace] = []
        for index in 0..<129 {
            let trace = try #require(meter.received(stream: .video, bytes: 1, pts: nil, epoch: nil, now: Double(index)))
            meter.enter(.vt, trace: trace, now: Double(index)); traces.append(trace)
        }
        for trace in traces.reversed() { meter.leave(.vt, trace: trace); meter.finish(trace) }
        let summary = meter.snapshot(now: 130)
        #expect(summary.pending[.vt] == 0 && summary.pendingHighWater[.vt] == 129)
        #expect(summary.counters[.correlationLost] == 1 && summary.counters[.missingCorrelation] ?? 0 > 0)
        #expect(summary.counters[.queueImbalance] == 0)
    }

    @Test func actualPresentationUsesPresentedTimeAndCountsSkipped() throws {
        let meter = PrimaryMediaDiagnostics(generation: 2, now: { 0 }, sink: { _ in })
        let trace = try #require(meter.received(stream: .video, bytes: 1, pts: 1, epoch: 1, now: 1))
        meter.mark(.appModel, trace: trace, now: 1.0)
        meter.mark(.surface, trace: trace, now: 1.01)
        let first = PrimaryDrawableMeasurement(trace: trace, submittedAt: 1.02)
        first.presented(at: 1.05)
        PrimaryDrawableMeasurement(trace: trace, submittedAt: 1.06).presented(at: 0)
        let snapshot = meter.snapshot(now: 2)
        #expect(snapshot.counters[.drawablePresented] == 1)
        #expect(snapshot.counters[.drawableSkipped] == 1)
        #expect(snapshot.histograms[.metalToPresented]?.sampleCount == 1)
        #expect(snapshot.histograms[.metalToPresented]?.maximumMilliseconds ?? 0 > 29.9)
        #expect(snapshot.firstPresentedElapsedMS == 1_050)
    }

    @Test func changedPostDispatchFrameMeasuresPresentedInputLatency() throws {
        let meter = PrimaryMediaDiagnostics(generation: 4, now: { 5 }, startedAt: 4, sink: { _ in })
        let baseline = try #require(meter.received(stream: .video, bytes: 1, pts: 1, epoch: 1, now: 5.0))
        meter.drawablePresented(
            trace: baseline,
            submittedAt: 5.01,
            presentedAt: 5.02,
            signature: PrimaryFrameSignature(luma: Array(repeating: 10, count: 144))
        )
        let input = try #require(meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: 5.03))
        meter.inputDispatched(trace: input, at: 5.04, epochMS: 123_456)
        let response = try #require(meter.received(stream: .video, bytes: 1, pts: 2, epoch: 1, now: 5.08))
        meter.drawablePresented(
            trace: response,
            submittedAt: 5.09,
            presentedAt: 5.119,
            signature: PrimaryFrameSignature(luma: Array(repeating: 40, count: 144))
        )
        let snapshot = meter.snapshot(now: 5.2)
        #expect(abs((snapshot.firstPresentedElapsedMS ?? 0) - 1_020) < 0.001)
        #expect(snapshot.histograms[.inputToVisibleChange]?.sampleCount == 1)
        #expect(snapshot.histograms[.inputToVisibleChange]?.maximumMilliseconds ?? 0 > 78.9)
        #expect(snapshot.histograms[.inputToVisibleChange]?.percentile95UpperBoundMilliseconds == 80)
        #expect(abs((snapshot.histograms[.inputToFrameReceived]?.maximumMilliseconds ?? 0) - 40) < 0.001)
        #expect(abs((snapshot.histograms[.frameReceivedToVisibleChange]?.maximumMilliseconds ?? 0) - 39) < 0.001)
        let sample = try #require(snapshot.inputFrameSamples.first)
        #expect(sample.inputSequence == input.sequence)
        #expect(sample.frameSequence == response.sequence)
        #expect(sample.videoPTSUs == 2)
        #expect(sample.inputDispatchEpochMS == 123_456)
        #expect(abs((sample.relativeVideoArrivalMS ?? 0) - 79.99999999999999) < 0.001)
        #expect(abs(sample.inputToFrameMS - 40) < 0.001)
        #expect(abs(sample.frameToVisibleMS - 39) < 0.001)
        #expect(snapshot.logLines.contains {
            $0.contains("inputFrameSample=input:")
                && $0.contains("pts_us:2")
                && $0.contains("dispatch_epoch_ms:123456.0")
                && $0.contains("relative_video_arrival_ms:")
        })
        #expect(snapshot.counters[.inputProbeExpired] == 0)
    }

    @Test func rejectedAndExpiredInputProbesCannotBecomeLatencySamples() throws {
        let meter = PrimaryMediaDiagnostics(generation: 5, now: { 0 }, sink: { _ in })
        let baseline = try #require(meter.received(stream: .video, bytes: 1, pts: 1, epoch: 1, now: 1))
        meter.drawablePresented(trace: baseline, submittedAt: 1, presentedAt: 1.01,
                                signature: PrimaryFrameSignature(luma: Array(repeating: 1, count: 144)))
        let cancelled = try #require(meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: 1.1))
        meter.inputDispatched(trace: cancelled, at: 1.1)
        meter.cancelInputProbe(trace: cancelled)
        let expired = try #require(meter.received(stream: .control, bytes: 0, pts: nil, epoch: nil, now: 1.2))
        meter.inputDispatched(trace: expired, at: 1.2)
        let late = try #require(meter.received(stream: .video, bytes: 1, pts: 2, epoch: 1, now: 3.3))
        meter.drawablePresented(trace: late, submittedAt: 3.31, presentedAt: 3.32,
                                signature: PrimaryFrameSignature(luma: Array(repeating: 20, count: 144)))
        let snapshot = meter.snapshot(now: 3.4)
        #expect(snapshot.histograms[.inputToVisibleChange]?.sampleCount == 0)
        #expect(snapshot.counters[.inputProbeExpired] == 1)
    }

    @Test func oneChangedFrameMeasuresOnlyTheLatestEligibleDragInput() throws {
        let meter = PrimaryMediaDiagnostics(generation: 7, now: { 0 }, sink: { _ in })
        let baseline = try #require(meter.received(stream: .video, bytes: 1, pts: 1, epoch: 1, now: 5.0))
        meter.drawablePresented(trace: baseline, submittedAt: 5.0, presentedAt: 5.01,
                                signature: PrimaryFrameSignature(luma: Array(repeating: 1, count: 144)))

        for (sequence, dispatchedAt) in [(2, 5.02), (3, 5.05), (4, 5.08)] {
            let input = try #require(meter.received(
                stream: .control,
                bytes: sequence,
                pts: nil,
                epoch: nil,
                now: dispatchedAt
            ))
            meter.inputDispatched(trace: input, at: dispatchedAt)
        }
        let afterIngress = try #require(meter.received(
            stream: .control,
            bytes: 5,
            pts: nil,
            epoch: nil,
            now: 5.12
        ))
        meter.inputDispatched(trace: afterIngress, at: 5.12)

        let response = try #require(meter.received(stream: .video, bytes: 1, pts: 2, epoch: 1, now: 5.10))
        meter.drawablePresented(trace: response, submittedAt: 5.11, presentedAt: 5.14,
                                signature: PrimaryFrameSignature(luma: Array(repeating: 30, count: 144)))
        var snapshot = meter.snapshot(now: 5.15)
        #expect(snapshot.histograms[.inputToVisibleChange]?.sampleCount == 1)
        #expect(abs((snapshot.histograms[.inputToVisibleChange]?.maximumMilliseconds ?? 0) - 60) < 0.001)
        #expect(abs((snapshot.histograms[.inputToFrameReceived]?.maximumMilliseconds ?? 0) - 20) < 0.001)
        #expect(abs((snapshot.histograms[.frameReceivedToVisibleChange]?.maximumMilliseconds ?? 0) - 40) < 0.001)
        #expect(snapshot.inputFrameSamples.count == 1)
        #expect(snapshot.inputFrameSamples.first?.videoPTSUs == 2)

        let next = try #require(meter.received(stream: .video, bytes: 1, pts: 3, epoch: 1, now: 5.16))
        meter.drawablePresented(trace: next, submittedAt: 5.17, presentedAt: 5.18,
                                signature: PrimaryFrameSignature(luma: Array(repeating: 60, count: 144)))
        snapshot = meter.snapshot(now: 5.19)
        #expect(snapshot.histograms[.inputToVisibleChange]?.sampleCount == 2)
        #expect(snapshot.histograms[.inputToVisibleChange]?.maximumMilliseconds ?? 0 < 61)
        #expect(snapshot.histograms[.inputToFrameReceived]?.sampleCount == 2)
        #expect(snapshot.histograms[.frameReceivedToVisibleChange]?.sampleCount == 2)
        #expect(snapshot.inputFrameSamples.map(\.videoPTSUs) == [2, 3])
        #expect(snapshot.counters[.inputProbeExpired] == 0)
    }

    @Test func frameSignatureSamplesPixelsOnlyInMemory() throws {
        let first = try QuicCodecFixtureFactory.nv12(marker: 40, motionIndex: 1)
        let second = try QuicCodecFixtureFactory.nv12(marker: 40, motionIndex: 2)
        let firstSignature = try #require(PrimaryFrameSignature.sample(first))
        let secondSignature = try #require(PrimaryFrameSignature.sample(second))
        #expect(firstSignature.luma.count == PrimaryFrameSignature.side * PrimaryFrameSignature.side)
        #expect(firstSignature.isVisiblyDifferent(from: secondSignature))
    }

    @Test func frameSignatureDetectsLocalizedControlsWithoutTreatingNoiseAsMotion() {
        let baseline = PrimaryFrameSignature(luma: Array(repeating: 80, count: PrimaryFrameSignature.side * PrimaryFrameSignature.side))
        let compressionNoise = PrimaryFrameSignature(luma: Array(repeating: 81, count: PrimaryFrameSignature.side * PrimaryFrameSignature.side))
        var localized = baseline.luma
        localized[20] = 110
        localized[21] = 110
        localized[22] = 110
        #expect(!compressionNoise.isVisiblyDifferent(from: baseline))
        #expect(PrimaryFrameSignature(luma: localized).isVisiblyDifferent(from: baseline))
    }
    @Test @MainActor func actualHandoffAndMulticastPreserveEffects() async throws {
        let meter = PrimaryMediaDiagnostics(generation: 9, now: { 0 }, sink: { _ in })
        let trace = try #require(meter.received(stream: .video, bytes: 3, pts: 1, epoch: 1, now: 0))
        let deliveries = DiagnosticEventSink()
        ScrcpyPrimaryMediaDelivery.deliver(.codec(.h264), trace: trace) { event, context in
            deliveries.values.append(event)
            #expect(context?.collector === meter)
        }
        ScrcpyPrimaryMediaDelivery.deliver(.codec(.h265), trace: nil) { event, context in
            deliveries.values.append(event)
            #expect(context == nil)
        }
        for _ in 0..<100 where deliveries.values.count < 2 { await Task.yield() }
        #expect(deliveries.values.count == 2)
        #expect(meter.snapshot(now: 1).histograms[.receiveToActor]?.sampleCount == 1)
        #expect(meter.snapshot(now: 1).pending[.event] == 0)

        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixel) == 0)
        let buffer = try #require(pixel)
        let registry = VideoSurfacePresenterRegistry()
        let first = DiagnosticPresenter()
        registry.attach(first)
        registry.present(buffer, presentationTime: .zero, epoch: 1, diagnosticTrace: trace)
        let late = DiagnosticPresenter()
        registry.attach(late)
        #expect(first.count == 1 && late.count == 1)
        #expect(first.trace?.collector === meter && late.trace?.collector === meter)
        meter.terminate(now: 2)
        let successor = PrimaryMediaDiagnostics(generation: 10, now: { 2 }, sink: { _ in })
        registry.attach(DiagnosticPresenter())
        late.trace?.collector.mark(.surface, trace: trace, now: 3)
        #expect(successor.snapshot(now: 3).histograms[.appModelToSurface]?.sampleCount == 0)
    }

    @Test func summaryCadenceAndCompletionLoss() throws {
        let sink = DiagnosticTestSink()
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: sink.append)
        meter.emitIfDue(now: 4.99); meter.emitIfDue(now: 5); meter.emitIfDue(now: 5.1)
        #expect(sink.values.count == 1)
        meter.terminate(now: 5.2); meter.terminate(now: 6)
        #expect(sink.values.count == 2)
        var allocated = false
        let disabled = PrimaryMediaDiagnostics.make(enabled: false) {
            allocated = true
            return PrimaryMediaDiagnostics(generation: 1, sink: sink.append)
        }
        #expect(disabled == nil && !allocated)
    }

    @Test func audioQueueCarriesOriginalTraceAndPreservesErrors() throws {
        let queue = DispatchQueue(label: "diagnostics.audio-fixture")
        let first = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        let next = PrimaryMediaDiagnostics(generation: 2, now: { 0 }, sink: { _ in })
        let trace = try #require(first.received(stream: .audio, bytes: 1, pts: nil, epoch: nil))
        let successorTrace = try #require(next.received(stream: .audio, bytes: 1, pts: nil, epoch: nil))
        first.mark(.actor, trace: trace)
        next.mark(.actor, trace: successorTrace)
        let errors = DiagnosticCount()
        let player = AACAudioPlayer(nowSeconds: { 0 }, queue: queue, failureHandler: { _ in errors.increment() })
        queue.suspend()
        player.consume(.codec(.h264), diagnosticTrace: trace)
        player.consume(.codec(.h264))
        player.consume(.codec(.h264), diagnosticTrace: successorTrace)
        #expect(first.snapshot(now: 1).pending[.decoder] == 1)
        #expect(next.snapshot(now: 1).pending[.decoder] == 1)
        #expect(first.snapshot(now: 1).counters[.failed] == 0)
        #expect(next.snapshot(now: 1).counters[.failed] == 0)
        queue.resume(); queue.sync {}
        #expect(errors.value == 3)
        for meter in [first, next] {
            let summary = meter.snapshot(now: 2)
            #expect(summary.pending[.decoder] == 0 && summary.pendingHighWater[.decoder] == 1)
            #expect(summary.counters[.failed] == 1 && summary.counters[.queueImbalance] == 0)
            #expect(summary.histograms[.actorToDecoder]?.sampleCount == 1)
        }
        let delayed = try #require(first.received(stream: .audio, bytes: 1, pts: nil, epoch: nil))
        let live = try #require(next.received(stream: .audio, bytes: 1, pts: nil, epoch: nil))
        queue.suspend()
        player.consume(.codec(.h264), diagnosticTrace: delayed)
        first.terminate(now: 3)
        player.consume(.codec(.h264), diagnosticTrace: live)
        queue.resume(); queue.sync {}
        #expect(errors.value == 5)
        #expect(first.snapshot(now: 4).counters[.failed] == 1)
        #expect(first.snapshot(now: 4).counters[.incomplete] == 1)
        #expect(next.snapshot(now: 4).counters[.failed] == 2)
        #expect(next.snapshot(now: 4).pending[.decoder] == 0)
        player.stop(); queue.sync {}
    }

    // Removing AACAudioPlayer.playoutDecision's trace forwarding must make the
    // positive per-owner clock counts fail, even though media decisions match.
    @Test func audioClockObservesLiveSuccessorAndDelayedOriginalTrace() throws {
        let first = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        let next = PrimaryMediaDiagnostics(generation: 2, now: { 0 }, sink: { _ in })
        let traceA = try #require(first.received(stream: .audio, bytes: 1, pts: nil, epoch: nil))
        let traceB = try #require(next.received(stream: .audio, bytes: 1, pts: nil, epoch: nil))
        let sharedClock = MediaPlayoutClock()
        let uninstrumentedClock = MediaPlayoutClock()
        let queue = DispatchQueue(label: "diagnostics.audio-clock-fixture")
        let player = AACAudioPlayer(playoutClock: sharedClock, nowSeconds: { 0 }, queue: queue,
                                    failureHandler: { _ in Issue.record("Clock-only fixture must not decode") })
        defer { player.stop(); queue.sync {} }
        let cases: [(UInt64?, UInt32?, PrimaryMediaTrace, MediaPlayoutDecision)] = [
            (nil, nil, traceA, .init(action: .immediate, generation: 0)),
            (1_000_000, 1, traceA, .init(action: .schedule(0.060), generation: 1)),
            (1_000_000, 2, traceB, .init(action: .schedule(0.060), generation: 2)),
            (nil, nil, traceA, .init(action: .immediate, generation: 2)), // delayed A after live B
            (1_000_000, 2, traceB, .init(action: .schedule(0.060), generation: 2)),
            (nil, nil, traceA, .init(action: .immediate, generation: 2)), // retired A is inert
            (2_000_000, 2, traceB, .init(action: .schedule(0.060), generation: 3)),
        ]
        for (index, sample) in cases.enumerated() {
            if index == 4 { first.terminate(now: 1) }
            let (pts, epoch, trace, expected) = sample
            let measured = player.playoutDecision(clock: sharedClock, presentationTimeUs: pts,
                                                  epoch: epoch, diagnosticTrace: trace)
            let plain = uninstrumentedClock.decision(track: .audio, presentationTimeUs: pts, epoch: epoch, now: 0)
            #expect(measured == expected)
            #expect(plain == expected)
        }
        let a = first.snapshot(now: 2)
        let b = next.snapshot(now: 2)
        #expect(a.counters[.clockDecisions] == 3 && b.counters[.clockDecisions] == 3)
        #expect(a.clockTracks == [3, 0] && b.clockTracks == [3, 0])
        let aActions: [PrimaryClockAction: UInt64] = [.immediate: 2, .schedule: 1]
        let bActions: [PrimaryClockAction: UInt64] = [.schedule: 3]
        for action in PrimaryClockAction.allCases {
            #expect(a.clockActions[action] == aActions[action, default: 0])
            #expect(b.clockActions[action] == bActions[action, default: 0])
        }
        let aReasons: [PrimaryClockReason: UInt64] = [.noPTS: 2, .epoch: 1]
        let bReasons: [PrimaryClockReason: UInt64] = [.epoch: 1, .none: 1, .futureReanchor: 1]
        for reason in PrimaryClockReason.allCases {
            #expect(a.clockReasons[reason] == aReasons[reason, default: 0])
            #expect(b.clockReasons[reason] == bReasons[reason, default: 0])
        }
        #expect(a.lastClockGeneration == 2 && a.clockGenerationChanges == 2)
        #expect(b.lastClockGeneration == 3 && b.clockGenerationChanges == 1)
    }
    @Test func handDerivedDurationsAndPTSDrift() throws {
        let meter = PrimaryMediaDiagnostics(generation: 7, now: { 0 }, sink: { _ in })
        let first = try #require(meter.received(stream: .video, bytes: 40, pts: 1_000_000, epoch: 1, now: 10))
        meter.enter(.event, trace: first, now: 10)
        meter.leave(.event, trace: first, now: 10.004)
        meter.mark(.actor, trace: first, now: 10.004)
        meter.mark(.decoder, trace: first, now: 10.006)
        let second = try #require(meter.received(stream: .video, bytes: 60, pts: 1_100_000, epoch: 1, now: 10.150))
        meter.finish(first)
        meter.finish(second)
        let summary = meter.snapshot(now: 11)
        // 4 ms arrival→actor, 2 ms actor→decoder; 150−100 = 50 ms PTS drift.
        #expect(summary.histograms[.receiveToActor]?.counts == [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(summary.histograms[.actorToDecoder]?.sampleCount == 1)
        #expect(summary.histograms[.relativePTS]?.sampleCount == 1)
        #expect(summary.histograms[.relativePTS]?.maximumMilliseconds ?? 0 > 49.9)
        #expect(summary.counters[.parsedBytes] == 100)
        #expect(summary.pending[.event] == 0)
    }

    @Test func boundedLossTerminalAndOldGeneration() throws {
        let sink = DiagnosticTestSink()
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: sink.append)
        for index in 0..<10_001 {
            let trace = try #require(meter.received(stream: .video, bytes: 1, pts: UInt64(index), epoch: 1, now: Double(index) / 1_000))
            meter.enter(.event, trace: trace, now: 0)
        }
        let old = try #require(meter.received(stream: .control, bytes: 1, pts: nil, epoch: nil, now: 1))
        #expect(meter.snapshot(now: 11).retainedSlots <= 256)
        #expect(meter.snapshot(now: 11).counters[.correlationLost] == 9_873)
        #expect(meter.snapshot(now: 11).pending[.event] == 10_001)
        meter.terminate(now: 12)
        meter.terminate(now: 13)
        let before = meter.snapshot(now: 13)
        meter.mark(.actor, trace: old, now: 14)
        #expect(meter.snapshot(now: 14).counters == before.counters)
        #expect(sink.values.count == 1)
        #expect(sink.values.first?.pending[.event] == 10_001)
    }

    @Test func clockHookIsActualAndDecisionsUnchanged() {
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        let measured = MediaPlayoutClock(diagnostics: meter)
        let plain = MediaPlayoutClock()
        for (pts, now) in [(UInt64(1_000_000), 0.0), (1_100_000, 0.50), (1_200_000, 0.80)] {
            #expect(measured.decision(track: .video, presentationTimeUs: pts, epoch: 1, now: now)
                    == plain.decision(track: .video, presentationTimeUs: pts, epoch: 1, now: now))
        }
        #expect(meter.snapshot(now: 1).counters[.clockDecisions] == 3)
    }

    @Test func invalidEpochStaticAndDisabled() {
        #expect(PrimaryMediaDiagnostics.isEnabled(arguments: [], bundleID: "com.xopmc.GalaxyBridge.internal") == false)
        #expect(PrimaryMediaDiagnostics.isEnabled(arguments: ["--primary-media-diagnostics"], bundleID: "com.xopmc.GalaxyBridge") == false)
        let meter = PrimaryMediaDiagnostics(generation: 1, now: { 0 }, sink: { _ in })
        _ = meter.received(stream: .video, bytes: 1, pts: 100, epoch: 1, now: 1)
        _ = meter.received(stream: .video, bytes: 1, pts: 50, epoch: 1, now: 2)
        _ = meter.received(stream: .video, bytes: 1, pts: 200, epoch: 2, now: 100)
        _ = meter.received(stream: .video, bytes: 1, pts: 300, epoch: 2, now: .nan)
        let summary = meter.snapshot(now: 200)
        #expect(summary.histograms[.relativePTS]?.sampleCount ?? 0 == 0)
        #expect(summary.counters[.invalidTimestamp] == 2)
    }
}

@MainActor private final class DiagnosticEventSink { var values: [ScrcpyStreamEvent] = [] }
@MainActor private final class DiagnosticPresenter: VideoSurfacePresenting {
    var count = 0
    var trace: PrimaryMediaTrace?
    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32) { count += 1 }
    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32, diagnosticTrace: PrimaryMediaTrace?) {
        count += 1; trace = diagnosticTrace
    }
}
private final class DiagnosticCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class DiagnosticTransportSink: @unchecked Sendable {
    private let lock = NSLock()
    private var content: [Data] = []
    private var completions: [@Sendable (Error?) -> Void] = []
    var bytes: [Data] { lock.withLock { content } }
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) -> Bool {
        lock.withLock { content.append(data); completions.append(completion) }
        return true
    }
    func complete() {
        let callbacks = lock.withLock { let result = completions; completions.removeAll(); return result }
        callbacks.forEach { $0(nil) }
    }
}

private final class DiagnosticTestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PrimaryMediaSummary] = []
    var values: [PrimaryMediaSummary] { lock.withLock { stored } }
    func append(_ value: PrimaryMediaSummary) { lock.withLock { stored.append(value) } }
}
