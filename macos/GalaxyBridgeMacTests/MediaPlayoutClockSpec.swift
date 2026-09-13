import Foundation

@main
enum MediaPlayoutClockSpec {
    static func main() throws {
        try sharedAnchorAlignsAudioAndVideo()
        try anotherTrackMayStartBeforeTheAnchorPTS()
        try arrivalJitterDoesNotMoveTheTimeline()
        try lateFramesAndAudioAreDropped()
        try qualifiedIndependentPreservesSharedAnchorAndDefaultPolicy()
        try sustainedNetworkDelayDoesNotDropEveryFrameForever()
        try futureTimestampJumpRebasesToInteractiveLatency()
        try backwardPTSStartsANewGeneration()
        try epochChangeStartsANewGeneration()
        try missingPTSRemainsPlayable()
        try twoHourTimelineRemainsNumericallyStable()
        print("PASS shared media playout clock bounds A/V drift and discontinuities")
    }

    private static func sharedAnchorAlignsAudioAndVideo() throws {
        let clock = MediaPlayoutClock()
        let audio = clock.decision(
            track: .audio,
            presentationTimeUs: 1_000_000,
            epoch: 7,
            now: 100.000
        )
        let video = clock.decision(
            track: .video,
            presentationTimeUs: 1_000_000,
            epoch: 7,
            now: 100.025
        )
        try expectScheduled(audio, at: 100.060, "48 kHz AAC anchors the shared clock")
        try expectScheduled(video, at: 100.060, "equal video PTS shares the AAC target")
        try expect(audio.generation == video.generation, "audio and video use one generation")
    }

    private static func arrivalJitterDoesNotMoveTheTimeline() throws {
        let clock = MediaPlayoutClock()
        _ = clock.decision(track: .audio, presentationTimeUs: 2_000_000, epoch: 3, now: 50.000)
        let earlyVideo = clock.decision(
            track: .video,
            presentationTimeUs: 2_033_333,
            epoch: 3,
            now: 50.004
        )
        let jitteredAudio = clock.decision(
            track: .audio,
            presentationTimeUs: 2_021_333,
            epoch: 3,
            now: 50.055
        )
        try expectScheduled(earlyVideo, at: 50.093_333, "early video arrival preserves PTS")
        try expectScheduled(jitteredAudio, at: 50.081_333, "jittered AAC arrival preserves PTS")
    }

    private static func anotherTrackMayStartBeforeTheAnchorPTS() throws {
        let clock = MediaPlayoutClock()
        _ = clock.decision(track: .audio, presentationTimeUs: 1_000_000, epoch: 7, now: 70.000)
        let video = clock.decision(
            track: .video,
            presentationTimeUs: 980_000,
            epoch: 7,
            now: 70.010
        )
        try expectScheduled(video, at: 70.040, "video may legitimately precede the first AAC PTS")
    }

    private static func lateFramesAndAudioAreDropped() throws {
        let clock = MediaPlayoutClock()
        _ = clock.decision(track: .video, presentationTimeUs: 10_000_000, epoch: 1, now: 10.000)
        let video = clock.decision(
            track: .video,
            presentationTimeUs: 10_033_333,
            epoch: 1,
            now: 10.250
        )
        let audio = clock.decision(
            track: .audio,
            presentationTimeUs: 10_042_666,
            epoch: 1,
            now: 10.260
        )
        try expect(video.action == .drop, "a video frame over 100 ms late is dropped")
        try expect(audio.action == .drop, "late AAC is dropped instead of shifting away from video")
    }

    private static func qualifiedIndependentPreservesSharedAnchorAndDefaultPolicy() throws {
        let clock=MediaPlayoutClock()
        let anchor=clock.decision(track:.audio,presentationTimeUs:1_000_000,epoch:7,now:100)
        let independent=clock.decision(track:.video,presentationTimeUs:1_000_000,epoch:7,now:100.250,allowLateIndependentVideo:true)
        try expect(independent.action == .immediate && independent.generation == anchor.generation,"new independent image presents without resetting shared clock")
        let dependent=clock.decision(track:.video,presentationTimeUs:1_016_667,epoch:7,now:100.260)
        try expect(dependent.action == .drop,"ordinary late dependent default is unchanged")
        let lateAudio=clock.decision(track:.audio,presentationTimeUs:1_021_334,epoch:7,now:100.270,allowLateIndependentVideo:true)
        try expect(lateAudio.action == .drop,"video exception never admits late AAC")
        let timely=clock.decision(track:.video,presentationTimeUs:1_300_000,epoch:7,now:100.300)
        try expectScheduled(timely,at:100.360,"later video keeps original shared PTS mapping")
        let audio=clock.decision(track:.audio,presentationTimeUs:1_320_000,epoch:7,now:100.330)
        try expectScheduled(audio,at:100.380,"AAC anchor was not reset by independent frame")
        clock.reset(epoch:8)
        try expect(!clock.isCurrent(generation:independent.generation),"queued independent output cannot survive epoch reset")
    }

