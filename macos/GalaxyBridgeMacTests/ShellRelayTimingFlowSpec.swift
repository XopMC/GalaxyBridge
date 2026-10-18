import Foundation
@preconcurrency import Network

struct ShellCapabilityBridgeContext: Sendable {
    let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1)
    let peer = 0
    let hostID = "synthetic-host"
    let sessionID = "synthetic-session"
}
enum ShellCapabilityBridgeFailure: Error { case unavailable, timeout }
enum StubChannelKind { case enhancedStream }
enum StubConnectionState { case connected, failed, authenticationRejected, disconnected }
enum PrimaryMediaDiagnostics {
    static func isEnabled(arguments: [String], bundleID: String?) -> Bool { false }
}
final class CompanionTLSClient: @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CompanionTLSClient] = []
        func append(_ value: CompanionTLSClient) { lock.withLock { values.append(value) } }
        func at(_ index: Int) -> CompanionTLSClient? { lock.withLock { values.indices.contains(index) ? values[index] : nil } }
    }
    static let registry = Registry()
    let rawStreamID: String
    private let ready: @Sendable () -> Void
    private let deliver: @Sendable (Data, @escaping @Sendable () -> Void) -> Void
    init(endpoint: NWEndpoint, peer: Int, hostID: String, sessionID: String, channelKind: StubChannelKind,
         stateHandler: @escaping @Sendable (StubConnectionState) -> Void,
         envelopeHandler: @escaping @Sendable (Int, Int) -> Void, rawStreamID: String,
         rawReadyHandler: @escaping @Sendable () -> Void,
         rawDataHandler: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void) {
        self.rawStreamID = rawStreamID; ready = rawReadyHandler; deliver = rawDataHandler
    }
    func start() { Self.registry.append(self); ready() }
    func sendRaw(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) { completion(true) }
    func cancel() {}
    func inject(_ bytes: Data) async {
        await withCheckedContinuation { continuation in deliver(bytes) { continuation.resume() } }
    }
}
private final class Receipts: @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [ShellRelayDiagnostics.Summary] = []
    private var kinds: [String] = []
    func collector(_ kind: String) -> ShellRelayDiagnostics? {
        lock.withLock { kinds.append(kind) }
        guard kind == "video" else { return nil }
        return .init(generation: 11) { [self] summary in lock.withLock { summaries.append(summary) } }
    }
    var values: [ShellRelayDiagnostics.Summary] { lock.withLock { summaries } }
    var observedKinds: [String] { lock.withLock { kinds } }
}
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) { lock.withLock { storage.append(data) } }
    var bytes: Data { lock.withLock { storage } }
}
@main enum ShellRelayTimingFlowSpec {
    static func eventually(_ predicate: @Sendable () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ShellCapabilityBridgeFailure.timeout
    }
    static func main() async throws {
        let receipts = Receipts()
        let relay = try await ShellCapabilityBridgeRelay.start(context: .init(), leaseID: "synthetic-lease",
            types: ["video", "audio"], diagnosticsFactory: receipts.collector)
        let local = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: relay.port)!, using: .tcp)
        let incoming = Received(), queue = DispatchQueue(label: "synthetic-relay-reader")
        local.start(queue: queue)
        try await eventually { CompanionTLSClient.registry.at(0) != nil }
        let remote = CompanionTLSClient.registry.at(0)!
        precondition(remote.rawStreamID == "synthetic-lease/video")
        @Sendable func receive() {
            local.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { bytes, _, complete, error in
                if let bytes { incoming.append(bytes) }
                if !complete && error == nil { receive() }
            }
        }
        receive()
        await remote.inject(Data([1, 2, 3]))
        await remote.inject(Data([4, 5, 6, 7, 8]))
        try await eventually { incoming.bytes.count == 8 }
        precondition(incoming.bytes == Data(1...8), "Actual loopback relay changed byte ordering or content")
        let audio = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: relay.port)!, using: .tcp)
        audio.start(queue: queue)
        try await eventually { CompanionTLSClient.registry.at(1) != nil }
        precondition(CompanionTLSClient.registry.at(1)!.rawStreamID == "synthetic-lease/audio")
        relay.cancel(); relay.cancel()
        try await eventually { receipts.values.count == 1 }
        let summary = receipts.values[0]
        precondition(summary.totalChunks == 2 && summary.totalBytes == 8 && summary.invalidObservations == 0)
        precondition(summary.samples.count == 2 && summary.samples.allSatisfy { $0.succeeded == true && $0.forwardedAt! >= $0.receivedAt })
        precondition(receipts.observedKinds == ["video", "audio"])
        local.cancel(); audio.cancel()
        print("PASS actual relay wiring: upgraded raw byte ranges, real loopback ordering, contentProcessed completions, stream isolation and repeated cancellation")
    }
}
