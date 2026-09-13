import Foundation
import GalaxyBridgeCore
import GalaxyBridgeProtocol
import Network
import Security

enum CompanionConnectionState: Equatable, Sendable {
    case connecting
    case connected
    case failed(String)
    case authenticationRejected(String)
    case disconnected
}

enum CompanionAuthenticationRejection {
    static let pairingRequiredCode = "pairing_required"
    static let authenticationFailedCode = "session_authentication_failed"

    static func message(for code: String) -> String? {
        switch code {
        case pairingRequiredCode:
            String(localized: "COMPANION_PAIRING_REQUIRED")
        case authenticationFailedCode:
            String(localized: "COMPANION_AUTHENTICATION_FAILED")
        default:
            nil
        }
    }
}

final class CompanionTLSClient: @unchecked Sendable {
    let peer: PairedPeer
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.companion-tls")
    private let stateHandler: @Sendable (CompanionConnectionState) -> Void
    private let envelopeHandler: @Sendable (GBEnvelope, Int) -> Void
    private let mediaHandler: @Sendable (MediaPacket) -> Void
    private let channelKind: GBChannelKind
    private let diagnostics: CompanionConnectionDiagnostics
    private var decoder = ControlFrameDecoder(maxPayloadLength: 8 * 1024 * 1024)
    private var mediaDecoder = MediaPacketDecoder(maxPayloadLength: 16 * 1024 * 1024)
    private var channelOpened = false
    private var receivedHello = false
    private var deliveredTerminalAuthenticationFailure = false
    private var messageID: UInt64 = 1
    private let messageIDLock = NSLock()
    private var heartbeat = CompanionControlHeartbeat()
    private var heartbeatPollSchedule = CompanionHeartbeatPollSchedule()
    private var heartbeatTimer: DispatchSourceTimer?
    private let sessionID: String
    private let hostID: String
    private let identityStore = KeychainIdentityStore()