    private static func futureTimestampJumpRebasesToInteractiveLatency() throws {
        let clock = MediaPlayoutClock()
        let first = clock.decision(track: .video, presentationTimeUs: 1_000_000, epoch: 1, now: 80.000)
        let reset = clock.decision(
            track: .video,
            presentationTimeUs: 1_500_000,
            epoch: 1,
            now: 80.010
        )
        try expectScheduled(reset, at: 80.070, "a future PTS discontinuity rebases to the 60 ms interactive lead")
        try expect(reset.generation > first.generation, "future discontinuity invalidates already queued frames")
    }

    private static func sustainedNetworkDelayDoesNotDropEveryFrameForever() throws {
        let clock = MediaPlayoutClock()
        let initial = clock.decision(track: .video, presentationTimeUs: 1_000_000, epoch: 1, now: 10)
        for index in 1...10 {
            let decision = clock.decision(
                track: .video,
                presentationTimeUs: 1_000_000 + UInt64(index) * 30_000,
                epoch: 1,
                now: 10.300 + Double(index) * 0.03
            )
            if index == 1 { try expect(decision.action == .drop, "isolated late frame is still dropped") }
            if index == 10 {
                try expectScheduled(decision, at: 10.660, "sustained Wi-Fi delay must recover without restarting capture")
                try expect(decision.generation > initial.generation, "recovery invalidates the stale timeline")
            }
        }
    }

    private static func backwardPTSStartsANewGeneration() throws {
        let clock = MediaPlayoutClock()
        let first = clock.decision(track: .audio, presentationTimeUs: 5_000_000, epoch: 4, now: 20)
        _ = clock.decision(track: .audio, presentationTimeUs: 5_021_333, epoch: 4, now: 20.02)
        let reset = clock.decision(track: .audio, presentationTimeUs: 900_000, epoch: 4, now: 21)
        try expectScheduled(reset, at: 21.060, "backward AAC PTS rebases with bounded lead")
        try expect(reset.generation > first.generation, "backward PTS invalidates queued media")
    }

    private static func epochChangeStartsANewGeneration() throws {
        let clock = MediaPlayoutClock()
        let old = clock.decision(track: .video, presentationTimeUs: 8_000_000, epoch: 10, now: 30)
        let reset = clock.decision(track: .video, presentationTimeUs: 100_000, epoch: 11, now: 31)
        try expectScheduled(reset, at: 31.060, "Fold/display epoch rebases the session")
        try expect(reset.generation > old.generation, "old scheduled frames are invalid after epoch change")
        try expect(!clock.isCurrent(generation: old.generation), "old frame generation is rejected")
    }

    private static func missingPTSRemainsPlayable() throws {
        let clock = MediaPlayoutClock()
        let audio = clock.decision(track: .audio, presentationTimeUs: nil, epoch: nil, now: 40)
        let video = clock.decision(track: .video, presentationTimeUs: nil, epoch: nil, now: 40)
        try expect(audio.action == .immediate, "audio-only streams without PTS remain playable")
        try expect(video.action == .immediate, "video-only streams without PTS remain playable")
    }

    private static func twoHourTimelineRemainsNumericallyStable() throws {
        let clock = MediaPlayoutClock()
        let startPTS: UInt64 = 9_000_000_000_000
        _ = clock.decision(track: .audio, presentationTimeUs: startPTS, epoch: 19, now: 1_000)

        var final = MediaPlayoutDecision(action: .drop, generation: 0)
        for frame in 1 ... 432_000 {
            let pts = startPTS + UInt64(frame) * 16_666
            let idealArrival = 1_000.060 + Double(frame * 16_666) / 1_000_000 - 0.010
            final = clock.decision(
                track: .video,
                presentationTimeUs: pts,
                epoch: 19,
                now: idealArrival
            )
        }
        let expected = 1_000.060 + Double(432_000 * 16_666) / 1_000_000
        try expectScheduled(final, at: expected, tolerance: 0.000_001, "two-hour target has sub-microsecond arithmetic drift")
    }

    private static func expectScheduled(
        _ decision: MediaPlayoutDecision,
        at expected: TimeInterval,
        tolerance: TimeInterval = 0.000_001,
        _ message: String
    ) throws {
        guard case let .schedule(actual) = decision.action else {
            throw SpecFailure("\(message): expected schedule, got \(decision.action)")
        }
        try expect(abs(actual - expected) < tolerance, "\(message): expected \(expected), got \(actual)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message) }
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
