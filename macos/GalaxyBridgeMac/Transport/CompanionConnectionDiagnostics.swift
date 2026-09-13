import Foundation
import Network

enum CompanionDiagnosticChannel: String, Sendable {
    case bundle
    case control
    case events
    case video
    case audio
    case files
    case camera
    case unknown
}

enum CompanionDiagnosticPhase: String, Sendable {
    case connecting
    case authenticationPreparation = "authentication_preparation"
    case awaitingHello = "awaiting_hello"
    case active
    case openChannelRequested = "open_channel_requested"
}

enum CompanionDiagnosticMilestone: String, Hashable, Sendable {
    case connectionStarted = "connection_started"
    case networkReady = "network_ready"
    case authenticationPrepared = "authentication_prepared"
    case helloReceived = "hello_received"
    case openChannelRequested = "open_channel_requested"
    case bundleStarted = "bundle_started"
}

enum CompanionDiagnosticTerminalOrigin: String, Sendable {
    case authenticationPreparation = "authentication_preparation"
    case pathWaiting = "path_waiting"
    case networkFailure = "network_failure"
    case send
    case receive
    case peerEOF = "peer_eof"
    case controlDecode = "control_decode"
    case heartbeatTimeout = "heartbeat_timeout"
    case connectingWatchdog = "connecting_watchdog"
    case localCancellation = "local_cancellation"
}

enum CompanionDiagnosticReasonCode: String, Sendable {
    case authenticationPreparationFailure = "authentication_preparation_failure"
    case networkError = "network_error"
    case unknownError = "unknown_error"
    case peerEOF = "peer_eof"
    case controlDecode = "control_decode_failure"
    case heartbeatTimeout = "heartbeat_timeout"
    case connectingWatchdog = "connecting_watchdog_timeout"
    case intentionalLocalCancellation = "intentional_local_cancellation"
}

enum CompanionDiagnosticTerminalAdmission: String, Sendable {
    case first
    case cascade
    case suppressed
}

enum CompanionDiagnosticNetworkDomain: String, Sendable {
    case posix = "nw.posix"
    case dns = "nw.dns"
    case tls = "nw.tls"
}

struct CompanionDiagnosticNetworkError: Equatable, Sendable {
    let domain: CompanionDiagnosticNetworkDomain
    let code: Int64
}

enum CompanionDiagnosticEventKind: String, Sendable {
    case milestone
    case terminal
    case callback
    case retry
}

enum CompanionDiagnosticCallbackState: String, Sendable {
    case connecting
    case connected
    case failed
    case disconnected
}

enum CompanionDiagnosticRecoveryDisposition: String, Sendable {
    case accepted
    case ignored
    case notApplicable = "not_applicable"
}

struct CompanionDiagnosticEvent: Equatable, Sendable {
    let kind: CompanionDiagnosticEventKind
    let bundleGeneration: UInt64
    let channel: CompanionDiagnosticChannel
    let connectionToken: UInt64?
    let phase: CompanionDiagnosticPhase?
    let elapsedMilliseconds: UInt64?
    let milestone: CompanionDiagnosticMilestone?
    let origin: CompanionDiagnosticTerminalOrigin?
    let reasonCode: CompanionDiagnosticReasonCode?
    let terminalAdmission: CompanionDiagnosticTerminalAdmission?
    let initiatingFailure: Bool?
    let networkError: CompanionDiagnosticNetworkError?
    let heartbeatPollCount: UInt16?
    let matchedPongCount: UInt16?
    let maximumHeartbeatSchedulingLatenessMilliseconds: UInt64?
    let maximumMatchedPongRTTMilliseconds: UInt64?
    let callbackState: CompanionDiagnosticCallbackState?
    let isCurrentGeneration: Bool?
    let recoveryDisposition: CompanionDiagnosticRecoveryDisposition?
    let retryAttempt: Int?
    let retryDelayMilliseconds: UInt64?