    init(
        endpoint: NWEndpoint,
        peer: PairedPeer,
        hostID: String,
        sessionID: String = UUID().uuidString.lowercased(),
        channelKind: GBChannelKind = .control,
        bundleGeneration: UInt64 = 0,
        diagnosticSink: @escaping CompanionConnectionDiagnostics.Sink = { _ in },
        stateHandler: @escaping @Sendable (CompanionConnectionState) -> Void,
        envelopeHandler: @escaping @Sendable (GBEnvelope, Int) -> Void,
        mediaHandler: @escaping @Sendable (MediaPacket) -> Void = { _ in }
    ) {
        self.peer = peer
        self.hostID = hostID
        self.sessionID = sessionID
        self.stateHandler = stateHandler
        self.envelopeHandler = envelopeHandler
        self.mediaHandler = mediaHandler
        self.channelKind = channelKind
        diagnostics = CompanionConnectionDiagnostics(
            bundleGeneration: bundleGeneration,
            channel: companionDiagnosticChannel(channelKind),
            sink: diagnosticSink
        )

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let expectedPin = peer.tlsCertificateSHA256
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, trustReference, complete in
                let trust = sec_trust_copy_ref(trustReference).takeRetainedValue()
                guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                    complete(false)
                    return
                }
                let certificateData = SecCertificateCopyData(certificate) as Data
                complete(
                    TLSCertificatePinVerifier.matches(
                        certificateDER: certificateData,
                        expectedSHA256: expectedPin
                    )
                )
            },
            queue
        )
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        connection = NWConnection(to: endpoint, using: parameters)
    }

    func start() {
        diagnostics.connectionStarted()
        stateHandler(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                diagnostics.networkReady()
                do {
                    try sendAuthentication()
                    diagnostics.authenticationPrepared()
                    receive()
                } catch {
                    diagnostics.authenticationPreparationFailed(error)
                    stateHandler(.failed(error.localizedDescription))
                    connection.cancel()
                }
            case let .waiting(error):
                diagnostics.pathWaiting(error)
                stateHandler(.failed(CompanionNetworkFailure.message(
                    unsatisfiedReason: connection.currentPath?.unsatisfiedReason
                )))
                connection.cancel()
            case let .failed(error):
                diagnostics.networkFailed(error)
                stateHandler(.failed(error.localizedDescription))
            case .cancelled:
                heartbeatTimer?.cancel()
                heartbeatTimer = nil
                if !deliveredTerminalAuthenticationFailure {
                    stateHandler(.disconnected)
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        diagnostics.localCancellation()
        connection.cancel()
    }

    func recordConnectingWatchdogTimeout() {
        diagnostics.connectingWatchdogTimedOut()
    }

    deinit { heartbeatTimer?.cancel() }

    func send(_ envelope: GBEnvelope) throws {
        let frame = try ControlFrameCodec.encode(try envelope.serializedData())
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.diagnostics.sendFailed(error)
                self?.stateHandler(.failed(error.localizedDescription))
            }
        })
    }

    func sendInput(_ input: GBInputEvent) throws {
        var envelope = baseEnvelope()
        envelope.inputEvent = input
        try send(envelope)
    }

    func sendNotificationAction(_ action: GBNotificationAction) throws {
        var envelope = baseEnvelope()
        envelope.notificationAction = action
        try send(envelope)
    }

    func sendClipboard(_ update: GBClipboardUpdate) throws {
        var envelope = baseEnvelope()
        envelope.clipboardUpdate = update
        try send(envelope)
    }

    func sendTransferManifest(_ manifest: GBTransferManifest) throws {
        var envelope = baseEnvelope()
        envelope.transferManifest = manifest
        try send(envelope)
    }

    func sendTransferChunk(_ chunk: GBTransferChunk) throws {
        var envelope = baseEnvelope()
        envelope.transferChunk = chunk
        try send(envelope)
    }

    func sendTransferAck(_ ack: GBTransferAck) throws {
        var envelope = baseEnvelope()
        envelope.transferAck = ack
        try send(envelope)
    }

    func sendTransferCancel(_ transferID: String) throws {
        var request = GBTransferCancel()
        request.transferID = transferID
        var envelope = baseEnvelope()
        envelope.transferCancel = request
        try send(envelope)
    }

    func sendCameraConfiguration(_ configuration: GBCameraConfiguration) throws {
        var envelope = baseEnvelope()
        envelope.cameraConfiguration = configuration
        try send(envelope)
    }

    func sendSMS(_ sms: GBSmsEvent) throws {
        var envelope = baseEnvelope()
        envelope.smsEvent = sms
        try send(envelope)
    }

    func sendCall(_ call: GBCallEvent) throws {
        var envelope = baseEnvelope()
        envelope.callEvent = call
        try send(envelope)
    }

    private func sendAuthentication() throws {
        let key = try identityStore.privateKey()
        let nonce = try randomBytes(count: 32)
        let timestamp = Int64(Date().timeIntervalSince1970)
        let publicKey = key.publicKey.x963Representation
        var authentication = GBSessionAuthentication()
        authentication.identityPublicKey = publicKey
        authentication.nonce = nonce
        authentication.timestampUnixSeconds = timestamp
        authentication.signature = try key.signature(
            for: SessionAuthenticationTranscript.make(
                deviceID: hostID,
                sessionID: sessionID,
                nonce: nonce,
                timestampUnixSeconds: timestamp,
                identityPublicKey: publicKey
            )
        ).derRepresentation
        var envelope = GBEnvelope()
        envelope.protocolMajor = 1
        envelope.protocolMinor = 0
        envelope.deviceID = hostID
        envelope.sessionID = sessionID
        envelope.messageID = nextMessageID()
        envelope.sessionAuthentication = authentication
        try send(envelope)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                if channelOpened && (channelKind == .video || channelKind == .audio || channelKind == .camera) {
                    do {
                        for packet in try mediaDecoder.append(data) { mediaHandler(packet) }
                    } catch {
                        diagnostics.receiveFailed(error)
                        stateHandler(.failed(error.localizedDescription))
                        connection.cancel()
                        return
                    }
                } else {
                    let frames: [Data]
                    do {
                        frames = try decoder.append(data)
                    } catch {
                        diagnostics.controlDecodeFailed(error)
                        stateHandler(.failed(error.localizedDescription))
                        connection.cancel()
                        return
                    }
                    for frame in frames {
                        do {
                            let envelope = try GBEnvelope(serializedBytes: frame)
                            if !receivedHello,
                               case let .error(error)? = envelope.payload,
                               let message = CompanionAuthenticationRejection.message(for: error.code) {
                                deliveredTerminalAuthenticationFailure = true
                                stateHandler(.authenticationRejected(message))
                                connection.cancel()
                                return
                            }
                            if case .hello? = envelope.payload {
                                receivedHello = true
                                diagnostics.helloReceived()
                                stateHandler(.connected)
                                if channelKind == .control { startHeartbeat() }
                            }
                            if case let .pong(pong)? = envelope.payload {
                                let now = ProcessInfo.processInfo.systemUptime
                                if let roundTripMilliseconds = heartbeat.receivePong(
                                    pong.echoedMonotonicTimeNs,
                                    now: now
                                ) {
                                    diagnostics.recordMatchedPong(
                                        roundTripMilliseconds: roundTripMilliseconds
                                    )
                                }
                            }
                            // The phone sends Hello THEN Capabilities. They may
                            // arrive in separate TCP reads. Do not parse the
                            // remaining control frame as a media header.
                            if case .capabilityUpdate? = envelope.payload,
                               receivedHello, channelKind != .control, !channelOpened {
                                do {
                                    try openChannel()
                                } catch {
                                    diagnostics.sendFailed(error)
                                    stateHandler(.failed(error.localizedDescription))
                                    connection.cancel()
                                    return
                                }
                            }
                            envelopeHandler(envelope, frame.count)
                        } catch {
                            diagnostics.controlDecodeFailed(error)
                            stateHandler(.failed(error.localizedDescription))
                            connection.cancel()
                            return
                        }
                    }
                }
            }
            if let error {
                diagnostics.receiveFailed(error)
                stateHandler(.failed(error.localizedDescription))
                connection.cancel()
                return
            }
            if complete {
                diagnostics.peerEOF()
                if deliveredTerminalAuthenticationFailure { return }
                stateHandler(
                    receivedHello
                        ? .disconnected
                        : .failed("Phone rejected session authentication")
                )
                return
            }
            receive()
        }
    }

    private func openChannel() throws {
        var request = GBOpenChannel()
        request.kind = channelKind
        request.streamID = UUID().uuidString.lowercased()
        if channelKind == .video || channelKind == .camera { request.codec = "h264" }
        if channelKind == .audio { request.codec = "aac" }
        var envelope = GBEnvelope()
        envelope.protocolMajor = 1
        envelope.protocolMinor = 0
        envelope.deviceID = hostID
        envelope.sessionID = sessionID
        envelope.messageID = nextMessageID()
        envelope.openChannel = request
        try send(envelope)
        diagnostics.openChannelRequested()
        channelOpened = true
    }

    private func nextMessageID() -> UInt64 {
        messageIDLock.lock()
        defer { messageIDLock.unlock() }
        defer { messageID &+= 1 }
        return messageID
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        heartbeatPollSchedule = CompanionHeartbeatPollSchedule(
            firstExpectedPollAt: ProcessInfo.processInfo.systemUptime
        )
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let observation = heartbeatPollSchedule.poll(&heartbeat, now: now)
            diagnostics.recordHeartbeatPoll(
                schedulingLatenessMilliseconds: observation.schedulingLatenessMilliseconds
            )
            switch observation.action {
            case .idle: break
            case .timedOut:
                heartbeatTimer?.cancel()
                diagnostics.heartbeatTimedOut()
                stateHandler(.failed("Companion heartbeat timed out"))
                connection.cancel()
            case let .ping(token):
                var envelope = baseEnvelope()
                envelope.ping.monotonicTimeNs = token
                do { try send(envelope) }
                catch {
                    heartbeatTimer?.cancel()
                    diagnostics.sendFailed(error)
                    stateHandler(.failed(error.localizedDescription))
                    connection.cancel()
                }
            }
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func baseEnvelope() -> GBEnvelope {
        var envelope = GBEnvelope()
        envelope.protocolMajor = 1
        envelope.protocolMinor = 0
        envelope.deviceID = hostID
        envelope.sessionID = sessionID
        envelope.messageID = nextMessageID()
        return envelope
    }

    private func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw IdentityStoreError.keychain(status) }
        return data
    }
}

func companionDiagnosticChannel(_ channel: GBChannelKind) -> CompanionDiagnosticChannel {
    switch channel {
    case .control: .control
    case .events: .events
    case .video: .video
    case .audio: .audio
    case .files: .files
    case .camera: .camera
    case .unspecified, .UNRECOGNIZED: .unknown
    }
}
