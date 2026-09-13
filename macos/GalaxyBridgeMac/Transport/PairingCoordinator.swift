import AppKit
import CryptoKit
import Darwin
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeProtocol
import Network

@MainActor
final class PairingCoordinator: ObservableObject {
    enum Status: Equatable {
        case idle
        case listening
        case paired(String)
        case failed(String)
    }

    @Published private(set) var pairingURL: URL?
    @Published private(set) var qrCodeImage: NSImage?
    @Published private(set) var status: Status = .idle

    private let identityStore = KeychainIdentityStore()
    private let peerStore = PairedPeerStore()
    private var listener: NWListener?
    // NWConnection only retains its handlers; the handlers deliberately capture the
    // exchange weakly. Keep the exchange alive until it produces a response.
    private var activeExchange: PairingExchange?
    private var token = Data()
    private var expiresAt = Date.distantPast
    private var hostID = UUID()
    private var pendingCommit: PendingPairingCommit?

    func start() {
        stop()
        do {
            token = try Self.randomBytes(count: PairingQRCode.tokenLength)
            expiresAt = Date().addingTimeInterval(PairingQRCode.maximumLifetime)
            hostID = Self.persistentHostID()
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard case .ready = state, let port = listener?.port else {
                    if case let .failed(error) = state {
                        Task { @MainActor in self?.fail(error.localizedDescription) }
                    }
                    return
                }
                Task { @MainActor in self?.becameReady(port: port.rawValue) }
            }
            listener.start(queue: DispatchQueue(label: "com.xopmc.GalaxyBridge.pairing-listener"))
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        activeExchange?.cancel()
        activeExchange = nil
        pendingCommit = nil
        listener?.cancel()
        listener = nil
        pairingURL = nil
        qrCodeImage = nil
        if case .paired = status { return }
        status = .idle
    }

