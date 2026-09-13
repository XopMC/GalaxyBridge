import Foundation
import Network

@main
enum CompanionConnectionDiagnosticsSpec {
    static func main() throws {
        try receiveFailureRemainsFirstAfterCancellation()
        try localCancellationRemainsFirstAfterLateSendFailure()
        try eofPhaseDistinguishesAuthenticationFromActiveConnection()
        try terminalOriginsRemainDistinct()
        try privacySerializationIsAllowlisted()
        try firstCauseAdmissionIsThreadSafeAndBounded()
        try heartbeatMetricsAreBoundedAndAggregated()
        try heartbeatTimingKeepsRTTSeparateFromQueueLateness()
        try generationCallbacksAndRecoveryAdmissionAreRecorded()
        print("CompanionConnectionDiagnosticsSpec: 9 tests passed")
    }

    private static func receiveFailureRemainsFirstAfterCancellation() throws {
        let events = LockedEvents()
        let diagnostics = makeDiagnostics(events: events)

        let receive = diagnostics.receiveFailed(NWError.posix(.ECONNRESET))
        let cancel = diagnostics.localCancellation()

        try expect(receive == .first, "receive failure must be admitted as the first terminal cause")
        try expect(cancel == .cascade, "cancellation after a receive failure must be a cascade")
        let terminal = events.values.filter { $0.kind == .terminal }
        try expect(terminal.count == 2, "only the first terminal and one cascade marker may be emitted")
        try expect(terminal[0].origin == .receive, "receive must remain the first terminal origin")
        try expect(terminal[0].terminalAdmission == .first, "receive must be marked first")
        try expect(terminal[0].networkError?.domain == .posix, "known NW errors retain the fixed domain")
        try expect(terminal[0].networkError?.code == Int64(POSIXErrorCode.ECONNRESET.rawValue), "known NW errors retain the numeric code")
        try expect(terminal[1].origin == .localCancellation, "the cascade marker must identify local cancellation")
    }

    private static func localCancellationRemainsFirstAfterLateSendFailure() throws {
        let events = LockedEvents()
        let diagnostics = makeDiagnostics(events: events)

        try expect(diagnostics.localCancellation() == .first, "local cancellation must be admitted when it happens first")
        try expect(
            diagnostics.sendFailed(NWError.posix(.EPIPE)) == .cascade,
            "a late send completion must not replace local cancellation"
        )

        let terminal = events.values.filter { $0.kind == .terminal }
        try expect(terminal.map(\.origin) == [.localCancellation, .send], "terminal order must remain stable")
        try expect(terminal.map(\.terminalAdmission) == [.first, .cascade], "late send failure must be marked cascade")
        try expect(terminal[0].initiatingFailure == false, "intentional local cancellation is not an initiating outage")
        try expect(terminal[1].initiatingFailure == false, "cancellation fallout must not become another initiating outage")
    }

    private static func eofPhaseDistinguishesAuthenticationFromActiveConnection() throws {
        let beforeHelloEvents = LockedEvents()
        let beforeHello = makeDiagnostics(events: beforeHelloEvents, token: 42)
        beforeHello.networkReady()
        beforeHello.authenticationPrepared()
        _ = beforeHello.peerEOF()

        let afterHelloEvents = LockedEvents()
        let afterHello = makeDiagnostics(events: afterHelloEvents, token: 43)
        afterHello.networkReady()
        afterHello.authenticationPrepared()
        afterHello.helloReceived()
        afterHello.openChannelRequested()
        _ = afterHello.peerEOF()

        try expect(
            beforeHelloEvents.firstTerminal?.phase == .awaitingHello,
            "EOF before Hello must retain the awaiting-Hello phase"
        )
        try expect(
            afterHelloEvents.firstTerminal?.phase == .openChannelRequested,
            "EOF after Hello/open request must retain that unacknowledged request phase"
        )
        try expect(
            afterHelloEvents.values.contains { $0.milestone == .helloReceived },
            "Hello must be a meaningful handshake milestone"
        )
        try expect(
            afterHelloEvents.values.contains { $0.milestone == .openChannelRequested },
            "an open-channel request must be logged as requested, not acknowledged"
        )
    }