    var serialized: String {
        var fields = [
            "event=\(kind.rawValue)",
            "generation=\(bundleGeneration)",
            "channel=\(channel.rawValue)",
        ]
        if let connectionToken { fields.append("connection=\(connectionToken)") }
        if let phase { fields.append("phase=\(phase.rawValue)") }
        if let elapsedMilliseconds { fields.append("elapsed_ms=\(elapsedMilliseconds)") }
        if let milestone { fields.append("milestone=\(milestone.rawValue)") }
        if let origin { fields.append("origin=\(origin.rawValue)") }
        if let reasonCode { fields.append("reason=\(reasonCode.rawValue)") }
        if let terminalAdmission { fields.append("admission=\(terminalAdmission.rawValue)") }
        if let initiatingFailure { fields.append("initiating=\(initiatingFailure ? 1 : 0)") }
        if let networkError {
            fields.append("nw_domain=\(networkError.domain.rawValue)")
            fields.append("nw_code=\(networkError.code)")
        }
        if let heartbeatPollCount { fields.append("heartbeat_polls=\(heartbeatPollCount)") }
        if let matchedPongCount { fields.append("matched_pongs=\(matchedPongCount)") }
        if let maximumHeartbeatSchedulingLatenessMilliseconds {
            fields.append("max_heartbeat_late_ms=\(maximumHeartbeatSchedulingLatenessMilliseconds)")
        }
        if let maximumMatchedPongRTTMilliseconds {
            fields.append("max_pong_rtt_ms=\(maximumMatchedPongRTTMilliseconds)")
        }
        if let callbackState { fields.append("state=\(callbackState.rawValue)") }
        if let isCurrentGeneration { fields.append("current=\(isCurrentGeneration ? 1 : 0)") }
        if let recoveryDisposition { fields.append("recovery=\(recoveryDisposition.rawValue)") }
        if let retryAttempt { fields.append("attempt=\(retryAttempt)") }
        if let retryDelayMilliseconds { fields.append("delay_ms=\(retryDelayMilliseconds)") }
        return fields.joined(separator: " ")
    }
}

struct CompanionConnectionDiagnosticsSnapshot: Equatable, Sendable {
    let retainedTerminalCauseCount: Int
    let heartbeatPollCount: UInt16
    let matchedPongCount: UInt16
}

final class CompanionConnectionDiagnostics: @unchecked Sendable {
    typealias Sink = @Sendable (CompanionDiagnosticEvent) -> Void
    typealias MonotonicClock = @Sendable () -> UInt64

    private struct State {
        var phase: CompanionDiagnosticPhase = .connecting
        var emittedMilestones = Set<CompanionDiagnosticMilestone>()
        var firstTerminalOrigin: CompanionDiagnosticTerminalOrigin?
        var emittedCascade = false
        var heartbeatPollCount: UInt16 = 0
        var matchedPongCount: UInt16 = 0
        var maximumHeartbeatSchedulingLatenessMilliseconds: UInt64 = 0
        var maximumMatchedPongRTTMilliseconds: UInt64 = 0
    }

    private let bundleGeneration: UInt64
    private let channel: CompanionDiagnosticChannel
    private let connectionToken: UInt64
    private let monotonicNowNanoseconds: MonotonicClock
    private let startedAtNanoseconds: UInt64
    private let sink: Sink
    private let lock = NSLock()
    private var state = State()

    init(
        bundleGeneration: UInt64,
        channel: CompanionDiagnosticChannel,
        connectionToken: UInt64 = CompanionDiagnosticTokenAllocator.shared.next(),
        monotonicNowNanoseconds: @escaping MonotonicClock = { DispatchTime.now().uptimeNanoseconds },
        sink: @escaping Sink
    ) {
        self.bundleGeneration = bundleGeneration
        self.channel = channel
        self.connectionToken = connectionToken
        self.monotonicNowNanoseconds = monotonicNowNanoseconds
        startedAtNanoseconds = monotonicNowNanoseconds()
        self.sink = sink
    }

