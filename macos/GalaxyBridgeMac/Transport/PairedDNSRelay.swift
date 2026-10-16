#if !GALAXYBRIDGE_APP_STORE
import Foundation
enum PairedDNSWire {
    enum Response: Equatable { case incomplete, invalid, complete(Data) }
    static func validQuery(_ wire: Data) -> Bool {
        wire.count >= 12 && wire.count <= 65_535 && wire[wire.startIndex + 2] & 0xf8 == 0
    }
    static func frame(_ wire: Data) -> Data? {
        guard wire.count >= 12, wire.count <= 65_535 else { return nil }
        var result = Data([UInt8(wire.count >> 8), UInt8(wire.count & 255)]); result.append(wire); return result
    }
    static func response(_ framed: Data, for query: Data) -> Response {
        guard framed.count <= 65_537, query.count >= 12 else { return .invalid }
        guard framed.count >= 2 else { return .incomplete }
        let prefix = Array(framed.prefix(2)); let count = Int(prefix[0]) << 8 | Int(prefix[1])
        guard count >= 12 else { return .invalid }
        guard framed.count >= count + 2 else { return .incomplete }
        guard framed.count == count + 2 else { return .invalid }
        let wire = Data(framed.dropFirst(2)); let header = Array(wire.prefix(3)); let expected = Array(query.prefix(2))
        guard header[0] == expected[0], header[1] == expected[1], header[2] & 0x80 != 0 else { return .invalid }
        return .complete(wire)
    }
}
#if !GB_PAIRED_DNS_WIRE_TEST
import Network
import GalaxyBridgeProtocol

/// Local UDP and TCP DNS use the same ephemeral loopback port. Every complete
/// query travels over a fresh authenticated, peer-pinned TLS DNS channel; the
/// selected Android Network's resolver handles the full wire message.
@MainActor
final class PairedDNSRelay {
    private let selectGateway: (Set<String>) -> PairedInternetRelay?
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.paired-dns")
    private var udp: NWListener?
    private var tcp: NWListener?
    private var clients: [UUID: Client] = [:]
    private var queries: [UUID: Query] = [:]
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private(set) var localPort: UInt16?

