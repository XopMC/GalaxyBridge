import Foundation

/// Driven on the connection's serial queue. Only a matching Pong confirms
/// liveness: outgoing writes may succeed while a Wi-Fi peer has disappeared.
struct CompanionControlHeartbeat {
    enum Action: Equatable {
        case idle
        case ping(UInt64)
        case timedOut
    }

    private var nextPingAt: TimeInterval?
    private var pending: (token: UInt64, sentAt: TimeInterval)?

    fileprivate mutating func poll(now: TimeInterval) -> Action {
        if let pending {
            return now - pending.sentAt >= 4 ? .timedOut : .idle
        }
        let nextProbeAt = nextPingAt ?? now
        guard now >= nextProbeAt else { return .idle }
        let token = UInt64(now * 1_000_000_000)
        pending = (token, now)
        nextPingAt = now + 2
        return .ping(token)
    }

    mutating func receivePong(_ token: UInt64, now: TimeInterval) -> UInt64? {
        guard let pendingProbe = pending, pendingProbe.token == token else { return nil }
        let roundTrip = max(0, now - pendingProbe.sentAt)
        guard roundTrip < 4 else { return nil }
        self.pending = nil
        return milliseconds(roundTrip)
    }

    private func milliseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64((interval * 1_000).rounded())
    }
}

/// Tracks the expected 500 ms DispatchSource poll deadline separately from
/// probe send/RTT state. A late valid Pong can suppress probes, but cannot add
/// queue scheduling lateness unless the timer callback itself arrives late.
struct CompanionHeartbeatPollSchedule {
    struct Observation: Equatable {
        let action: CompanionControlHeartbeat.Action
        let schedulingLatenessMilliseconds: UInt64
    }

    private static let interval: TimeInterval = 0.5
    private var nextExpectedPollAt: TimeInterval?

    init(firstExpectedPollAt: TimeInterval? = nil) {
        nextExpectedPollAt = firstExpectedPollAt
    }

    mutating func poll(
        _ heartbeat: inout CompanionControlHeartbeat,
        now: TimeInterval
    ) -> Observation {
        let expectedPollAt = nextExpectedPollAt ?? now
        advanceExpectedPoll(after: now, from: expectedPollAt)
        return Observation(
            action: heartbeat.poll(now: now),
            schedulingLatenessMilliseconds: UInt64(
                (max(0, now - expectedPollAt) * 1_000).rounded()
            )
        )
    }

    private mutating func advanceExpectedPoll(
        after now: TimeInterval,
        from expectedPollAt: TimeInterval
    ) {
        guard now >= expectedPollAt else {
            nextExpectedPollAt = expectedPollAt + Self.interval
            return
        }
        let elapsedIntervals = floor((now - expectedPollAt) / Self.interval)
        nextExpectedPollAt = expectedPollAt + (elapsedIntervals + 1) * Self.interval
    }
}