    var snapshot: CompanionConnectionDiagnosticsSnapshot {
        lock.withLock {
            CompanionConnectionDiagnosticsSnapshot(
                retainedTerminalCauseCount: state.firstTerminalOrigin == nil ? 0 : 1,
                heartbeatPollCount: state.heartbeatPollCount,
                matchedPongCount: state.matchedPongCount
            )
        }
    }

    func connectionStarted() {
        recordMilestone(.connectionStarted, phase: .connecting)
    }

    func networkReady() {
        recordMilestone(.networkReady, phase: .authenticationPreparation)
    }

    func authenticationPrepared() {
        recordMilestone(.authenticationPrepared, phase: .awaitingHello)
    }

    func helloReceived() {
        recordMilestone(.helloReceived, phase: .active)
    }

    func openChannelRequested() {
        recordMilestone(.openChannelRequested, phase: .openChannelRequested)
    }

    @discardableResult
    func authenticationPreparationFailed(_: Error) -> CompanionDiagnosticTerminalAdmission {
        recordTerminal(
            origin: .authenticationPreparation,
            reasonCode: .authenticationPreparationFailure,
            networkError: nil
        )
    }

    @discardableResult
    func pathWaiting(_ error: Error) -> CompanionDiagnosticTerminalAdmission {
        recordNetworkTerminal(origin: .pathWaiting, error: error)
    }

    @discardableResult
    func networkFailed(_ error: Error) -> CompanionDiagnosticTerminalAdmission {
        recordNetworkTerminal(origin: .networkFailure, error: error)
    }

    @discardableResult
    func sendFailed(_ error: Error) -> CompanionDiagnosticTerminalAdmission {
        recordNetworkTerminal(origin: .send, error: error)
    }

    @discardableResult
    func receiveFailed(_ error: Error) -> CompanionDiagnosticTerminalAdmission {
        recordNetworkTerminal(origin: .receive, error: error)
    }

    @discardableResult
    func peerEOF() -> CompanionDiagnosticTerminalAdmission {
        recordTerminal(origin: .peerEOF, reasonCode: .peerEOF, networkError: nil)
    }

    @discardableResult
    func controlDecodeFailed(_: Error) -> CompanionDiagnosticTerminalAdmission {
        recordTerminal(origin: .controlDecode, reasonCode: .controlDecode, networkError: nil)
    }

    @discardableResult
    func heartbeatTimedOut() -> CompanionDiagnosticTerminalAdmission {
        recordTerminal(origin: .heartbeatTimeout, reasonCode: .heartbeatTimeout, networkError: nil)
    }

    @discardableResult
    func connectingWatchdogTimedOut() -> CompanionDiagnosticTerminalAdmission {
        recordTerminal(origin: .connectingWatchdog, reasonCode: .connectingWatchdog, networkError: nil)
    }

    @discardableResult
    func localCancellation() -> CompanionDiagnosticTerminalAdmission {
        recordTerminal(
            origin: .localCancellation,
            reasonCode: .intentionalLocalCancellation,
            networkError: nil
        )
    }

    func recordHeartbeatPoll(schedulingLatenessMilliseconds: UInt64) {
        lock.withLock {
            state.heartbeatPollCount = saturatingIncrement(state.heartbeatPollCount)
            state.maximumHeartbeatSchedulingLatenessMilliseconds = max(
                state.maximumHeartbeatSchedulingLatenessMilliseconds,
                schedulingLatenessMilliseconds
            )
        }
    }

    func recordMatchedPong(roundTripMilliseconds: UInt64) {
        lock.withLock {
            state.matchedPongCount = saturatingIncrement(state.matchedPongCount)
            state.maximumMatchedPongRTTMilliseconds = max(
                state.maximumMatchedPongRTTMilliseconds,
                roundTripMilliseconds
            )
        }
    }

