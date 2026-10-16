#if !GALAXYBRIDGE_APP_STORE
import Foundation
import Network
import GalaxyBridgeProtocol

/// Loopback-only authenticated SOCKS adapter. The TLS channel retains the
/// existing peer pin/session authentication; no phone credentials cross it.
@MainActor
final class PairedInternetRelay {
    let endpoint: NWEndpoint
    let peer: PairedPeer
    let hostID: String
    let sessionID: String
    let leaseID: String
    let username: String
    let password: String
    private(set) var localPort: UInt16?
    var activeFlowCount: Int { flows.count }
    private var listener: NWListener?
    private var flows: [UUID: Flow] = [:]
    private var generation = UUID()
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var startTimeout: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.internet-loopback")

    init(endpoint: NWEndpoint, peer: PairedPeer, hostID: String, sessionID: String,
         leaseID: String, username: String, password: String) {
        self.endpoint = endpoint; self.peer = peer; self.hostID = hostID
        self.sessionID = sessionID; self.leaseID = leaseID
        self.username = username; self.password = password
    }

    func start() async throws -> UInt16 {
        if let localPort { return localPort }
        guard listener == nil, Self.hexSecret(username), Self.hexSecret(password), !leaseID.isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let attempt = UUID(); generation = attempt
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == attempt, self.flows.count < 32 else { connection.cancel(); return }
                let flow = Flow(connection: connection, relay: self)
                self.flows[flow.id] = flow
                flow.start(on: self.queue)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { self.failStart(); return }
                    self.localPort = port
                    self.startContinuation?.resume(returning: port); self.startContinuation = nil
                    self.startTimeout?.cancel(); self.startTimeout = nil
                case .failed, .cancelled: self.failStart()
                default: break
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            startTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.generation == attempt else { return }
                self.failStart()
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        generation = UUID()
        startTimeout?.cancel(); startTimeout = nil
        startContinuation?.resume(throwing: CancellationError()); startContinuation = nil
        listener?.cancel(); listener = nil; localPort = nil
        let retiring = Array(flows.values); flows.removeAll()
        for flow in retiring { flow.cancel() }
    }

