#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeProtocol
@preconcurrency import Network

/// One loopback-only listener maps the existing ordered scrcpy socket opens to
/// authenticated raw channels. Each direction has one <=64KiB outstanding send.
final class ShellCapabilityBridgeRelay: @unchecked Sendable {
    private final class Completion: @unchecked Sendable { var done = false }
    private final class Pipe: @unchecked Sendable {
        let local: NWConnection
        let queue: DispatchQueue
        var remote: CompanionTLSClient?
        let diagnostics: ShellRelayDiagnostics?
        init(local: NWConnection, queue: DispatchQueue, diagnostics: ShellRelayDiagnostics?) {
            self.local = local; self.queue = queue; self.diagnostics = diagnostics
        }
        func read() {
            local.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { return }
                guard error == nil else { cancel(); return }
                guard let data, !data.isEmpty, let remote else { if complete { cancel() } else { read() }; return }
                remote.sendRaw(data) { [weak self] accepted in
                    guard let self else { return }
                    queue.async { if accepted && !complete { self.read() } else { self.cancel() } }
                }
            }
        }
        func cancel() { local.cancel(); remote?.cancel(); diagnostics?.finish() }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.shell-relay")
    typealias DiagnosticsFactory = @Sendable (String) -> ShellRelayDiagnostics?
    private let diagnosticsFactory: DiagnosticsFactory
    private let context: ShellCapabilityBridgeContext
    private let leaseID: String
    private var remaining: [String]
    private var pipes: [Pipe] = []
    private(set) var port: UInt16 = 0
    private init(context: ShellCapabilityBridgeContext, leaseID: String, types: [String], diagnosticsFactory: @escaping DiagnosticsFactory) throws {
        self.context = context; self.leaseID = leaseID; remaining = types; self.diagnosticsFactory = diagnosticsFactory
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    private static func defaultDiagnostics(_ kind: String) -> ShellRelayDiagnostics? {
        let arguments = ProcessInfo.processInfo.arguments, bundleID = Bundle.main.bundleIdentifier
        return ShellRelayDiagnostics.make(enabled: kind == "video"
            && PrimaryMediaDiagnostics.isEnabled(arguments: arguments, bundleID: bundleID)
            && arguments.contains(ShellRelayDiagnostics.argument)) {
            ShellRelayDiagnostics.logging(bundleID: bundleID ?? "com.xopmc.GalaxyBridge")
        }
    }
    static func start(context: ShellCapabilityBridgeContext, leaseID: String, types: [String],
                      diagnosticsFactory: @escaping DiagnosticsFactory = defaultDiagnostics) async throws -> ShellCapabilityBridgeRelay {
        let relay = try ShellCapabilityBridgeRelay(context: context, leaseID: leaseID, types: types, diagnosticsFactory: diagnosticsFactory)
        return try await withCheckedThrowingContinuation { continuation in
            let completion = Completion()
            relay.listener.stateUpdateHandler = { state in
                guard !completion.done else { return }
                switch state {
                case .ready:
                    guard let port = relay.listener.port else { return }
                    completion.done = true; relay.port = port.rawValue; relay.listener.stateUpdateHandler = nil
                    continuation.resume(returning: relay)
                case .failed:
                    completion.done = true; relay.cancel(); continuation.resume(throwing: ShellCapabilityBridgeFailure.unavailable)
                default: break
                }
            }
            relay.listener.newConnectionHandler = { [weak relay] connection in relay?.accept(connection) }
            relay.listener.start(queue: relay.queue)
            relay.queue.asyncAfter(deadline: .now() + 5) {
                if !completion.done { completion.done = true; relay.cancel(); continuation.resume(throwing: ShellCapabilityBridgeFailure.timeout) }
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard !remaining.isEmpty else { connection.cancel(); return }
        let type = remaining.removeFirst(), context = context
        let pipe = Pipe(local: connection, queue: queue, diagnostics: diagnosticsFactory(type)); pipes.append(pipe)
        let remote = CompanionTLSClient(endpoint: context.endpoint, peer: context.peer, hostID: context.hostID,
            sessionID: context.sessionID, channelKind: .enhancedStream,
            stateHandler: { [weak pipe] state in
                switch state { case .failed, .authenticationRejected, .disconnected: pipe?.cancel(); default: break }
            }, envelopeHandler: { _, _ in }, rawStreamID: leaseID + "/" + type,
            rawReadyHandler: { [weak pipe] in guard let pipe else { return }; pipe.queue.async { pipe.read() } },
            rawDataHandler: { [weak pipe] data, next in
                guard let pipe else { next(); return }
                let ticket = pipe.diagnostics?.received(bytes: data.count)
                pipe.local.send(content: data, completion: .contentProcessed { error in
                    if let ticket { pipe.diagnostics?.forwarded(ticket, succeeded: error == nil) }
                    next(); if error != nil { pipe.cancel() }
                })
            })
        pipe.remote = remote; connection.start(queue: queue); remote.start()
        if remaining.isEmpty { listener.cancel() }
    }
    func cancel() {
        queue.async { [self] in
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
            pipes.forEach { $0.cancel() }; pipes.removeAll()
        }
    }
}
#endif