    private func recordMilestone(
        _ milestone: CompanionDiagnosticMilestone,
        phase: CompanionDiagnosticPhase
    ) {
        let event = lock.withLock { () -> CompanionDiagnosticEvent? in
            state.phase = phase
            guard state.emittedMilestones.insert(milestone).inserted else { return nil }
            return makeEvent(kind: .milestone, phase: phase, milestone: milestone)
        }
        if let event { sink(event) }
    }

    private func recordNetworkTerminal(
        origin: CompanionDiagnosticTerminalOrigin,
        error: Error
    ) -> CompanionDiagnosticTerminalAdmission {
        let networkError = CompanionDiagnosticNetworkError.sanitized(error)
        return recordTerminal(
            origin: origin,
            reasonCode: networkError == nil ? .unknownError : .networkError,
            networkError: networkError
        )
    }

    private func recordTerminal(
        origin: CompanionDiagnosticTerminalOrigin,
        reasonCode: CompanionDiagnosticReasonCode,
        networkError: CompanionDiagnosticNetworkError?
    ) -> CompanionDiagnosticTerminalAdmission {
        let result = lock.withLock { () -> (CompanionDiagnosticTerminalAdmission, CompanionDiagnosticEvent?) in
            let admission: CompanionDiagnosticTerminalAdmission
            if state.firstTerminalOrigin == nil {
                state.firstTerminalOrigin = origin
                admission = .first
            } else if !state.emittedCascade {
                state.emittedCascade = true
                admission = .cascade
            } else {
                return (.suppressed, nil)
            }
            return (
                admission,
                makeEvent(
                    kind: .terminal,
                    phase: state.phase,
                    origin: origin,
                    reasonCode: reasonCode,
                    terminalAdmission: admission,
                    initiatingFailure: admission == .first && origin != .localCancellation,
                    networkError: networkError,
                    includeHeartbeatSummary: true
                )
            )
        }
        if let event = result.1 { sink(event) }
        return result.0
    }

    private func makeEvent(
        kind: CompanionDiagnosticEventKind,
        phase: CompanionDiagnosticPhase,
        milestone: CompanionDiagnosticMilestone? = nil,
        origin: CompanionDiagnosticTerminalOrigin? = nil,
        reasonCode: CompanionDiagnosticReasonCode? = nil,
        terminalAdmission: CompanionDiagnosticTerminalAdmission? = nil,
        initiatingFailure: Bool? = nil,
        networkError: CompanionDiagnosticNetworkError? = nil,
        includeHeartbeatSummary: Bool = false
    ) -> CompanionDiagnosticEvent {
        CompanionDiagnosticEvent(
            kind: kind,
            bundleGeneration: bundleGeneration,
            channel: channel,
            connectionToken: connectionToken,
            phase: phase,
            elapsedMilliseconds: elapsedMilliseconds(),
            milestone: milestone,
            origin: origin,
            reasonCode: reasonCode,
            terminalAdmission: terminalAdmission,
            initiatingFailure: initiatingFailure,
            networkError: networkError,
            heartbeatPollCount: includeHeartbeatSummary ? state.heartbeatPollCount : nil,
            matchedPongCount: includeHeartbeatSummary ? state.matchedPongCount : nil,
            maximumHeartbeatSchedulingLatenessMilliseconds: includeHeartbeatSummary
                ? state.maximumHeartbeatSchedulingLatenessMilliseconds : nil,
            maximumMatchedPongRTTMilliseconds: includeHeartbeatSummary
                ? state.maximumMatchedPongRTTMilliseconds : nil,
            callbackState: nil,
            isCurrentGeneration: nil,
            recoveryDisposition: nil,
            retryAttempt: nil,
            retryDelayMilliseconds: nil
        )
    }

    private func elapsedMilliseconds() -> UInt64 {
        let now = monotonicNowNanoseconds()
        guard now >= startedAtNanoseconds else { return 0 }
        return (now - startedAtNanoseconds) / 1_000_000
    }

    private func saturatingIncrement(_ value: UInt16) -> UInt16 {
        value == .max ? .max : value + 1
    }
}

