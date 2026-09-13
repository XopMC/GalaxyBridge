import Foundation

@main
enum AudioPresentationTimelineSpec {
    static func main() throws {
        var timeline = AudioPresentationTimeline()
        let first = try required(
            timeline.targetHostTime(presentationTimeUs: 1_000_000, now: 100),
            "first target"
        )
        try expectNear(first, 100.060, "first packet receives a bounded lead")

        let second = try required(
            timeline.targetHostTime(presentationTimeUs: 1_021_333, now: 100.040),
            "second target"
        )
        try expectNear(second, 100.081_333, "arrival jitter does not change the PTS timeline")

        let late = try required(
            timeline.targetHostTime(presentationTimeUs: 1_042_666, now: 100.250),
            "late target"
        )
        try expectNear(late, 100.260, "a packet over 100 ms late rebases instead of drifting")

        let backwards = try required(
            timeline.targetHostTime(presentationTimeUs: 900_000, now: 101),
            "backwards target"
        )
        try expectNear(backwards, 101.060, "epoch/backwards PTS resets the timeline")

        timeline.reset()
        try expect(
            timeline.targetHostTime(presentationTimeUs: nil, now: 200) == nil,
            "packets without PTS remain immediate"
        )
        try expect(timeline.basePresentationTimeUs == nil, "reset clears the PTS base")
        print("PASS AAC presentation timeline preserves PTS and bounds drift")
    }

    private static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SpecFailure(message) }
        return value
    }

    private static func expectNear(
        _ actual: TimeInterval,
        _ expected: TimeInterval,
        _ message: String
    ) throws {
        try expect(abs(actual - expected) < 0.000_001, "\(message): expected \(expected), got \(actual)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message) }
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
