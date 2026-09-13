import Foundation

@main
enum CompanionControlHeartbeatSpec {
    static func main() {
        var heartbeat = CompanionControlHeartbeat()
        var heartbeatSchedule = CompanionHeartbeatPollSchedule(firstExpectedPollAt: 10)
        let firstHeartbeatPoll = heartbeatSchedule.poll(&heartbeat, now: 10)
        precondition(
            firstHeartbeatPoll.action == .ping(10_000_000_000)
        )
        precondition(firstHeartbeatPoll.schedulingLatenessMilliseconds == 0)
        precondition(heartbeat.receivePong(9_000_000_000, now: 10.5) == nil)
        precondition(heartbeatSchedule.poll(&heartbeat, now: 12).action == .idle, "old pong must not acknowledge a new request")
        precondition(heartbeatSchedule.poll(&heartbeat, now: 14).action == .timedOut, "silent Wi-Fi disconnect must not stay connected forever")

        var justInTime = CompanionControlHeartbeat()
        var onTimeSchedule = CompanionHeartbeatPollSchedule(firstExpectedPollAt: 20)
        let firstOnTimePoll = onTimeSchedule.poll(&justInTime, now: 20)
        guard case let .ping(justInTimeToken) = firstOnTimePoll.action else {
            preconditionFailure("first poll must send a ping")
        }
        precondition(firstOnTimePoll.schedulingLatenessMilliseconds == 0)
        for onTimePoll in stride(from: 20.5, through: 23.5, by: 0.5) {
            let observation = onTimeSchedule.poll(&justInTime, now: onTimePoll)
            precondition(observation.action == .idle)
            precondition(observation.schedulingLatenessMilliseconds == 0)
        }
        precondition(
            justInTime.receivePong(justInTimeToken, now: 23.999) == 3_999,
            "matching Pong just below four seconds must produce bounded RTT metadata"
        )
        let postPongPoll = onTimeSchedule.poll(&justInTime, now: 24)
        guard case let .ping(onTimeToken) = postPongPoll.action else {
            preconditionFailure("settled heartbeat must send its suppressed next ping")
        }
        precondition(
            postPongPoll.schedulingLatenessMilliseconds == 0,
            "long remote RTT and single-outstanding-probe suppression must not count as queue lateness"
        )
        precondition(
            justInTime.receivePong(onTimeToken, now: 28) == nil,
            "Pong at the four-second boundary must not revive a timed-out probe"
        )
        precondition(onTimeSchedule.poll(&justInTime, now: 28).action == .timedOut)

        var pending = CompanionControlHeartbeat()
        var pendingSchedule = CompanionHeartbeatPollSchedule(firstExpectedPollAt: 40)
        precondition(pendingSchedule.poll(&pending, now: 40).action == .ping(40_000_000_000))
        let delayedWhilePending = pendingSchedule.poll(&pending, now: 40.750)
        precondition(delayedWhilePending.action == .idle)
        precondition(
            delayedWhilePending.schedulingLatenessMilliseconds == 250,
            "timer delay must remain observable while a long-RTT Pong is still pending"
        )

        var delayed = CompanionControlHeartbeat()
        var delayedSchedule = CompanionHeartbeatPollSchedule(firstExpectedPollAt: 30)
        guard case let .ping(delayedToken) = delayedSchedule.poll(&delayed, now: 30).action else {
            preconditionFailure("first delayed-scenario poll must send a ping")
        }
        precondition(delayed.receivePong(delayedToken, now: 30) == 0)
        for onTimePoll in [30.5, 31.0, 31.5] {
            precondition(delayedSchedule.poll(&delayed, now: onTimePoll).action == .idle)
        }
        let delayedPoll = delayedSchedule.poll(&delayed, now: 32.250)
        guard case .ping = delayedPoll.action else {
            preconditionFailure("independently delayed poll must send the due ping")
        }
        precondition(
            delayedPoll.schedulingLatenessMilliseconds == 250,
            "actual injected timer delay must be attributed to queue scheduling regardless of Pong RTT"
        )

        var healthy = CompanionControlHeartbeat()
        var healthySchedule = CompanionHeartbeatPollSchedule(firstExpectedPollAt: 10)
        for tick in 10...200 {
            let now = Double(tick)
            let action = healthySchedule.poll(&healthy, now: now).action
            if case let .ping(token) = action {
                precondition(healthy.receivePong(token, now: now) == 0)
            } else {
                precondition(action == .idle)
            }
        }
        print("PASS control heartbeat separates timer lateness from RTT and detects blackholed Wi-Fi")
    }
}
