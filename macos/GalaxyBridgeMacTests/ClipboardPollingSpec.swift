import Foundation

@MainActor final class PollControlSocket {
    var sent: [Data] = []
    func send(_ data: Data) { sent.append(data) }
}
@MainActor final class PollAgentSocket {
    var writes = 0
    func setText(_ value: String, changeID: String) -> Bool { writes += 1; return true }
    func cancel() {}
}
enum ScrcpyControlMessage {
    static func getClipboard() -> Data { Data([9]) }
    static func setClipboard(sequence: UInt64, text: String, paste: Bool) -> Data { Data([10]) + Data(text.utf8) }
}
struct PollEchoes {
    mutating func shouldForward(_ data: Data) -> Bool { true }
    mutating func markInjected(_ data: Data) {}
}
@MainActor final class ClipboardPollingProbe {
    enum State { case preparing, ready }
    var state = State.preparing
    var generation = UUID()
    var pollTask: Task<Void, Never>?
    var controlSocket: PollControlSocket? = PollControlSocket()
    var agentSocket: PollAgentSocket? = PollAgentSocket()
    var pendingAgentMessage: ScrcpyClipboardAgentMessage?
    var usesClipboardOccurrences = false
    var supportsClipboardAvailability = false
    var serial = "fixture", sessionID = "session"
    var lastObservedContent: Data?
    var receiveSequence: UInt64 = 1, sendSequence: UInt64 = 1
    var injectedEchoes = PollEchoes()
    var readyHandler: (String) -> Void = { _ in }
    var clipboardEventHandler: ((ScrcpyClipboardUpdate) -> Void)?
    var clipboardUnavailableHandler: (() -> Void)?
    var failures = 0
    func fail(request: UUID, reason: String) { failures += 1 }
    // ACTUAL_CLIPBOARD_METHODS
}

final class AgentInputProbe {
    var decoder = ScrcpyClipboardAgentDecoder()
    var readyHandler: (Bool) -> Void = { _ in }
    var messageHandler: (ScrcpyClipboardAgentMessage) -> Void = { _ in }
    // ACTUAL_AGENT_INPUT_METHOD
}

@main enum ClipboardPollingSpec {
    @MainActor static func main() async throws {
        let wire = AgentInputProbe()
        var handshakes: [Bool] = []
        wire.readyHandler = { handshakes.append($0) }
        try wire.consume(Data("GBC".utf8))
        precondition(handshakes.isEmpty, "A partial preamble is not an agent handshake")
        try wire.consume(Data("2".utf8))
        precondition(handshakes == [true], "An empty GBC2 clipboard must negotiate before its first payload")
        try wire.consume(Data())
        precondition(handshakes == [true], "The socket must emit protocol readiness once")
        let legacyWire = AgentInputProbe()
        legacyWire.readyHandler = { handshakes.append($0) }
        try legacyWire.consume(Data("GBC1".utf8))
        precondition(handshakes == [true, false], "GBC1 must retain legacy fallback semantics")

        let probe = ClipboardPollingProbe(), request = probe.generation
        var received: [ScrcpyClipboardUpdate] = []
        probe.clipboardEventHandler = { received.append($0) }
        probe.didBecomeReady(request: request)
        probe.didBecomeAgentReady(usesOccurrences: true, request: request)
        let stockReads = probe.controlSocket!.sent.count
        try await Task.sleep(for: .milliseconds(650))
        precondition(probe.controlSocket!.sent.count == stockReads,
            "Confirmed occurrence-agent must stop stock GET_CLIPBOARD polling")
        probe.receiveAgent(.init(kind: .text, content: Data("copy".utf8), timestamp: 1), request: request)
        probe.receiveAgent(.init(kind: .png, content: Data([137, 80, 78, 71]), timestamp: 2), request: request)
        precondition(received.count == 2 && received[0].kind == .text && received[1].kind == .png,
            "Stopping redundant reads must preserve genuine text and image delivery")
        var unavailable = 0
        probe.clipboardUnavailableHandler = { unavailable += 1 }
        probe.receiveAgent(.init(kind: .text, content: Data(), timestamp: 0, isAvailable: false), request: request)
        precondition(unavailable == 1 && received.count == 2 && probe.lastObservedContent == nil,
            "Empty/sensitive/unsupported clipboard must invalidate the target claim without becoming an exported copy")
        precondition(probe.setText("outbound", changeID: "hub:write") && probe.agentSocket?.writes == 1,
            "Confirmed occurrence protocol must retain text writes")
        probe.pollTask?.cancel()

        let early = ClipboardPollingProbe()
        early.didBecomeAgentReady(usesOccurrences: true, request: early.generation)
        early.didBecomeReady(request: early.generation)
        precondition(early.pollTask == nil && early.controlSocket!.sent.isEmpty,
            "Agent-first ordering must never start the stock content reader")

        let fallback = ClipboardPollingProbe(), previous = UUID()
        fallback.didBecomeReady(request: fallback.generation)
        fallback.agentUnavailable(request: fallback.generation, reason: "missing legacy agent")
        fallback.didBecomeAgentReady(usesOccurrences: true, request: previous)
        fallback.agentUnavailable(request: previous, reason: "stale socket")
        precondition(!fallback.usesClipboardOccurrences && fallback.pollTask != nil && fallback.failures == 0,
            "Missing or stale agent must not cancel the current generation's legacy fallback")
        try await Task.sleep(for: .milliseconds(1200))
        precondition(!fallback.controlSocket!.sent.isEmpty, "Missing agent must retain bounded legacy clipboard polling")
        fallback.didBecomeAgentReady(usesOccurrences: true, request: fallback.generation)
        precondition(!fallback.usesClipboardOccurrences,
            "A retired socket's late handshake must not promote its failed agent")
        fallback.pollTask?.cancel()
        let late = ClipboardPollingProbe()
        late.didBecomeReady(request: late.generation)
        try await Task.sleep(for: .milliseconds(1200))
        precondition(!late.controlSocket!.sent.isEmpty)
        late.didBecomeAgentReady(usesOccurrences: true, request: late.generation)
        let before = late.controlSocket!.sent.count
        try await Task.sleep(for: .milliseconds(600))
        precondition(late.controlSocket!.sent.count == before && late.pollTask == nil,
            "A late occurrence handshake must cancel an already-running fallback")
        print("PASS actual clipboard polling/socket parser: GBC2 handshake without payload, agent-first/ready-first and late handshake stop stock reads, genuine text/images/writes, bounded missing/legacy fallback and stale-generation isolation")
    }
}