    private func failStart() {
        startContinuation?.resume(throwing: CocoaError(.fileReadNoPermission)); startContinuation = nil
        stop()
    }
    private static func hexSecret(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    @MainActor private final class Flow {
        let id = UUID()
        enum Phase { case greeting, credentials, tlsReady, tlsGreeting, stream, closed }
        private var phase = Phase.greeting
        private let local: NWConnection
        private weak var relay: PairedInternetRelay?
        private var upstream: CompanionTLSClient?
        private var buffer = Data()
        private var tlsGreeting = Data()
        private var timeout: Task<Void, Never>?

        init(connection: NWConnection, relay: PairedInternetRelay) { local = connection; self.relay = relay }
        func start(on queue: DispatchQueue) {
            local.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.readLocal()
                    case .failed, .cancelled: self.cancel()
                    default: break
                    }
                }
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, self.phase != .stream else { return }
                self.cancel()
            }
            local.start(queue: queue)
        }
        func cancel() {
            guard phase != .closed else { return }
            phase = .closed; timeout?.cancel(); timeout = nil
            upstream?.cancel(); upstream = nil; local.cancel()
            buffer.removeAll(keepingCapacity: false); tlsGreeting.removeAll(keepingCapacity: false)
            relay?.flows.removeValue(forKey: id)
        }
        private func readLocal() {
            guard phase != .closed else { return }
            local.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] bytes, _, complete, error in
                Task { @MainActor in
                    guard let self, self.phase != .closed else { return }
                    guard error == nil, let bytes, !bytes.isEmpty else { self.cancel(); return }
                    if self.phase == .stream {
                        self.upstream?.sendRaw(bytes) { [weak self] sent in
                            Task { @MainActor in
                                guard let self else { return }
                                if sent && !complete { self.readLocal() } else { self.cancel() }
                            }
                        }
                    } else {
                        guard !complete, self.buffer.count + bytes.count <= 64 * 1024 else { self.cancel(); return }
                        self.buffer.append(bytes); self.consumeHandshake()
                    }
                }
            }
        }
        private func consumeHandshake() {
            guard let relay else { cancel(); return }
            if phase == .greeting {
                guard buffer.count >= 2 else { readLocal(); return }
                let greetingBytes = Array(buffer)
                let count = Int(greetingBytes[1]); guard greetingBytes[0] == 5, count > 0 else { cancel(); return }
                guard buffer.count >= count + 2 else { readLocal(); return }
                guard greetingBytes[2..<(count + 2)].contains(2) else { cancel(); return }
                buffer = Data(greetingBytes.dropFirst(count + 2)); phase = .credentials
                local.send(content: Data([5, 2]), completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in guard let self else { return }; if error == nil { self.consumeHandshake() } else { self.cancel() } }
                })
                return
            }
            if phase == .credentials {
                guard buffer.count >= 2 else { readLocal(); return }
                let credentialBytes = Array(buffer)
                let userCount = Int(credentialBytes[1]); guard credentialBytes[0] == 1, userCount == 64 else { cancel(); return }
                guard buffer.count >= 3 + userCount else { readLocal(); return }
                let passCount = Int(credentialBytes[2 + userCount]); guard passCount == 64 else { cancel(); return }
                let length = 3 + userCount + passCount
                guard buffer.count >= length else { readLocal(); return }
                let user = Data(credentialBytes[2..<(2 + userCount)])
                let pass = Data(credentialBytes[(3 + userCount)..<length])
                guard Self.equal(user, Data(relay.username.utf8)), Self.equal(pass, Data(relay.password.utf8)) else { cancel(); return }
                buffer = Data(credentialBytes.dropFirst(length)); phase = .tlsReady
                local.send(content: Data([1, 0]), completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in guard let self else { return }; if error == nil { self.connectTLS() } else { self.cancel() } }
                })
            }
        }
        private static func equal(_ a: Data, _ b: Data) -> Bool {
            guard a.count == b.count else { return false }
            return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }
        private func connectTLS() {
            guard let relay, phase == .tlsReady else { cancel(); return }
            let client = CompanionTLSClient(endpoint: relay.endpoint, peer: relay.peer, hostID: relay.hostID,
                sessionID: relay.sessionID, channelKind: .internetProxy,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        switch state { case .failed, .authenticationRejected, .disconnected: self?.cancel(); default: break }
                    }
                }, envelopeHandler: { _, _ in }, rawStreamID: relay.leaseID,
                rawReadyHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.phase == .tlsReady else { return }
                        self.phase = .tlsGreeting
                        self.upstream?.sendRaw(Data([5, 1, 0])) { [weak self] sent in
                            if !sent { Task { @MainActor in self?.cancel() } }
                        }
                    }
                }, rawDataHandler: { [weak self] bytes, finished in
                    Task { @MainActor in self?.receiveTLS(bytes, finished: finished) ?? finished() }
                })
            upstream = client; client.start()
        }
        private func receiveTLS(_ bytes: Data, finished: @escaping @Sendable () -> Void) {
            guard phase != .closed else { finished(); return }
            if phase == .tlsGreeting {
                tlsGreeting.append(bytes)
                guard tlsGreeting.count >= 2 else { finished(); return }
                guard tlsGreeting.prefix(2) == Data([5, 0]) else { finished(); cancel(); return }
                tlsGreeting.removeFirst(2); phase = .stream; timeout?.cancel(); timeout = nil
                let extra = tlsGreeting; tlsGreeting.removeAll()
                if !buffer.isEmpty {
                    let pending = buffer; buffer.removeAll()
                    upstream?.sendRaw(pending) { [weak self] sent in
                        Task { @MainActor in if sent { self?.readLocal() } else { self?.cancel() } }
                    }
                } else { readLocal() }
                if extra.isEmpty { finished(); return }
                sendToLocal(extra, finished: finished); return
            }
            guard phase == .stream else { finished(); cancel(); return }
            sendToLocal(bytes, finished: finished)
        }
        private func sendToLocal(_ bytes: Data, finished: @escaping @Sendable () -> Void) {
            local.send(content: bytes, completion: .contentProcessed { [weak self] error in
                finished()
                if error != nil { Task { @MainActor in self?.cancel() } }
            })
        }
    }
}
#endif