struct CompanionRecoveryDiagnostics: Sendable {
    typealias Sink = @Sendable (CompanionDiagnosticEvent) -> Void
    private let sink: Sink

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func recordBundleStarted(bundleGeneration: UInt64) {
        sink(
            event(
                kind: .milestone,
                bundleGeneration: bundleGeneration,
                channel: .bundle,
                milestone: .bundleStarted
            )
        )
    }

    func recordCallback(
        bundleGeneration: UInt64,
        channel: CompanionDiagnosticChannel,
        state: CompanionDiagnosticCallbackState,
        isCurrentGeneration: Bool,
        recoveryAccepted: Bool?
    ) {
        let recoveryDisposition: CompanionDiagnosticRecoveryDisposition
        switch recoveryAccepted {
        case true: recoveryDisposition = .accepted
        case false: recoveryDisposition = .ignored
        case nil: recoveryDisposition = .notApplicable
        }
        sink(
            event(
                kind: .callback,
                bundleGeneration: bundleGeneration,
                channel: channel,
                callbackState: state,
                isCurrentGeneration: isCurrentGeneration,
                recoveryDisposition: recoveryDisposition
            )
        )
    }

    func recordRetry(
        bundleGeneration: UInt64,
        attempt: Int,
        delayMilliseconds: UInt64
    ) {
        sink(
            event(
                kind: .retry,
                bundleGeneration: bundleGeneration,
                channel: .bundle,
                retryAttempt: attempt,
                retryDelayMilliseconds: delayMilliseconds
            )
        )
    }

    private func event(
        kind: CompanionDiagnosticEventKind,
        bundleGeneration: UInt64,
        channel: CompanionDiagnosticChannel,
        milestone: CompanionDiagnosticMilestone? = nil,
        callbackState: CompanionDiagnosticCallbackState? = nil,
        isCurrentGeneration: Bool? = nil,
        recoveryDisposition: CompanionDiagnosticRecoveryDisposition? = nil,
        retryAttempt: Int? = nil,
        retryDelayMilliseconds: UInt64? = nil
    ) -> CompanionDiagnosticEvent {
        CompanionDiagnosticEvent(
            kind: kind,
            bundleGeneration: bundleGeneration,
            channel: channel,
            connectionToken: nil,
            phase: nil,
            elapsedMilliseconds: nil,
            milestone: milestone,
            origin: nil,
            reasonCode: nil,
            terminalAdmission: nil,
            initiatingFailure: nil,
            networkError: nil,
            heartbeatPollCount: nil,
            matchedPongCount: nil,
            maximumHeartbeatSchedulingLatenessMilliseconds: nil,
            maximumMatchedPongRTTMilliseconds: nil,
            callbackState: callbackState,
            isCurrentGeneration: isCurrentGeneration,
            recoveryDisposition: recoveryDisposition,
            retryAttempt: retryAttempt,
            retryDelayMilliseconds: retryDelayMilliseconds
        )
    }
}

private extension CompanionDiagnosticNetworkError {
    static func sanitized(_ error: Error) -> CompanionDiagnosticNetworkError? {
        guard let networkError = error as? NWError else { return nil }
        switch networkError {
        case let .posix(code):
            return CompanionDiagnosticNetworkError(domain: .posix, code: Int64(code.rawValue))
        case let .dns(code):
            return CompanionDiagnosticNetworkError(domain: .dns, code: Int64(code))
        case let .tls(code):
            return CompanionDiagnosticNetworkError(domain: .tls, code: Int64(code))
        case .wifiAware:
            return nil
        @unknown default:
            return nil
        }
    }
}

private final class CompanionDiagnosticTokenAllocator: @unchecked Sendable {
    static let shared = CompanionDiagnosticTokenAllocator()

    private let lock = NSLock()
    private var nextToken: UInt64 = 0

    func next() -> UInt64 {
        lock.withLock {
            nextToken &+= 1
            return nextToken
        }
    }
}