    private static func terminalOriginsRemainDistinct() throws {
        let scenarios: [(CompanionDiagnosticTerminalOrigin, (CompanionConnectionDiagnostics) -> CompanionDiagnosticTerminalAdmission)] = [
            (.authenticationPreparation, { $0.authenticationPreparationFailed(SensitiveError()) }),
            (.pathWaiting, { $0.pathWaiting(NWError.posix(.ENETDOWN)) }),
            (.networkFailure, { $0.networkFailed(NWError.posix(.ETIMEDOUT)) }),
            (.send, { $0.sendFailed(NWError.posix(.EPIPE)) }),
            (.receive, { $0.receiveFailed(NWError.posix(.ECONNRESET)) }),
            (.peerEOF, { $0.peerEOF() }),
            (.controlDecode, { $0.controlDecodeFailed(SensitiveError()) }),
            (.heartbeatTimeout, { $0.heartbeatTimedOut() }),
            (.connectingWatchdog, { $0.connectingWatchdogTimedOut() }),
            (.localCancellation, { $0.localCancellation() }),
        ]

        for (index, scenario) in scenarios.enumerated() {
            let events = LockedEvents()
            let diagnostics = makeDiagnostics(events: events, token: UInt64(100 + index))
            try expect(scenario.1(diagnostics) == .first, "each isolated terminal origin must be admitted")
            try expect(events.firstTerminal?.origin == scenario.0, "terminal origin \(scenario.0) must remain distinct")
        }
    }

    private static func privacySerializationIsAllowlisted() throws {
        let secret = "SECRET phone UUID 192.0.2.44:47777 Bonjour-Alice /Users/alice/private nonce clipboard pixels"
        let events = LockedEvents()
        let diagnostics = makeDiagnostics(events: events)
        _ = diagnostics.receiveFailed(
            NSError(
                domain: "private.\(secret)",
                code: 991,
                userInfo: [NSLocalizedDescriptionKey: secret]
            )
        )

        guard let event = events.firstTerminal else { throw SpecFailure("missing privacy event") }
        let serialized = event.serialized
        try expect(event.reasonCode == .unknownError, "unknown NSError must collapse to a fixed category")
        try expect(event.networkError == nil, "unknown NSError domain/code must not be retained")
        try expect(!serialized.contains(secret), "serialized metadata must not contain an error description")
        try expect(!serialized.contains("private."), "serialized metadata must not contain an arbitrary domain")
        try expect(!serialized.contains("192.0.2.44"), "serialized metadata must not contain endpoint data")

        let knownEvents = LockedEvents()
        let known = makeDiagnostics(events: knownEvents, token: 88)
        _ = known.pathWaiting(NWError.posix(.ENETDOWN))
        guard let knownLine = knownEvents.firstTerminal?.serialized else { throw SpecFailure("missing known NW event") }
        try expect(knownLine.contains("nw_domain=nw.posix"), "known NW error must retain only its fixed domain")
        try expect(knownLine.contains("nw_code=50"), "known NW error must retain its numeric code")
    }

    private static func firstCauseAdmissionIsThreadSafeAndBounded() throws {
        let events = LockedEvents()
        let diagnostics = makeDiagnostics(events: events, token: 90)

        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            if index.isMultiple(of: 2) {
                _ = diagnostics.receiveFailed(NWError.posix(.ECONNRESET))
            } else {
                _ = diagnostics.localCancellation()
            }
        }