    private func becameReady(port: UInt16) {
        do {
            let payload = PairingPayload(
                version: 1,
                hostID: hostID,
                addresses: Self.localAddresses(),
                port: port,
                token: token,
                publicKeyFingerprint: try identityStore.fingerprint(),
                expiresAt: expiresAt
            )
            let url = try PairingQRCode.encode(payload)
            pairingURL = url
            qrCodeImage = QRCodeRenderer.image(for: url.absoluteString)
            status = .listening
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Date() < expiresAt else {
            fail("Pairing token expired")
            return
        }
        do {
            let key = try identityStore.privateKey()
            let clientNonce = try Self.randomBytes(count: 32)
            let displayName = Host.current().localizedName ?? "Mac"
            var request = GBPairingRequest()
            request.oneTimeToken = token
            request.identityPublicKey = key.publicKey.x963Representation
            request.displayName = displayName
            request.clientNonce = clientNonce
            request.transcriptSignature = try key.signature(
                for: PairingTranscript.makeRequest(
                    token: token,
                    clientNonce: clientNonce,
                    macPublicKey: key.publicKey.x963Representation,
                    displayName: Data(displayName.utf8)
                )
            ).derRepresentation
            var envelope = GBEnvelope()
            envelope.protocolMajor = 1
            envelope.protocolMinor = 0
            envelope.deviceID = hostID.uuidString.lowercased()
            envelope.sessionID = UUID().uuidString.lowercased()
            envelope.messageID = 1
            envelope.pairingRequest = request
            let requestEnvelope = envelope
            let frame = try ControlFrameCodec.encode(try envelope.serializedData())
            let exchange = PairingExchange(
                connection: connection,
                requestFrame: frame,
                expiresAt: expiresAt,
                responseHandler: { [weak self] responseEnvelope in
                    guard let self else { throw PairingExchangeError.disconnected }
                    return try await MainActor.run {
                        try self.prepareCommit(
                            responseEnvelope,
                            requestEnvelope: requestEnvelope,
                            clientNonce: clientNonce,
                            macPrivateKey: key
                        )
                    }
                },
                completion: { [weak self] result in
                    Task { @MainActor in
                        self?.activeExchange = nil
                        self?.complete(result)
                    }
                }
            )
            activeExchange?.cancel()
            activeExchange = exchange
            exchange.start()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func prepareCommit(
        _ envelope: GBEnvelope,
        requestEnvelope: GBEnvelope,
        clientNonce: Data,
        macPrivateKey: P256.Signing.PrivateKey
    ) throws -> Data {
        guard Date() < expiresAt,
              envelope.protocolMajor == 1,
              envelope.sessionID == requestEnvelope.sessionID,
              case let .pairingResponse(response)? = envelope.payload,
              response.accepted,
              !response.deviceID.isEmpty,
              response.deviceID == envelope.deviceID,
              response.identityPublicKey.count == 65,
              response.serverNonce.count == 32,
              response.tlsCertificateSha256.count == 32
        else {
            if case let .pairingResponse(response)? = envelope.payload, !response.accepted {
                throw PairingExchangeError.rejected(response.rejectionReason)
            }
            throw PairingExchangeError.invalidPayload
        }
        let macPublicKey = macPrivateKey.publicKey.x963Representation
        let responseTranscript = PairingTranscript.make(
            token: token,
            clientNonce: clientNonce,
            serverNonce: response.serverNonce,
            macPublicKey: macPublicKey,
            androidPublicKey: response.identityPublicKey
        )
        guard try PairingTranscript.verify(
            signatureDER: response.transcriptSignature,
            transcript: responseTranscript,
            publicKeyX963: response.identityPublicKey
        ) else {
            throw PairingExchangeError.invalidSignature
        }
        let displayName = response.displayName.isEmpty ? "Samsung Galaxy" : response.displayName
        let peer = PairedPeer(
            deviceID: response.deviceID,
            displayName: displayName,
            identityPublicKey: response.identityPublicKey,
            tlsCertificateSHA256: response.tlsCertificateSha256,
            pairedAt: Date()
        )

        let commitTranscript = PairingTranscript.makeCommit(
            token: token,
            clientNonce: clientNonce,
            serverNonce: response.serverNonce,
            macPublicKey: macPublicKey,
            androidPublicKey: response.identityPublicKey,
            hostID: requestEnvelope.deviceID,
            deviceID: response.deviceID,
            sessionID: requestEnvelope.sessionID
        )
        let commitSignature = try macPrivateKey.signature(for: commitTranscript).derRepresentation
        var commit = GBPairingCommit()
        commit.hostID = requestEnvelope.deviceID
        commit.deviceID = response.deviceID
        commit.sessionID = requestEnvelope.sessionID
        commit.transcriptSignature = commitSignature
        var commitEnvelope = GBEnvelope()
        commitEnvelope.protocolMajor = 1
        commitEnvelope.protocolMinor = 0
        commitEnvelope.deviceID = requestEnvelope.deviceID
        commitEnvelope.sessionID = requestEnvelope.sessionID
        commitEnvelope.messageID = envelope.messageID + 1
        commitEnvelope.pairingCommit = commit
        let commitFrame = try ControlFrameCodec.encode(try commitEnvelope.serializedData())

        let pending = PendingPairingCommit(
            peer: peer,
            sessionID: requestEnvelope.sessionID,
            hostID: requestEnvelope.deviceID,
            commitTranscript: commitTranscript,
            commitSignature: commitSignature
        )
        // Persisting a non-authorizing candidate is the first half of the commit.
        // `PairedPeerStore.peers()` cannot expose it until a valid signed Ack promotes it.
        try peerStore.stage(
            StagedPairingTrust(
                peer: peer,
                hostID: pending.hostID,
                sessionID: pending.sessionID,
                commitTranscript: pending.commitTranscript,
                commitSignature: pending.commitSignature,
                expiresAt: expiresAt
            )
        )
        pendingCommit = pending
        return commitFrame
    }

    private func complete(_ result: Result<GBEnvelope, Error>) {
        do {
            let envelope = try result.get()
            guard let pendingCommit,
                  envelope.protocolMajor == 1,
                  envelope.sessionID == pendingCommit.sessionID,
                  envelope.deviceID == pendingCommit.peer.deviceID,
                  case let .pairingCommitAck(acknowledgement)? = envelope.payload,
                  acknowledgement.committed,
                  acknowledgement.hostID == pendingCommit.hostID,
                  acknowledgement.deviceID == pendingCommit.peer.deviceID,
                  acknowledgement.sessionID == pendingCommit.sessionID
            else { throw PairingExchangeError.invalidAcknowledgement }
            let acknowledgementTranscript = PairingTranscript.makeCommitAcknowledgement(
                commitTranscript: pendingCommit.commitTranscript,
                commitSignature: pendingCommit.commitSignature
            )
            guard try PairingTranscript.verify(
                signatureDER: acknowledgement.transcriptSignature,
                transcript: acknowledgementTranscript,
                publicKeyX963: pendingCommit.peer.identityPublicKey
            ) else { throw PairingExchangeError.invalidSignature }

            let promotedPeer = try peerStore.promote(
                deviceID: pendingCommit.peer.deviceID,
                sessionID: pendingCommit.sessionID
            )
            CompanionLifecycleEvents.pairingStored(promotedPeer)
            listener?.cancel()
            listener = nil
            self.pendingCommit = nil
            status = .paired(promotedPeer.displayName)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        activeExchange?.cancel()
        activeExchange = nil
        listener?.cancel()
        listener = nil
        pendingCommit = nil
        status = .failed(message)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw IdentityStoreError.keychain(status) }
        return bytes
    }

    private static func persistentHostID() -> UUID {
        let key = "com.xopmc.GalaxyBridge.host-id"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString.lowercased(), forKey: key)
        return id
    }

    private static func localAddresses() -> [String] {
        var candidates: [PairingAddressCandidate] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&interfaces) == 0 {
            var current = interfaces
            while let interface = current?.pointee {
                defer { current = interface.ifa_next }
                guard let socketAddress = interface.ifa_addr,
                      socketAddress.pointee.sa_family == UInt8(AF_INET) ||
                        socketAddress.pointee.sa_family == UInt8(AF_INET6),
                      (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                      (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0
                else { continue }
                let interfaceName = String(cString: interface.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length: socklen_t = socketAddress.pointee.sa_family == UInt8(AF_INET)
                    ? socklen_t(MemoryLayout<sockaddr_in>.size)
                    : socklen_t(MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(socketAddress, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    candidates.append(PairingAddressCandidate(interfaceName: interfaceName, address: address))
                }
            }
            freeifaddrs(interfaces)
        }
        var localHostname: String?
        var hostname = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN))
        if gethostname(&hostname, hostname.count) == 0 {
            let name = String(decoding: hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            localHostname = name.hasSuffix(".local") ? name : "\(name).local"
        }
        return PairingAddressSelector.select(candidates: candidates, hostname: localHostname)
    }
}

private struct PendingPairingCommit {
    let peer: PairedPeer
    let sessionID: String
    let hostID: String
    let commitTranscript: Data
    let commitSignature: Data
}

private enum PairingExchangeError: Error, LocalizedError {
    case disconnected
    case invalidPayload
    case rejected(String)
    case invalidSignature
    case invalidAcknowledgement
    case expired

    var errorDescription: String? {
        switch self {
        case .disconnected: String(localized: "ERROR_PAIRING_DISCONNECTED")
        case .invalidPayload, .invalidAcknowledgement: String(localized: "ERROR_PAIRING_RESPONSE")
        case .rejected: String(localized: "ERROR_PAIRING_REJECTED")
        case .invalidSignature: String(localized: "ERROR_PAIRING_IDENTITY")
        case .expired: String(localized: "ERROR_PAIRING_EXPIRED")
        }
    }
}

private final class PairingExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let expiresAt: Date
    private let responseHandler: @Sendable (GBEnvelope) async throws -> Data
    private let completion: @Sendable (Result<GBEnvelope, Error>) -> Void
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.pairing-exchange")
    private var decoder = ControlFrameDecoder(maxPayloadLength: 8 * 1024 * 1024)
    private var retryState: PairingExchangeRetryState
    private var responseIsBeingPrepared = false
    private var pendingAcknowledgement: GBEnvelope?
    private var isFinished = false
    private var retryWorkItem: DispatchWorkItem?

    init(
        connection: NWConnection,
        requestFrame: Data,
        expiresAt: Date,
        responseHandler: @escaping @Sendable (GBEnvelope) async throws -> Data,
        completion: @escaping @Sendable (Result<GBEnvelope, Error>) -> Void
    ) {
        self.connection = connection
        self.expiresAt = expiresAt
        self.responseHandler = responseHandler
        self.completion = completion
        retryState = PairingExchangeRetryState(requestFrame: requestFrame, expiresAt: expiresAt)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
                self.sendCurrentFrame()
                self.scheduleRetry()
            case let .failed(error): self.finish(.failure(error))
            case .cancelled: break
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self, !isFinished else { return }
            isFinished = true
            retryWorkItem?.cancel()
            connection.cancel()
        }
    }

    private func sendCurrentFrame() {
        guard !isFinished else { return }
        guard let frame = retryState.outboundFrame(now: Date()) else {
            if Date() >= expiresAt { finish(.failure(PairingExchangeError.expired)) }
            return
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failure(error)) }
        })
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !isFinished else { return }
            sendCurrentFrame()
            scheduleRetry()
        }
        retryWorkItem = item
        queue.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            do {
                if let data {
                    for frame in try decoder.append(data) {
                        let envelope = try GBEnvelope(serializedBytes: frame)
                        switch envelope.payload {
                        case .pairingResponse?:
                            acceptResponse(envelope)
                        case .pairingCommitAck?:
                            pendingAcknowledgement = envelope
                            retryState.acknowledged()
                            if retryState.isFailed {
                                finish(.failure(PairingExchangeError.expired))
                                return
                            }
                            guard retryState.isComplete else { continue }
                            finish(.success(pendingAcknowledgement ?? envelope))
                            return
                        default:
                            continue
                        }
                    }
                }
                if let error { throw error }
                if complete { throw PairingExchangeError.disconnected }
                receive()
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func acceptResponse(_ envelope: GBEnvelope) {
        guard !responseIsBeingPrepared,
              retryState.outboundFrame(now: Date()) != nil
        else { return }
        responseIsBeingPrepared = true
        retryState.responseAccepted()
        Task { [weak self] in
            guard let self else { return }
            do {
                let commitFrame = try await responseHandler(envelope)
                queue.async { [weak self] in
                    guard let self, !isFinished else { return }
                    retryState.peerSaved(commitFrame: commitFrame)
                    responseIsBeingPrepared = false
                    if retryState.isComplete, let pendingAcknowledgement {
                        finish(.success(pendingAcknowledgement))
                        return
                    }
                    sendCurrentFrame()
                }
            } catch {
                queue.async { [weak self] in
                    self?.retryState.peerSaveFailed()
                    self?.finish(.failure(error))
                }
            }
        }
    }

    private func finish(_ result: Result<GBEnvelope, Error>) {
        guard !isFinished else { return }
        isFinished = true
        retryWorkItem?.cancel()
        connection.cancel()
        completion(result)
    }
}

private enum QRCodeRenderer {
    static func image(for string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