    init(selectGateway: @escaping (Set<String>) -> PairedInternetRelay?) { self.selectGateway = selectGateway }
    func start() async throws -> UInt16 {
        if let localPort { return localPort }
        guard udp == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
        let attempt = UUID(); generation = attempt
        let listener = try NWListener(using: Self.parameters(udp: true, port: .any))
        udp = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.admit(connection, datagram: true, attempt: attempt) ?? connection.cancel() }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { self.stop(); return }
                    do { try self.startTCP(port: port, attempt: attempt) } catch { self.stop() }
                case .failed, .cancelled: self.stop()
                default: break
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.generation == attempt else { return }
                self.stop()
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        generation = UUID(); localPort = nil
        timeout?.cancel(); timeout = nil
        continuation?.resume(throwing: CancellationError()); continuation = nil
        udp?.cancel(); tcp?.cancel(); udp = nil; tcp = nil
        let pending = Array(queries.values); queries.removeAll()
        for query in pending { query.finish(nil) }
        let retiring = Array(clients.values); clients.removeAll()
        for client in retiring { client.close() }
    }
    private static func parameters(udp: Bool, port: NWEndpoint.Port) -> NWParameters {
        let parameters = udp ? NWParameters.udp : NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.includePeerToPeer = false
        return parameters
    }
    private func startTCP(port: NWEndpoint.Port, attempt: UUID) throws {
        guard tcp == nil else { return }
        let listener = try NWListener(using: Self.parameters(udp: false, port: port))
        tcp = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.admit(connection, datagram: false, attempt: attempt) ?? connection.cancel() }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                switch state {
                case .ready:
                    self.localPort = port.rawValue
                    self.timeout?.cancel(); self.timeout = nil
                    self.continuation?.resume(returning: port.rawValue); self.continuation = nil
                case .failed, .cancelled: self.stop()
                default: break
                }
            }
        }
        listener.start(queue: queue)
    }
    private func admit(_ connection: NWConnection, datagram: Bool, attempt: UUID) {
        guard generation == attempt, clients.count < 32 else { connection.cancel(); return }
        let client = Client(connection: connection, datagram: datagram, owner: self)
        clients[client.id] = client; client.start(queue: queue)
    }
    private func resolve(_ wire: Data, completion: @escaping (Data?) -> Void) {
        guard PairedDNSWire.validQuery(wire), queries.count < 32 else { completion(nil); return }
        resolve(wire, excluding: [], deadline: ContinuousClock.now + .seconds(8), completion: completion)
    }
    private func resolve(_ wire: Data, excluding: Set<String>, deadline: ContinuousClock.Instant, completion: @escaping (Data?) -> Void) {
        guard ContinuousClock.now < deadline, queries.count < 32, let gateway = selectGateway(excluding) else { completion(nil); return }
        let attempt = generation
        let query = Query(wire: wire, gateway: gateway, deadline: deadline) { [weak self] id, result in
            guard let self else { completion(nil); return }
            self.queries.removeValue(forKey: id)
            if result == nil, self.generation == attempt, excluding.count < 1 {
                self.resolve(wire, excluding: excluding.union([gateway.peer.deviceID]), deadline: deadline, completion: completion)
            } else { completion(result) }
        }
        queries[query.id] = query; query.start()
    }
    func setHealthyPeers(_ ids: Set<String>) {
        for query in Array(queries.values) where !ids.contains(query.peerID) { query.finish(nil) }
    }
    private static func failure(_ query: Data) -> Data? {
        guard query.count >= 12 else { return nil }
        var bytes = Array(query)
        bytes[2] |= 0x80; bytes[3] = (bytes[3] & 0xf0) | 2
        bytes[6] = 0; bytes[7] = 0; bytes[8] = 0; bytes[9] = 0
        return Data(bytes)
    }
    @MainActor private final class Client {
        let id = UUID()
        private let connection: NWConnection
        private let datagram: Bool
        private weak var owner: PairedDNSRelay?
        private var closed = false
        private var timeout: Task<Void, Never>?
        init(connection: NWConnection, datagram: Bool, owner: PairedDNSRelay) { self.connection = connection; self.datagram = datagram; self.owner = owner }
        func start(queue: DispatchQueue) {
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state { case .ready: self.readNext(); case .failed, .cancelled: self.close(); default: break }
                }
            }
            connection.start(queue: queue); armTimeout()
        }
        func close() {
            guard !closed else { return }; closed = true
            timeout?.cancel(); timeout = nil; connection.cancel(); owner?.clients.removeValue(forKey: id)
        }
        private func armTimeout() {
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8)); guard !Task.isCancelled else { return }; self?.close()
            }
        }
        private func readNext() {
            guard !closed else { return }; armTimeout()
            if datagram {
                connection.receiveMessage { [weak self] bytes, _, _, error in
                    Task { @MainActor in
                        guard let self, error == nil, let bytes else { self?.close(); return }
                        self.query(bytes)
                    }
                }
            } else {
                readExactly(2) { [weak self] header in
                    guard let self, let header else { self?.close(); return }
                    let bytes = Array(header); let count = Int(bytes[0]) << 8 | Int(bytes[1])
                    guard count >= 12 else { self.close(); return }
                    self.readExactly(count) { [weak self] wire in
                        guard let self, let wire else { self?.close(); return }; self.query(wire)
                    }
                }
            }
        }
        private func readExactly(_ count: Int, accumulated: Data = Data(), completion: @escaping @MainActor (Data?) -> Void) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { [weak self] bytes, _, complete, error in
                Task { @MainActor in
                    guard let self, !self.closed, error == nil, let bytes, !bytes.isEmpty else { completion(nil); return }
                    var total = accumulated; total.append(bytes)
                    if total.count == count { completion(total) }
                    else if complete { completion(nil) }
                    else { self.readExactly(count, accumulated: total, completion: completion) }
                }
            }
        }
        private func query(_ wire: Data) {
            guard !closed, let owner else { close(); return }
            owner.resolve(wire) { [weak self] result in
                guard let self, !self.closed else { return }
                guard let response = result ?? PairedDNSRelay.failure(wire) else { self.close(); return }
                var payload = Data()
                if !self.datagram { payload.append(UInt8(response.count >> 8)); payload.append(UInt8(response.count & 255)) }
                payload.append(response)
                self.connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in guard let self else { return }; if error == nil { self.readNext() } else { self.close() } }
                })
            }
        }
    }
    @MainActor private final class Query {
        let id = UUID()
        var peerID: String { gateway.peer.deviceID }
        private let wire: Data
        private let gateway: PairedInternetRelay
        private let deadline: ContinuousClock.Instant
        private let completion: (UUID, Data?) -> Void
        private var client: CompanionTLSClient?
        private var timeout: Task<Void, Never>?
        private var buffer = Data()
        private var done = false
        init(wire: Data, gateway: PairedInternetRelay, deadline: ContinuousClock.Instant, completion: @escaping (UUID, Data?) -> Void) { self.wire = wire; self.gateway = gateway; self.deadline = deadline; self.completion = completion }
        func start() {
            let client = CompanionTLSClient(endpoint: gateway.endpoint, peer: gateway.peer, hostID: gateway.hostID,
                sessionID: gateway.sessionID, channelKind: .internetProxy,
                stateHandler: { [weak self] state in
                    Task { @MainActor in switch state { case .failed, .authenticationRejected, .disconnected: self?.finish(nil); default: break } }
                }, envelopeHandler: { _, _ in }, rawStreamID: gateway.leaseID, rawCodec: "dns-wire-v1",
                rawReadyHandler: { [weak self] in Task { @MainActor in self?.send() } },
                rawDataHandler: { [weak self] bytes, finished in
                    Task { @MainActor in guard let self else { finished(); return }; self.receive(bytes); finished() }
                })
            self.client = client
            timeout = Task { [weak self] in
                guard let self else { return }
                let remaining = ContinuousClock.now.duration(to: self.deadline)
                if remaining > .zero { try? await Task.sleep(for: remaining) }
                guard !Task.isCancelled else { return }; self.finish(nil)
            }
            client.start()
        }
        private func send() {
            guard !done else { return }
            guard let frame = PairedDNSWire.frame(wire) else { finish(nil); return }
            client?.sendRaw(frame) { [weak self] sent in if !sent { Task { @MainActor in self?.finish(nil) } } }
        }
        private func receive(_ bytes: Data) {
            guard !done, buffer.count + bytes.count <= 65_537 else { finish(nil); return }
            buffer.append(bytes)
            switch PairedDNSWire.response(buffer, for: wire) {
            case .incomplete: return
            case .invalid: finish(nil)
            case let .complete(response): finish(response)
            }
        }

        func finish(_ response: Data?) {
            guard !done else { return }; done = true
            timeout?.cancel(); timeout = nil; client?.cancel(); client = nil
            buffer.removeAll(); completion(id, response)
        }
    }
}
#endif
#endif
