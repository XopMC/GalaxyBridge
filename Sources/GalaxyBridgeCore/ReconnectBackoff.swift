public struct ReconnectBackoff: Sendable {
    private static let schedule: [Duration] = [
        .seconds(1),
        .seconds(2),
        .seconds(5),
        .seconds(10),
        .seconds(30),
    ]

    private var attempt = 0

    public init() {}

    public mutating func nextDelay() -> Duration {
        let index = min(attempt, Self.schedule.count - 1)
        attempt += 1
        return Self.schedule[index]
    }
}
