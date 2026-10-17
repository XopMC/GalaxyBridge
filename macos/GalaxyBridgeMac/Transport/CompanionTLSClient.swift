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
    let endpoint: NWEndpoint
    var authenticatedSessionID: String { sessionID }
    var resolvedEndpoint: NWEndpoint { connection.currentPath?.remoteEndpoint ?? endpoint }
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
    private let notificationActionCapabilityLock = NSLock()
    private var notificationActionResultsSupported = false
    private var featureConfigurationSupported = false
    private var connectivityCapabilitiesState = CompanionConnectivityCapabilities()
    private let rawStreamID: String?
    private let rawCodec: String?
    private let rawReadyHandler: @Sendable () -> Void
    private let rawDataHandler: (@Sendable (Data, @escaping @Sendable () -> Void) -> Void)?
    private var rawReady = false
    private var rawUpgradeDecoder = RawChannelUpgradeDecoder()

    var supportsInternetGateway: Bool {
        connectivityCapabilities.internetGateway
    }

    var supportsShellBridge: Bool { connectivityCapabilities.supportsShellBridge }
    var supportsCaptureRetirementProof: Bool { connectivityCapabilities.supportsCaptureRetirementProof }
    var supportsShellRuntimeIdentity: Bool { connectivityCapabilities.supportsShellRuntimeIdentity }

    var connectivityCapabilities: CompanionConnectivityCapabilities {
        notificationActionCapabilityLock.lock(); defer { notificationActionCapabilityLock.unlock() }
        return connectivityCapabilitiesState
    }

    var supportsFeatureConfiguration: Bool {
        notificationActionCapabilityLock.lock(); defer { notificationActionCapabilityLock.unlock() }
        return featureConfigurationSupported
    }

    var supportsNotificationActionResults: Bool {
        notificationActionCapabilityLock.lock()
        defer { notificationActionCapabilityLock.unlock() }
        return notificationActionResultsSupported
    }
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
        mediaHandler: @escaping @Sendable (MediaPacket) -> Void = { _ in },
        rawStreamID: String? = nil,
        rawCodec: String? = nil,
        rawReadyHandler: @escaping @Sendable () -> Void = {},
        rawDataHandler: (@Sendable (Data, @escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        self.peer = peer
        self.endpoint = endpoint
        self.rawStreamID = rawStreamID
        self.rawCodec = rawCodec
        self.rawReadyHandler = rawReadyHandler
        self.rawDataHandler = rawDataHandler
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
        let parameters = CompanionTransportParameters.make(tls: tls)
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

    func sendFeatureConfiguration(_ request: GBFeatureConfigurationRequest) throws {
        guard channelKind == .control, supportsFeatureConfiguration else { throw CocoaError(.featureUnsupported) }
        var envelope = baseEnvelope(); envelope.featureConfigurationRequest = request; try send(envelope)
    }

    func sendInternetSharing(_ request: GBInternetSharingRequest) throws {
        guard supportsInternetGateway else { throw CocoaError(.featureUnsupported) }
        var envelope = baseEnvelope(); envelope.internetSharingRequest = request; try send(envelope)
    }

    func sendShellBridge(_ request: GBShellBridgeRequest) throws {
        guard supportsShellBridge else { throw CocoaError(.featureUnsupported) }
        var envelope = baseEnvelope(); envelope.shellBridgeRequest = request; try send(envelope)
    }

    func sendRaw(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard rawReady, data.count <= 256 * 1024 else { completion(false); return }
            connection.send(content: data, completion: .contentProcessed { completion($0 == nil) })
        }
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
        if rawReady { receiveRaw(); return }
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
                } else if channelKind == .internetProxy || channelKind == .enhancedStream {
                    do {
                        try rawUpgradeDecoder.append(data)
                        while !rawReady, let frame = try rawUpgradeDecoder.nextFrame() {
                            let envelope = try GBEnvelope(serializedBytes: frame)
                            guard handleControlEnvelope(envelope, frameCount: frame.count) else { return }
                        }
                        if rawReady {
                            let pending = rawUpgradeDecoder.takeRawRemainder()
                            if !pending.isEmpty, let rawDataHandler {
                                rawDataHandler(pending) { [weak self] in
                                    guard let self else { return }
                                    self.queue.async { [weak self] in self?.receiveRaw() }
                                }
                                return
                            }
                        }
                    } catch {
                        diagnostics.controlDecodeFailed(error)
                        stateHandler(.failed(error.localizedDescription)); connection.cancel(); return
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
                            guard handleControlEnvelope(envelope, frameCount: frame.count) else { return }
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

    private func handleControlEnvelope(_ envelope: GBEnvelope, frameCount: Int) -> Bool {
        if !receivedHello,
           case let .error(error)? = envelope.payload,
           let message = CompanionAuthenticationRejection.message(for: error.code) {
            deliveredTerminalAuthenticationFailure = true
            stateHandler(.authenticationRejected(message))
            connection.cancel()
            return false
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
        if case let .capabilityUpdate(update)? = envelope.payload, channelKind == .control {
            notificationActionCapabilityLock.lock()
            notificationActionResultsSupported = update.available.contains(.notificationActionResults)
            featureConfigurationSupported = update.available.contains(.featureConfiguration)
            connectivityCapabilitiesState = CompanionConnectivityCapabilities(negotiated: true,
                nearbyLink: update.available.contains(.nearbyLink), internetGateway: update.available.contains(.internetGateway),
                privilegedBridge: update.available.contains(.privilegedBridge),
                captureRetirementProof: update.available.contains(.captureRetirementProof),
                shellRuntimeIdentity: update.available.contains(.shellRuntimeIdentity), unavailableReasons: update.unavailableReasons)
            notificationActionCapabilityLock.unlock()
    }
        if case let .internetSharingStatus(status)? = envelope.payload,
           channelKind == .internetProxy, status.enabled,
           status.leaseID == rawStreamID, rawDataHandler != nil {
            rawReady = true
            rawReadyHandler()
    }
        if case let .shellBridgeResult(result)? = envelope.payload,
           channelKind == .enhancedStream, result.available, result.state == "stream_ready",
           let rawStreamID, result.streamIds.contains(rawStreamID), rawDataHandler != nil {
            rawReady = true
            rawReadyHandler()
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
                return false
            }
    }
        envelopeHandler(envelope, frameCount)
        return true
    }

    private func openChannel() throws {
        var request = GBOpenChannel()
        request.kind = channelKind
        request.streamID = rawStreamID ?? UUID().uuidString.lowercased()
        if let rawCodec { request.codec = rawCodec }
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

    private func receiveRaw() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            let next: @Sendable () -> Void = { [weak self] in
                guard let self else { return }
                self.queue.async {
                    if let error { self.stateHandler(.failed(error.localizedDescription)); self.connection.cancel() }
                    else if complete { self.stateHandler(.disconnected); self.connection.cancel() }
                    else { self.receiveRaw() }
                }
            }
            if let data, !data.isEmpty, let rawDataHandler { rawDataHandler(data, next) }
            else { next() }
        }
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
    case .internetProxy, .enhancedStream, .unspecified, .UNRECOGNIZED: .unknown
    }
}