        let terminal = events.values.filter { $0.kind == .terminal }
        try expect(terminal.filter { $0.terminalAdmission == .first }.count == 1, "concurrent callbacks admit exactly one first cause")
        try expect(terminal.filter { $0.terminalAdmission == .cascade }.count <= 1, "cascade logging must be bounded")
        try expect(terminal.count <= 2, "diagnostics must not retain or emit an unbounded terminal queue")
        try expect(diagnostics.snapshot.retainedTerminalCauseCount == 1, "only one terminal cause may be retained")
    }

    private static func heartbeatMetricsAreBoundedAndAggregated() throws {
        let events = LockedEvents()
        let diagnostics = makeDiagnostics(events: events, token: 91)
        for value in 0..<70_000 {
            diagnostics.recordHeartbeatPoll(schedulingLatenessMilliseconds: UInt64(value % 700))
            diagnostics.recordMatchedPong(roundTripMilliseconds: UInt64(value % 900))
        }
        _ = diagnostics.heartbeatTimedOut()

        guard let terminal = events.firstTerminal else { throw SpecFailure("missing heartbeat terminal event") }
        try expect(terminal.heartbeatPollCount == UInt16.max, "poll count must saturate instead of growing without bound")
        try expect(terminal.matchedPongCount == UInt16.max, "pong count must saturate instead of growing without bound")
        try expect(terminal.maximumHeartbeatSchedulingLatenessMilliseconds == 699, "maximum scheduling lateness must be aggregated")
        try expect(terminal.maximumMatchedPongRTTMilliseconds == 899, "maximum matched-Pong RTT must be aggregated")
    }

    private static func heartbeatTimingKeepsRTTSeparateFromQueueLateness() throws {
        let events = LockedEvents()
        let diagnostics = makeDiagnostics(events: events, token: 92)
        var heartbeat = CompanionControlHeartbeat()
        var schedule = CompanionHeartbeatPollSchedule(firstExpectedPollAt: 20)

        let firstPoll = schedule.poll(&heartbeat, now: 20)
        guard case let .ping(firstToken) = firstPoll.action else {
            throw SpecFailure("first poll must send a heartbeat")
        }
        diagnostics.recordHeartbeatPoll(
            schedulingLatenessMilliseconds: firstPoll.schedulingLatenessMilliseconds
        )
        for onTimePoll in stride(from: 20.5, through: 23.5, by: 0.5) {
            let observation = schedule.poll(&heartbeat, now: onTimePoll)
            diagnostics.recordHeartbeatPoll(
                schedulingLatenessMilliseconds: observation.schedulingLatenessMilliseconds
            )
            try expect(observation.action == .idle, "on-time pending polls stay idle")
        }
        guard let longRTT = heartbeat.receivePong(firstToken, now: 23.999) else {
            throw SpecFailure("valid long-RTT Pong must match")
        }
        diagnostics.recordMatchedPong(roundTripMilliseconds: longRTT)

        let secondPoll = schedule.poll(&heartbeat, now: 24)
        guard case let .ping(secondToken) = secondPoll.action else {
            throw SpecFailure("on-time poll after long RTT must send the suppressed due probe")
        }
        diagnostics.recordHeartbeatPoll(
            schedulingLatenessMilliseconds: secondPoll.schedulingLatenessMilliseconds
        )
        guard let immediateRTT = heartbeat.receivePong(secondToken, now: 24) else {
            throw SpecFailure("immediate Pong must match")
        }
        diagnostics.recordMatchedPong(roundTripMilliseconds: immediateRTT)

        for onTimePoll in [24.5, 25.0, 25.5] {
            let observation = schedule.poll(&heartbeat, now: onTimePoll)
            diagnostics.recordHeartbeatPoll(
                schedulingLatenessMilliseconds: observation.schedulingLatenessMilliseconds
            )
            try expect(observation.action == .idle, "pre-deadline polls stay idle")
        }
        let delayedPoll = schedule.poll(&heartbeat, now: 26.250)
        guard case .ping = delayedPoll.action else {
            throw SpecFailure("independently delayed poll must send the next probe")
        }
        diagnostics.recordHeartbeatPoll(
            schedulingLatenessMilliseconds: delayedPoll.schedulingLatenessMilliseconds
        )
        _ = diagnostics.localCancellation()

        guard let terminal = events.firstTerminal else { throw SpecFailure("missing timing summary") }
        try expect(terminal.maximumMatchedPongRTTMilliseconds == 3_999, "long RTT must remain in the RTT metric")
        try expect(terminal.maximumHeartbeatSchedulingLatenessMilliseconds == 250, "only actual timer delay enters scheduling lateness")
        try expect(terminal.heartbeatPollCount == 13, "every timer poll contributes to bounded scheduling summaries")
        try expect(terminal.matchedPongCount == 2, "only matched Pongs contribute RTT summaries")
    }

    @MainActor
    private static func generationCallbacksAndRecoveryAdmissionAreRecorded() throws {
        let events = LockedEvents()
        let recorder = CompanionRecoveryDiagnostics { events.append($0) }
        let supervisor = CompanionLogicalSessionRecoverySupervisor()
        let firstGeneration = supervisor.beginSession(companionID: "sensitive-companion-id")!

        let accepted = supervisor.requestRecovery(
            companionID: "sensitive-companion-id",
            generation: firstGeneration
        ) != nil
        recorder.recordCallback(
            bundleGeneration: firstGeneration,
            channel: .files,
            state: .failed,
            isCurrentGeneration: true,
            recoveryAccepted: accepted
        )
        for channel in [CompanionDiagnosticChannel.control, .events, .video, .audio, .camera] {
            let current = supervisor.currentGeneration(companionID: "sensitive-companion-id") == firstGeneration
            let siblingAccepted = supervisor.requestRecovery(
                companionID: "sensitive-companion-id",
                generation: firstGeneration
            ) != nil
            recorder.recordCallback(
                bundleGeneration: firstGeneration,
                channel: channel,
                state: .disconnected,
                isCurrentGeneration: current,
                recoveryAccepted: siblingAccepted
            )
        }

        let replacement = supervisor.beginSession(companionID: "sensitive-companion-id")!
        recorder.recordCallback(
            bundleGeneration: firstGeneration,
            channel: .control,
            state: .failed,
            isCurrentGeneration: supervisor.currentGeneration(companionID: "sensitive-companion-id") == firstGeneration,
            recoveryAccepted: false
        )
        recorder.recordCallback(
            bundleGeneration: replacement,
            channel: .control,
            state: .connected,
            isCurrentGeneration: supervisor.currentGeneration(companionID: "sensitive-companion-id") == replacement,
            recoveryAccepted: nil
        )
        recorder.recordRetry(bundleGeneration: firstGeneration, attempt: 3, delayMilliseconds: 5_000)

        let callbacks = events.values.filter { $0.kind == .callback }
        try expect(callbacks.filter { $0.recoveryDisposition == .accepted }.count == 1, "one sibling failure must accept recovery")
        try expect(callbacks.filter { $0.recoveryDisposition == .ignored }.count == 6, "cancellation and stale callbacks must remain visible as ignored")
        try expect(callbacks.last?.isCurrentGeneration == true, "replacement generation callback must be current")
        try expect(events.values.last?.kind == .retry, "retry attempt/delay must be recorded")
        try expect(events.values.last?.retryAttempt == 3, "retry attempt must be preserved")
        try expect(events.values.last?.retryDelayMilliseconds == 5_000, "retry delay must be preserved")
        try expect(!events.values.map(\.serialized).joined().contains("sensitive-companion-id"), "callbacks must not serialize companion identity")
    }

    private static func makeDiagnostics(
        events: LockedEvents,
        token: UInt64 = 41
    ) -> CompanionConnectionDiagnostics {
        CompanionConnectionDiagnostics(
            bundleGeneration: 7,
            channel: .control,
            connectionToken: token,
            monotonicNowNanoseconds: { 1_000_000_000 },
            sink: { events.append($0) }
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SpecFailure(message) }
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CompanionDiagnosticEvent] = []

    var values: [CompanionDiagnosticEvent] {
        lock.withLock { storage }
    }

    var firstTerminal: CompanionDiagnosticEvent? {
        values.first { $0.kind == .terminal && $0.terminalAdmission == .first }
    }

    func append(_ event: CompanionDiagnosticEvent) {
        lock.withLock { storage.append(event) }
    }
}

private struct SensitiveError: LocalizedError {
    var errorDescription: String? {
        "SECRET phone UUID host.local:47777 /Users/alice/private nonce clipboard pixels"
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
