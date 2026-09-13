#if !GALAXYBRIDGE_APP_STORE
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import Network
import OSLog
import Security

enum ScrcpyPhysicalDisplayPolicy: Equatable, Sendable {
    case primaryMirror
    case leaveUnchanged
}
private final class ScrcpyMediaHealthDelivery: @unchecked Sendable {
    private let lock=NSLock()
    private var latest:[UInt32:QuicMediaHealth]=[:]
    private var scheduled=false
    func submit(_ value:QuicMediaHealth, deliver:@escaping @MainActor @Sendable (QuicMediaHealth)->Void) {
        let start=lock.withLock { latest[value.track]=value; if scheduled {return false};scheduled=true;return true }
        guard start else {return}
        Task { @MainActor [self] in
            let values=lock.withLock { let values=latest.values.sorted {$0.track<$1.track};latest.removeAll();scheduled=false;return values }
            values.forEach(deliver)
        }
    }
}

private final class WirelessADBVideoIngressRecovery: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = WirelessADBVideoRecoveryGate()

    func shouldAdmit(_ event: ScrcpyStreamEvent) -> Bool {
        lock.withLock { gate.shouldAdmit(event) }
    }

    func notePressure(on event: ScrcpyStreamEvent) -> Bool {
        lock.withLock { gate.notePressure(on: event) }
    }

    func noteAdmitted(_ event: ScrcpyStreamEvent) {
        lock.withLock { gate.noteAdmitted(event) }
    }
}

typealias ScrcpyApplicationDisplayEventDelivery = @Sendable (
    @escaping @MainActor @Sendable () -> Void
) -> Void

@MainActor
final class ScrcpySession: ObservableObject {
    @Published private(set) var state: ScrcpySessionState = .idle
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var displayEpoch: UInt32 = 0
    @Published private(set) var screenInterlockPresentation: ScreenInterlockPresentation = .waitingForFirstFrame
    @Published private(set) var mediaHealth: [UInt32:QuicMediaHealth] = [:]
    private var lastMediaFrame: NativeMediaSourceIdentity?
    private var screenPresentationBase: ScreenInterlockPresentation = .waitingForFirstFrame
    @Published private(set) var applicationDisplayIdentity: ScrcpyApplicationDisplayIdentity?

    let serial: String
    private let adb: ADBClient
    private let physicalDisplayPolicy: ScrcpyPhysicalDisplayPolicy
    private let automaticDisplayManagement: Bool
    private let primaryDiagnosticsEnabled: Bool
    private let clipboardPollingEnabled: Bool
    private let wirelessADBVideoRecovery: WirelessADBVideoIngressRecovery?
    private let quicSelection: QuicWirelessSelection?
    private let quicPreparedLaunch: (@Sendable (ScrcpyLaunchConfiguration, UInt64) async throws -> QuicBackendBridge.Launch)?
    private var quicTransport: QuicScrcpySessionTransport?
    private var retiredQuicTransport: QuicScrcpySessionTransport?
    private(set) var quicRetirementOutcome: ScrcpyTransportSettlement?
    private(set) var primaryDiagnostics: PrimaryMediaDiagnostics?
    private var primaryDiagnosticsStartedAt: Double?
    private let applicationDisplayEventDelivery: ScrcpyApplicationDisplayEventDelivery
    private let nativePreparationBoundary: (@MainActor @Sendable (ScrcpyNativeMediaOwner, ScrcpyCodec) async throws -> Bool)?
    private var configuration: ScrcpyLaunchConfiguration?
    private var serverProcess: Process?
    private var serverSCID: UInt32?
    private var serverOutputObserver: ScrcpyOwnedProcessOutputObserver?
    private var applicationDisplayLaunchGeneration: ScrcpyApplicationDisplayLaunchGeneration?
    private var applicationDisplayIdentityConflicted = false
    private var forwardedPort: UInt16?
    private var reverseTunnel: ScrcpyReverseTunnel?
    private var videoSocket: ScrcpyStreamSocket?
    private var audioSocket: ScrcpyStreamSocket?
    private var controlSocket: ScrcpyControlSocket?
    private var preparationTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var keyboardSettlementTask: Task<Void, Never>?
    private var clipboardPollingTask: Task<Void, Never>?
    private var clipboardRequestTask: Task<Void, Never>?
    private var physicalDisplayMonitoringTask: Task<Void, Never>?
    private var displayBlackoutTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var originalDisplayBrightness: Double?
    private var hasRemoteKeyboardPreferenceLease = false
    private var screenInterlock = InteractiveDisplayBlackoutStateMachine()
    private var screenInterlockPublication = ScreenInterlockPresentationPublicationState(
        initial: .waitingForFirstFrame
    )
    private var hasDeliveredFirstFrameEvent = false
    private var deviceName = "Samsung Galaxy"
    private var captureTarget: ScrcpyCaptureTarget = .display(id: 0)
    private var applicationTarget: ScrcpyApplicationTarget?
    private let clipboardSessionID = UUID().uuidString.lowercased()
    private var clipboardReceiveSequence: UInt64 = 1
    private var keyboardInputQueue = ScrcpyKeyboardInputQueue()
    private var injectedClipboardEchoes = ScrcpyInjectedClipboardEchoSuppressor()
    private var injectedClipboardEchoesBySequence: [UInt64: Data] = [:]
    private var lastObservedClipboardContent: Data?
    private var forceNextClipboardForward = false
    private let keyboardEmissionSink: ((ScrcpyKeyboardEmission) -> Void)?
    private let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "scrcpy")

    var videoEventHandler: (@Sendable (ScrcpyStreamEvent) -> Void)?
    var audioEventHandler: (@Sendable (ScrcpyStreamEvent) -> Void)?
    var recordingAudioEventHandler: (@MainActor @Sendable (ScrcpyStreamEvent, UInt32?, UUID) -> Void)?
    var decodedFrameHandler: (@Sendable (CVPixelBuffer, CMTime, UInt32) -> Void)? { didSet { refreshNativeBinding() } }
    var diagnosticDecodedFrameHandler: (@Sendable (CVPixelBuffer, CMTime, UInt32, PrimaryMediaTrace?) -> Void)? { didSet { refreshNativeBinding() } }
    var ownedDecodedFrameHandler: (@MainActor @Sendable (NativeDecodedFrame) -> Void)? { didSet { refreshNativeBinding() } }
    var controlReadyHandler: (@MainActor @Sendable () -> Void)?
    var clipboardEventHandler: (@Sendable (ScrcpyClipboardUpdate) -> Void)?
#if !GALAXYBRIDGE_APP_STORE && GB_QUIC_BACKEND_QA
    var quicStockObservation: (@Sendable ([UInt64]) -> Void)?
    var quicDeviceObservation: (@MainActor @Sendable (ScrcpyDeviceMessage) -> Void)?
#endif
    private var audioPlaybackEnabled = true
    func setPlaybackEnabled(_ enabled: Bool) {
        audioPlaybackEnabled = enabled
        nativeOwner?.audio.setPlaybackEnabled(enabled)
    }

    private var audioPlaybackEvidenceRequest: (id: UUID, completion: @MainActor @Sendable (UUID) -> Void)?

    func requestPlaybackEvidence(id: UUID, completion: @escaping @MainActor @Sendable (UUID) -> Void) {
        audioPlaybackEvidenceRequest = (id, completion)
        if let owner = nativeOwner { armPlaybackEvidence(owner) }
    }

    func cancelPlaybackEvidence() {
        audioPlaybackEvidenceRequest = nil
        nativeOwner?.audio.cancelPlaybackEvidence()
    }

    private func armPlaybackEvidence(_ owner: ScrcpyNativeMediaOwner) {
        guard let request = audioPlaybackEvidenceRequest else { return }
        let sourceID = owner.attempt.id
        owner.audio.requestPlaybackEvidence(id: request.id) { [weak self] id in
            Task { @MainActor in
                guard let self, self.nativeOwner?.attempt.id == sourceID,
                      self.audioPlaybackEnabled, self.nativeOwner?.attempt.isAdmitted == true,
                      let current = self.audioPlaybackEvidenceRequest, current.id == id else { return }
                self.audioPlaybackEvidenceRequest = nil
                current.completion(id)
            }
        }
    }

    private let nativeSessionID = UUID()
    private var preparationID = UUID()
    private(set) var nativeOwner: ScrcpyNativeMediaOwner?
    private var retiredNativeOwner: ScrcpyNativeMediaOwner?
    private var retiredNativeHandle: NativeMediaRetirement?
    private(set) var nativeRetirementOutcome: NativeMediaSettlement?
    var nativeRetirementSnapshot: NativeMediaSnapshot? { retiredNativeHandle?.snapshot }
    /// A deadline result is not proof that vendor/native references are gone.
    /// Cross-instance owners must check this before admitting a successor.
    var cleanupPhysicallySettled: Bool {
        (retiredNativeOwner?.attempt.snapshot.actuallySettled ?? true)
            && (retiredQuicTransport?.physicallySettled ?? true)
    }

    /// Actual prepare and host-native fixtures share this allocation seam.
    /// It never implicitly replaces a live or incompletely retired bundle.
    @discardableResult func beginNativeAttempt(
        videoQueue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.owned-video"),
        audioQueue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.owned-audio"),
        playoutQueue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.owned-playout"),
        frameDelivery: @escaping NativeFrameDelivery = { action in Task { @MainActor in action() } }
    ) throws -> ScrcpyNativeMediaOwner {
        guard nativeOwner == nil,
              retiredQuicTransport?.physicallySettled ?? true,
              retiredNativeOwner?.attempt.snapshot.actuallySettled ?? true else { throw NativeMediaFailure.cleanupIncomplete }
        retiredNativeOwner = nil
        retiredQuicTransport = nil
        let id = NativeMediaAttemptID(sessionID: nativeSessionID)
        let videoLeadTime: TimeInterval
        if wirelessADBVideoRecovery != nil,
           Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
           ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-video-lead-10ms") {
            videoLeadTime = 0.010
        } else if wirelessADBVideoRecovery != nil,
                  Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
                  ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-video-lead-30ms") {
            videoLeadTime = 0.030
        } else {
            videoLeadTime = MediaPlayoutClock.defaultLeadTime
        }
        let immediateVideoPlayout = wirelessADBVideoRecovery != nil || quicSelection != nil
            ? ScrcpyLaunchProfile.wirelessADB(codec: .h264).immediateVideoDelivery
            : ScrcpyLaunchProfile.usb.immediateVideoDelivery
        let owner = ScrcpyNativeMediaOwner(id: id, binding: makeNativeBinding(id),
            videoQueue: videoQueue, audioQueue: audioQueue, playoutQueue: playoutQueue,
            videoClock: MediaPlayoutClock(leadTime: videoLeadTime),
            immediateVideoPlayout: immediateVideoPlayout,
            recoverCorruptVideoFrames: quicSelection != nil, frameDelivery: frameDelivery) { [weak self] id, failure in
            Task { @MainActor in
                guard let self, self.nativeOwner?.attempt.id == id else { return }
                self.quicTransport?.nativeFailed(failure)
                self.fail(failure, component: "Native media")
            }
        }
        owner.audio.setPlaybackEnabled(audioPlaybackEnabled)
        nativeOwner = owner
        armPlaybackEvidence(owner)
        return owner
    }

    private func refreshNativeBinding() {
        if let owner = nativeOwner { owner.replaceBinding(makeNativeBinding(owner.attempt.id)) }
    }

    private func makeNativeBinding(_ id: NativeMediaAttemptID) -> NativeFrameBinding {
        let owned = ownedDecodedFrameHandler
        let diagnostic = diagnosticDecodedFrameHandler
        let plain = decodedFrameHandler
        return NativeFrameBinding { [weak self] frame in
            guard let self, frame.isAdmitted, self.nativeOwner?.attempt.id == id else {
                if let trace = frame.trace { trace.collector.finish(trace, reason: .dropped) }
                return
            }
            if let source=frame.context.sourceIdentity {
                self.lastMediaFrame=source
                self.publishScreenInterlockPresentation(self.screenPresentationBase)
            }
            if !self.hasDeliveredFirstFrameEvent {
                self.hasDeliveredFirstFrameEvent = true
                self.handleScreenInterlock(.firstFrame)
            }
            if let owned { owned(frame) }
            else if let diagnostic { diagnostic(frame.pixelBuffer, frame.presentationTime, frame.epoch, frame.trace) }
            else {
                plain?(frame.pixelBuffer, frame.presentationTime, frame.epoch)
                if let trace = frame.trace { trace.collector.finish(trace) }
            }
        }
    }

    init(
        serial: String,
        adb: ADBClient,
        physicalDisplayPolicy: ScrcpyPhysicalDisplayPolicy = .primaryMirror,
        automaticDisplayManagement: Bool = true,
        primaryDiagnosticsEnabled: Bool = false,
        clipboardPollingEnabled: Bool = true,
        quicSelection: QuicWirelessSelection? = nil,
        quicPreparedLaunch: (@Sendable (ScrcpyLaunchConfiguration, UInt64) async throws -> QuicBackendBridge.Launch)? = nil,
        keyboardEmissionSink: ((ScrcpyKeyboardEmission) -> Void)? = nil,
        applicationDisplayEventDelivery: @escaping ScrcpyApplicationDisplayEventDelivery = { action in
            Task { @MainActor in action() }
        },
        nativePreparationBoundary: (@MainActor @Sendable (ScrcpyNativeMediaOwner, ScrcpyCodec) async throws -> Bool)? = nil
    ) {
        self.serial = serial
        self.adb = adb
        self.physicalDisplayPolicy = physicalDisplayPolicy
        self.automaticDisplayManagement = automaticDisplayManagement
        self.primaryDiagnosticsEnabled = primaryDiagnosticsEnabled
        self.clipboardPollingEnabled = clipboardPollingEnabled
        wirelessADBVideoRecovery = serial.contains(":") || serial.contains("_adb-tls-connect._tcp")
            ? WirelessADBVideoIngressRecovery()
            : nil
        self.quicSelection = quicSelection
        self.quicPreparedLaunch = quicPreparedLaunch
        self.keyboardEmissionSink = keyboardEmissionSink
        self.applicationDisplayEventDelivery = applicationDisplayEventDelivery
        self.nativePreparationBoundary = nativePreparationBoundary
    }

    func start(
        preferredCodec: ScrcpyCodec = .h265,
        captureTarget requestedTarget: ScrcpyCaptureTarget? = nil,
        applicationTarget requestedApplicationTarget: ScrcpyApplicationTarget? = nil
    ) {
        guard state == .idle || state == .stopped || isFailure else { return }
        if isFailure { stopResources() }
        invalidateApplicationDisplayObservation()
        hasDeliveredFirstFrameEvent = false
        primaryDiagnosticsStartedAt = ProcessInfo.processInfo.systemUptime
        preparationTask?.cancel()
        let target = requestedTarget ?? captureTarget
        let targetApplication = requestedApplicationTarget ?? applicationTarget
        let initialCodec = ScrcpyLaunchProfile.selectedCodec(
            requested: preferredCodec,
            isWirelessADB: wirelessADBVideoRecovery != nil
        )
        captureTarget = target
        applicationTarget = targetApplication
        state = .preparing
        let request = UUID()
        preparationID = request
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                await cleanupTask?.value
                try checkPreparation(request)
                try await prepare(
                    preferredCodec: initialCodec,
                    captureTarget: target,
                    applicationTarget: targetApplication,
                    request: request
                )
                try checkPreparation(request)
                preparationTask = nil
            } catch is CancellationError {
                guard preparationID == request else { return }
                stopResources()
                preparationTask = nil
                if state != .stopped { state = .stopped }
            } catch {
                guard preparationID == request else { return }
                stopResources()
                let canRetryPreparation = !(error is NativeMediaFailure)
                    && !(error is QuicBackendError)
                    && !Task.isCancelled
                // A failed ADB preparation is not evidence that the Android
                // encoder rejected a hint. Do not silently retry the wireless
                // AVC session with different settings on unrelated failures.
                if initialCodec == .h265, canRetryPreparation {
                    state = .preparing
                    do {
                        await cleanupTask?.value
                        try checkPreparation(request)
                        try await prepare(
                            preferredCodec: .h264,
                            captureTarget: target,
                            applicationTarget: targetApplication,
                            request: request
                        )
                        try checkPreparation(request)
                        preparationTask = nil
                    } catch {
                        guard preparationID == request else { return }
                        stopResources()
                        preparationTask = nil
                        if Task.isCancelled {
                            if state != .stopped { state = .stopped }
                        } else {
                            fail(error, component: "H.264 fallback")
                        }
                    }
                } else {
                    preparationTask = nil
                    fail(error, component: "Session preparation")
                }
            }
        }
    }

    func stop() {
        preparationID = UUID()
        let precedingPreparation = preparationTask
        precedingPreparation?.cancel()
        preparationTask = nil
        restartTask?.cancel()
        restartTask = nil
        stopResources()
        if let precedingPreparation { scheduleCleanup { await precedingPreparation.value } }
        state = .stopped
    }

    func stopAndWaitForCleanup() async {
        stop()
        await cleanupTask?.value
    }

    func restart(captureTarget: ScrcpyCaptureTarget) {
        stop()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, state == .stopped else { return }
            restartTask = nil
            start(captureTarget: captureTarget)
        }
    }

    func sendControl(_ data: Data, diagnosticTrace: PrimaryMediaTrace? = nil) {
        if let quicTransport { quicTransport.send(data, received: QuicReceiptClock.now, trace: diagnosticTrace) }
        else { controlSocket?.send(data, diagnosticTrace: diagnosticTrace) }
    }

    func requestClipboard(
        copyKey: ScrcpyControlMessage.ClipboardCopyKey,
        afterExternalCopy: Bool = false
    ) {
        logger.info("Requesting device clipboard (copy-key: \(copyKey.rawValue, privacy: .public))")
        clipboardRequestTask?.cancel()
        let sendRequest = { [weak self] in
            guard let self else { return }
            self.forceNextClipboardForward = true
            for message in ScrcpyControlMessage.clipboardRequestMessages(copyKey: copyKey) {
                self.sendControl(message)
            }
        }
        guard afterExternalCopy else {
            clipboardRequestTask = nil
            sendRequest()
            return
        }
        clipboardRequestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self else { return }
            sendRequest()
            self.clipboardRequestTask = nil
        }
    }

    func sendText(_ text: String) {
        if quicSelection != nil, text.utf8.count > 262130 { fail(QuicBackendError(status: 108), component: "Clipboard input"); return }
        switch ScrcpyTextInputRoutingPolicy.route(for: text) {
        case .directInjection:
            sendDirectText(text)
        case .clipboardPaste:
            sendKeyboardEmissions(keyboardInputQueue.enqueueText(text))
            scheduleKeyboardSettlementIfNeeded()
        }
    }

    /// scrcpy's server injects TYPE_INJECT_TEXT on this session's action
    /// display. This matters for independent application windows: Samsung
    /// Chrome accepts direct text events on its virtual display, but ignores
    /// both KEYCODE_PASTE and Ctrl-V even after the clipboard is acknowledged.
    /// ADB `input text` is not used because it is lossy for composed/Unicode
    /// text and needs an externally discovered Android display id.
    func sendVirtualDisplayText(_ text: String) {
        if quicSelection != nil, text.count > 4096 { fail(QuicBackendError(status: 108), component: "Virtual display input"); return }
        let boundedText = String(text.prefix(4_096))
        guard !boundedText.isEmpty else { return }
        logger.info("Queueing virtual-display text (bytes: \(boundedText.utf8.count, privacy: .public))")
        self.sendDirectText(boundedText)
    }

    func sendDirectText(_ text: String) {
        for controlMessage in ScrcpyControlMessage.injectTextMessages(text) {
            sendKeyboardControl(controlMessage)
        }
    }

    func sendKeyboardControl(_ controlMessage: Data) {
        sendKeyboardEmissions(keyboardInputQueue.enqueueControl(controlMessage))
    }

    private func sendKeyboardEmissions(_ emissions: [ScrcpyKeyboardEmission]) {
        for emission in emissions {
            if let clipboardEcho = emission.clipboardEcho {
                injectedClipboardEchoes.markInjected(clipboardEcho)
                if let sequence = emission.clipboardSequence {
                    injectedClipboardEchoesBySequence[sequence] = clipboardEcho
                }
            }
            if let keyboardEmissionSink {
                keyboardEmissionSink(emission)
            } else {
                sendControl(emission.controlMessage)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private func prepare(
        preferredCodec: ScrcpyCodec,
        captureTarget: ScrcpyCaptureTarget,
        applicationTarget: ScrcpyApplicationTarget?,
        request: UUID
    ) async throws {
        try checkPreparation(request)
        let owner = try beginNativeAttempt()
        if let nativePreparationBoundary {
            // Owned host fixture boundary; normal production always continues
            // directly below. No transport or codec operation is substituted.
            let continueToADB = try await nativePreparationBoundary(owner, preferredCodec)
            try checkPreparation(request)
            if !continueToADB { return }
        }
        let hostPreparedLaunch = quicSelection != nil && quicPreparedLaunch != nil
        if !hasRemoteKeyboardPreferenceLease && !hostPreparedLaunch {
            try await EnhancedRemoteKeyboardPreferenceCoordinator.shared.acquire(
                adb: adb,
                serial: serial
            )
            guard preparationID == request, !Task.isCancelled else {
                try? await EnhancedRemoteKeyboardPreferenceCoordinator.shared.release(adb: adb, serial: serial)
                throw CancellationError()
            }
            hasRemoteKeyboardPreferenceLease = true
        }
        if quicSelection == nil {
            let serverURL = try ScrcpyServerLocator.locate()
            try await Task.detached(priority: .userInitiated) { [adb, serial] in
                try adb.push(serial: serial, localURL: serverURL, remotePath: ScrcpyLaunchConfiguration.remoteServerPath)
            }.value
        }
        try checkPreparation(request)
        var random = UInt32.random(in: 1 ... 0x7FFF_FFFF)
        if SecRandomCopyBytes(kSecRandomDefault, MemoryLayout.size(ofValue: random), &random) != errSecSuccess {
            random = UInt32.random(in: 1 ... 0x7FFF_FFFF)
        }
        random &= 0x7FFF_FFFF
        if random == 0 { random = 1 }
        let launchProfile = wirelessADBVideoRecovery == nil
            ? ScrcpyLaunchProfile.usb
            : ScrcpyLaunchProfile.wirelessADB(codec: preferredCodec)
        let constantBitRateExperiment = launchProfile.videoCodecConstantBitRate || (
            wirelessADBVideoRecovery != nil
                && Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
                && ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-cbr")
        )
        let fastestComplexityExperiment = launchProfile.videoCodecFastestComplexity || (
            wirelessADBVideoRecovery != nil
                && Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
                && ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-fastest-complexity")
        )
        let operatingRateExperiment: UInt16? = wirelessADBVideoRecovery != nil
            && Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-operating-rate-120")
            ? UInt16(120)
            : nil
        let repeatPreviousFrameExperiment: UInt32? = wirelessADBVideoRecovery != nil
            && Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-repeat-frame-50ms")
            ? UInt32(50_000)
            : nil
        let baselineProfileExperiment = wirelessADBVideoRecovery != nil
            && Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-baseline-profile")
        let reverseTunnelExperiment = wirelessADBVideoRecovery != nil
            && Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-reverse-tunnel")
        let maximumVideoSize = wirelessADBVideoRecovery != nil
            && Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-max-size-1280")
            ? UInt16(1_280)
            : launchProfile.maxSize
        let videoBitRate: UInt32
        if wirelessADBVideoRecovery != nil,
           Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
           ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-video-4mbps") {
            videoBitRate = 4_000_000
        } else if wirelessADBVideoRecovery != nil,
                  Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
                  ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-video-6mbps") {
            videoBitRate = 6_000_000
        } else if wirelessADBVideoRecovery != nil,
                  Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
                  ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-video-8mbps") {
            videoBitRate = 8_000_000
        } else {
            videoBitRate = launchProfile.videoBitRate
        }
        let maximumVideoFPS = wirelessADBVideoRecovery != nil
            && Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && ProcessInfo.processInfo.arguments.contains("--qa-scrcpy-video-30fps")
            ? UInt16(30)
            : launchProfile.maxFPS
        let configuration = ScrcpyLaunchConfiguration(
            scid: random,
            videoCodec: preferredCodec,
            maxSize: maximumVideoSize,
            maxFPS: maximumVideoFPS,
            videoBitRate: videoBitRate,
            videoKeyFrameIntervalSeconds: launchProfile.videoKeyFrameIntervalSeconds,
            videoCodecRealtimePriority: launchProfile.videoCodecRealtimePriority,
            videoCodecZeroFrameLatency: launchProfile.videoCodecZeroFrameLatency,
            videoCodecOperatingRate: operatingRateExperiment,
            videoCodecRepeatPreviousFrameAfterMicroseconds: repeatPreviousFrameExperiment,
            videoCodecConstantBitRate: constantBitRateExperiment,
            videoCodecFastestComplexity: fastestComplexityExperiment,
            videoCodecBaselineProfile: baselineProfileExperiment,
            audioEnabled: Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
                && ProcessInfo.processInfo.arguments.contains("--qa-disable-scrcpy-audio") ? false : nil,
            tunnelForward: !reverseTunnelExperiment,
            captureTarget: captureTarget,
            applicationTarget: applicationTarget,
            // Galaxy Bridge deliberately runs independent screen, application,
            // and capture-free clipboard scrcpy owners on the same phone. A
            // screen owner must therefore never ask the server to remove the
            // shared pinned jar or perform process-global cleanup when its
            // window closes. Each owner already retires its own socket,
            // forward, process, display state, and keyboard preference below.
            cleanup: ScrcpySharedResourceOwnershipPolicy.serverCleanupEnabled
        )
        self.configuration = configuration
        let diagnostics = PrimaryMediaDiagnostics.make(enabled: primaryDiagnosticsEnabled && applicationTarget == nil) {
            PrimaryMediaDiagnostics.logging(generation: UInt64.random(in: 1...UInt64.max),
                bundleID: Bundle.main.bundleIdentifier ?? "com.xopmc.GalaxyBridge.internal",
                startedAt: primaryDiagnosticsStartedAt)
        }
        primaryDiagnostics = diagnostics
        if let quicSelection {
            let generation = UInt64.random(in: 1...UInt64.max)
            let launch: QuicBackendBridge.Launch
            if let quicPreparedLaunch {
                launch = try await quicPreparedLaunch(configuration, generation)
            } else {
                launch = try await Task.detached(priority: .userInitiated) { [adb, serial] in
                    try QuicRuntimeArtifacts.launch(adb: adb, serial: serial, configuration: configuration,
                                                    selection: quicSelection, generation: generation)
                }.value
            }
            try checkPreparation(request)
            invalidateApplicationDisplayObservation()
            let displayGeneration = applicationTarget == nil ? nil : ScrcpyApplicationDisplayLaunchGeneration()
            applicationDisplayLaunchGeneration = displayGeneration
            let displayDelivery = applicationDisplayEventDelivery
            let healthDelivery=ScrcpyMediaHealthDelivery()
            let nativeID=owner.attempt.id
            mediaHealth=[:]; lastMediaFrame=nil
            let transport = QuicScrcpySessionTransport(launch: launch, native: owner, diagnostics: diagnostics, callbacks: .init(
                ready: { [weak self] in Task { @MainActor in
                    guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else { return }
                    self.handleScreenInterlock(.controlReady); self.controlReadyHandler?()
                    self.sendInitialControlMessages(); self.startClipboardPollingIfNeeded()
                } },
                media: { [weak self] media in
                    ScrcpyPrimaryMediaDelivery.deliver(media.work.event, trace: media.work.trace) { [weak self] event, trace in
                        guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else { return }
                        if media.identity.track == 1 {
                            self.handleVideo(event, diagnosticTrace: trace, owner: owner, work: media.work, consumed: true)
                        } else {
                            self.audioEventHandler?(event)
                            self.recordingAudioEventHandler?(event, media.identity.epoch, owner.attempt.id.attemptID)
                        }
                    }
                },
                device: { [weak self] message, delivery in Task { @MainActor in
                    delivery.deliver {
                        guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else { return false }
#if GB_QUIC_BACKEND_QA
                        self.quicDeviceObservation?(message)
#endif
                        self.handleControl(message)
                        return true
                    }
                } },
                display: { [weak self] event in displayDelivery {
                    guard let self, let displayGeneration else { return }
                    self.handleApplicationDisplayOutput(event, generation: displayGeneration)
                } },
                failure: { [weak self] error in Task { @MainActor in
                    guard let self, self.nativeOwner === owner else { return }
                    self.fail(error, component: "QUIC transport")
                } },
                health: { [weak self] value in healthDelivery.submit(value) { [weak self] value in
                    guard let self,self.nativeOwner?.attempt.id==nativeID else {return}
                    self.mediaHealth[value.track]=value
                    self.publishScreenInterlockPresentation(self.screenPresentationBase)
                } }
            ))
#if GB_QUIC_BACKEND_QA
            transport.stockObservation = quicStockObservation
#endif
            quicTransport = transport; state = .connecting; transport.start()
            return
        }
        let port: UInt16?
        if configuration.tunnelForward {
            let forwarded = try await Task.detached(priority: .userInitiated) { [adb, serial] in
                try adb.forwardAutomatically(serial: serial, socketName: configuration.socketName)
            }.value
            guard preparationID == request, !Task.isCancelled else {
                await Task.detached { [adb, serial] in
                    try? adb.removeForward(serial: serial, port: forwarded)
                }.value
                throw CancellationError()
            }
            forwardedPort = forwarded
            port = forwarded
        } else {
            let tunnel = try await ScrcpyReverseTunnel.start()
            // Retain the listener before any subsequent throwing operation so
            // the shared preparation cleanup always cancels it (and removes a
            // partially installed reverse mapping) on cancellation/failure.
            reverseTunnel = tunnel
            try checkPreparation(request)
            try await Task.detached(priority: .userInitiated) { [adb, serial] in
                try adb.reverse(
                    serial: serial,
                    socketName: configuration.socketName,
                    hostPort: tunnel.port
                )
            }.value
            port = nil
        }
        let outputObserver = try beginApplicationDisplayObservation(for: applicationTarget)
        // Record ownership before launch so cancellation during adb/app_process
        // startup can still retire only this exact server instance.
        serverSCID = configuration.scid
        serverProcess = try adb.launch(
            serial: serial,
            arguments: configuration.serverArguments,
            outputObserver: outputObserver
        )
        if configuration.tunnelForward {
            try await Task.detached(priority: .userInitiated) { [adb, serial] in
                try adb.waitForAbstractSocket(serial: serial, socketName: configuration.socketName)
            }.value
        }
        try checkPreparation(request)
        state = .connecting

        let reverseVideoConnection: NWConnection?
        let reverseAudioConnection: NWConnection?
        let reverseControlConnection: NWConnection?
        if let tunnel = reverseTunnel {
            reverseVideoConnection = try await tunnel.nextConnection()
            reverseAudioConnection = configuration.audioEnabled ? try await tunnel.nextConnection() : nil
            reverseControlConnection = try await tunnel.nextConnection()
            try checkPreparation(request)
        } else {
            reverseVideoConnection = nil
            reverseAudioConnection = nil
            reverseControlConnection = nil
        }

        let video = ScrcpyStreamSocket(
            connection: reverseVideoConnection ?? NWConnection(
                host: .ipv4(IPv4Address.loopback),
                port: NWEndpoint.Port(rawValue: port!)!,
                using: ScrcpyTCPParameters.make()
            ),
            kind: .video,
            initialPreambleLength: configuration.tunnelForward ? 65 : 64,
            expectsLeadingDummyByte: configuration.tunnelForward,
            diagnostics: diagnostics,
            eventHandler: { [weak self] event, trace in
                if let recovery = self?.wirelessADBVideoRecovery,
                   !recovery.shouldAdmit(event) {
                    if let trace { trace.collector.finish(trace, reason: .dropped) }
                    return
                }
                let admission: NativeMediaAdmission<NativeMediaWork>
                if let recovery = self?.wirelessADBVideoRecovery,
                   case let .packet(packet) = event, !packet.isConfiguration {
                    admission = owner.admitRecoverableRealtime(event, audio: false, trace: trace)
                    switch admission {
                    case let .granted(work):
                        recovery.noteAdmitted(event)
                        ScrcpyPrimaryMediaDelivery.deliver(work.event, trace: trace) { [weak self] event, trace in
                            guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else {
                                if let trace { trace.collector.finish(trace, reason: .dropped) }
                                return
                            }
                            self.handleVideo(event, diagnosticTrace: trace, owner: owner, work: work)
                        }
                    case .pressure:
                        if recovery.notePressure(on: event) { owner.video.markInputGap() }
                        if let trace { trace.collector.finish(trace, reason: .dropped) }
                    case .obsolete:
                        if let trace { trace.collector.finish(trace, reason: .dropped) }
                    case let .fatal(reason):
                        owner.attempt.fail(reason)
                        if let trace { trace.collector.finish(trace, reason: .failed) }
                    }
                    return
                }
                guard let work = owner.admit(event, trace: trace) else {
                    if let trace { trace.collector.finish(trace, reason: .dropped) }
                    return
                }
                ScrcpyPrimaryMediaDelivery.deliver(work.event, trace: trace) { [weak self] event, trace in
                    guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else {
                        if let trace { trace.collector.finish(trace, reason: .dropped) }
                        return
                    }
                    self.handleVideo(event, diagnosticTrace: trace, owner: owner, work: work)
                }
            },
            failureHandler: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else { return }
                    self.fail(error, component: "Video socket")
                }
            }
        )
        videoSocket = video
        video.start()

        if configuration.audioEnabled {
            try await Task.sleep(for: .milliseconds(40))
            try checkPreparation(request)
            let audio = ScrcpyStreamSocket(
                connection: reverseAudioConnection ?? NWConnection(
                    host: .ipv4(IPv4Address.loopback),
                    port: NWEndpoint.Port(rawValue: port!)!,
                    using: ScrcpyTCPParameters.make()
                ),
                kind: .audio,
                initialPreambleLength: 0,
                diagnostics: diagnostics,
                eventHandler: { [weak self] event, trace in
                    if self?.wirelessADBVideoRecovery != nil,
                       case let .packet(packet) = event, !packet.isConfiguration {
                        switch owner.admitRecoverableRealtime(event, audio: true, trace: trace) {
                        case let .granted(work):
                            ScrcpyPrimaryMediaDelivery.deliver(work.event, trace: trace) { [weak self] event, trace in
                                guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else {
                                    if let trace { trace.collector.finish(trace, reason: .dropped) }
                                    return
                                }
                                owner.audio.consume(event, diagnosticTrace: trace, nativeWork: work)
                                self.audioEventHandler?(event)
                                self.recordingAudioEventHandler?(event, nil, owner.attempt.id.attemptID)
                            }
                        case .pressure, .obsolete:
                            if let trace { trace.collector.finish(trace, reason: .dropped) }
                        case let .fatal(reason):
                            owner.attempt.fail(reason)
                            if let trace { trace.collector.finish(trace, reason: .failed) }
                        }
                        return
                    }
                    guard let work = owner.admit(event, audio: true, trace: trace) else {
                        if let trace { trace.collector.finish(trace, reason: .dropped) }
                        return
                    }
                    ScrcpyPrimaryMediaDelivery.deliver(work.event, trace: trace) { [weak self] event, trace in
                        guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else {
                            if let trace { trace.collector.finish(trace, reason: .dropped) }
                            return
                        }
                        owner.audio.consume(event, diagnosticTrace: trace, nativeWork: work)
                        self.audioEventHandler?(event)
                        self.recordingAudioEventHandler?(event, nil, owner.attempt.id.attemptID)
                    }
                },
                failureHandler: { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else { return }
                        self.fail(error, component: "Audio socket")
                    }
                }
            )
            audioSocket = audio
            audio.start()
            try await Task.sleep(for: .milliseconds(40))
            try checkPreparation(request)
        }
        let control = ScrcpyControlSocket(
            connection: reverseControlConnection ?? NWConnection(
                host: .ipv4(IPv4Address.loopback),
                port: NWEndpoint.Port(rawValue: port!)!,
                using: ScrcpyTCPParameters.make()
            ),
            diagnostics: diagnostics,
            readyHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else { return }
                    self.handleScreenInterlock(.controlReady)
                    self.controlReadyHandler?()
                    self.sendInitialControlMessages()
                    self.startClipboardPollingIfNeeded()
                }
            },
            messageHandler: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else { return }
                    self.handleControl(message)
                }
            },
            failureHandler: { [weak self] error in
                Task { @MainActor in
                    guard let self, self.nativeOwner === owner, owner.attempt.isAdmitted else { return }
                    self.fail(error, component: "Control socket")
                }
            }
        )
        controlSocket = control
        control.start()
    }

    private func sendInitialControlMessages() {
        guard controlSocket != nil || quicTransport != nil, let configuration else { return }
        for message in configuration.initialControlMessages {
            sendControl(message)
        }
    }

    func handleVideo(_ event: ScrcpyStreamEvent, diagnosticTrace: PrimaryMediaTrace? = nil) {
        guard let owner = nativeOwner, let work = owner.admit(event, trace: diagnosticTrace) else {
            if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
            return
        }
        handleVideo(work.event, diagnosticTrace: diagnosticTrace, owner: owner, work: work)
    }

    private func handleVideo(_ event: ScrcpyStreamEvent, diagnosticTrace: PrimaryMediaTrace?,
                             owner: ScrcpyNativeMediaOwner, work: NativeMediaWork, consumed: Bool = false) {
        guard nativeOwner === owner, work.attempt.isAdmitted else { return }
        if !consumed { owner.video.consume(event, diagnosticTrace: diagnosticTrace, nativeWork: work) }
        if case let .videoSession(session) = event {
            displayEpoch &+= 1
            videoSize = CGSize(width: Int(session.width), height: Int(session.height))
            state = .streaming(deviceName)
        }
        videoEventHandler?(event)
    }

    func beginApplicationDisplayObservation(
        for applicationTarget: ScrcpyApplicationTarget?
    ) throws -> ScrcpyOwnedProcessOutputObserver? {
        invalidateApplicationDisplayObservation()
        guard applicationTarget != nil else { return nil }
        let generation = ScrcpyApplicationDisplayLaunchGeneration()
        applicationDisplayLaunchGeneration = generation
        let applicationDisplayEventDelivery = applicationDisplayEventDelivery
        let observer = try ScrcpyOwnedProcessOutputObserver { [weak self] event in
            applicationDisplayEventDelivery {
                self?.handleApplicationDisplayOutput(event, generation: generation)
            }
        }
        serverOutputObserver = observer
        return observer
    }

    private func handleApplicationDisplayOutput(
        _ event: ScrcpyOwnedProcessOutputEvent,
        generation: ScrcpyApplicationDisplayLaunchGeneration
    ) {
        guard applicationDisplayLaunchGeneration == generation else { return }
        switch event {
        case let .announcement(announcement):
            guard !applicationDisplayIdentityConflicted else { return }
            if let applicationDisplayIdentity {
                guard applicationDisplayIdentity.displayID != announcement.displayID else { return }
                logger.info(
                    "Invalidated application display identity (id: \(applicationDisplayIdentity.displayID, privacy: .public))"
                )
                self.applicationDisplayIdentity = nil
                applicationDisplayIdentityConflicted = true
                return
            }
            applicationDisplayIdentity = ScrcpyApplicationDisplayIdentity(
                displayID: announcement.displayID,
                launchGeneration: generation
            )
            logger.info(
                "Observed application display identity (id: \(announcement.displayID, privacy: .public))"
            )
        case .conflict:
            if let applicationDisplayIdentity {
                logger.info(
                    "Invalidated application display identity (id: \(applicationDisplayIdentity.displayID, privacy: .public))"
                )
            }
            applicationDisplayIdentity = nil
            applicationDisplayIdentityConflicted = true
        case .ended:
            if let applicationDisplayIdentity {
                logger.info(
                    "Invalidated application display identity (id: \(applicationDisplayIdentity.displayID, privacy: .public))"
                )
            }
            applicationDisplayIdentity = nil
            applicationDisplayLaunchGeneration = nil
            applicationDisplayIdentityConflicted = false
            serverOutputObserver = nil
        }
    }

    private func invalidateApplicationDisplayObservation() {
        if let applicationDisplayIdentity {
            logger.info(
                "Invalidated application display identity (id: \(applicationDisplayIdentity.displayID, privacy: .public))"
            )
        }
        applicationDisplayIdentity = nil
        applicationDisplayLaunchGeneration = nil
        applicationDisplayIdentityConflicted = false
        serverOutputObserver?.cancel()
        serverOutputObserver = nil
    }

    private func handleControl(_ message: ScrcpyDeviceMessage) {
        switch message {
        case let .clipboard(content):
            logger.info("Received device clipboard (bytes: \(content.count, privacy: .public))")
            let forceForward = forceNextClipboardForward
            forceNextClipboardForward = false
            guard forceForward || lastObservedClipboardContent != content else { return }
            lastObservedClipboardContent = content
            guard injectedClipboardEchoes.shouldForward(content) else {
                logger.info("Suppressed reflected device clipboard")
                return
            }
            let update = ScrcpyClipboardUpdate(
                changeID: ScrcpyClipboardIdentity.changeID(
                    serial: serial,
                    sessionID: clipboardSessionID,
                    sequence: clipboardReceiveSequence,
                    content: content
                ),
                content: content
            )
            clipboardReceiveSequence &+= 1
            clipboardEventHandler?(update)
        case let .clipboardAcknowledgement(sequence):
            receiveKeyboardClipboardAcknowledgement(sequence)
        case .uhidOutput:
            break
        }
    }

    func receiveKeyboardClipboardAcknowledgement(_ sequence: UInt64) {
        logger.info("Received clipboard acknowledgement (sequence: \(sequence, privacy: .public))")
        sendKeyboardEmissions(keyboardInputQueue.acknowledgeClipboard(sequence: sequence))
        scheduleKeyboardSettlementIfNeeded()
    }

    private func startClipboardPollingIfNeeded() {
        guard clipboardPollingEnabled,
              physicalDisplayPolicy == .primaryMirror,
              clipboardPollingTask == nil
        else { return }
        clipboardPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.sendControl(ScrcpyControlMessage.getClipboard())
            }
        }
    }

    private func scheduleKeyboardSettlementIfNeeded() {
        guard let ticket = keyboardInputQueue.clipboardSettlementTicket else { return }
        keyboardSettlementTask?.cancel()
        keyboardSettlementTask = Task { [weak self] in
            // scrcpy acknowledges SET_CLIPBOARD after it queues KEYCODE_PASTE
            // with Android's asynchronous injection mode. Samsung may apply
            // that key after the acknowledgement. Restart this quiet period
            // whenever more physical text arrives so a later clipboard value
            // cannot replace the one Android is still pasting.
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled, let self,
                  self.keyboardInputQueue.clipboardSettlementTicket == ticket
            else { return }
            self.keyboardSettlementTask = nil
            if let content = self.injectedClipboardEchoesBySequence.removeValue(
                forKey: ticket.clipboardSequence
            ) {
                self.injectedClipboardEchoes.discardInjected(content)
            }
            self.sendKeyboardEmissions(
                self.keyboardInputQueue.completeClipboardSettlement(ticket: ticket)
            )
        }
    }

    private func handleScreenInterlock(_ event: ScreenInterlockEvent) {
        guard physicalDisplayPolicy == .primaryMirror, automaticDisplayManagement else {
            switch event {
            case .firstFrame:
                publishScreenInterlockPresentation(.mirroring)
            case .stopped:
                publishScreenInterlockPresentation(.waitingForFirstFrame)
            case .controlReady, .physicalDisplayChanged:
                break
            }
            return
        }
        let effects = screenInterlock.handle(event)
        publishScreenInterlockPresentation(screenInterlock.presentation)
        for effect in effects {
            switch effect {
            case .setPhysicalDisplayPowerOff:
                sendControl(ScrcpyControlMessage.setDisplayPower(on: false))
            case .forcePhysicalDisplayPowerOff:
                Task.detached(priority: .utility) { [adb, serial] in
                    _ = try? adb.run(arguments: [
                        "-s", serial, "shell", "cmd", "display", "power-off", "0",
                    ])
                }
            case .applyInteractiveBlackout:
                applyInteractiveDisplayBlackout()
            case .revealPhysicalDisplay:
                revealPhysicalDisplay()
            case .restorePhysicalDisplay:
                restorePhysicalDisplay()
            case .startPhysicalDisplayMonitoring:
                startPhysicalDisplayMonitoring()
            case .stopPhysicalDisplayMonitoring:
                stopPhysicalDisplayMonitoring()
            }
        }
    }

    private func publishScreenInterlockPresentation(
        _ presentation: ScreenInterlockPresentation
    ) {
        screenPresentationBase=presentation
        var composed=presentation
        if presentation == .mirroring, let health=mediaHealth[1] {
            let unavailable = ScreenStreamMediaAvailabilityPolicy.isUnavailable(
                healthState: health.state,
                healthReason: health.reason,
                healthEpoch: health.epoch,
                healthConfiguration: health.configuration,
                frameEpoch: lastMediaFrame?.epoch,
                frameConfiguration: lastMediaFrame?.configuration
            )
            if unavailable { composed = .mediaUnavailable }
        }
        guard let changed = screenInterlockPublication.consume(composed) else { return }
        screenInterlockPresentation = changed
    }

    private func applyInteractiveDisplayBlackout() {
        displayBlackoutTask?.cancel()
        displayBlackoutTask = Task { [weak self, adb, serial] in
            guard let self else { return }
            if originalDisplayBrightness == nil {
                let brightness = await Task.detached(priority: .utility) {
                    try? adb.displayBrightness(serial: serial)
                }.value
                guard !Task.isCancelled else { return }
                // Zero may be a residue from an interrupted previous debug
                // session. Keep a safe, dim restoration fallback rather than
                // trapping the user on a permanently black panel.
                originalDisplayBrightness = brightness.flatMap { $0 > 0 ? $0 : nil } ?? 0.05
            }
            await Task.detached(priority: .utility) {
                try? adb.setDisplayBrightness(serial: serial, brightness: 0)
                // A previous interrupted session or a physical power press may
                // leave Samsung's display asleep. Keep the OLED black, but
                // wake Android's display pipeline so SurfaceControl continues
                // producing frames and positional input remains available.
                try? adb.wakePhysicalDisplay(serial: serial)
            }.value
            guard !Task.isCancelled else { return }
            // Keep Android logically interactive. Samsung rejects every
            // positional injection while display power is actually OFF.
            sendControl(ScrcpyControlMessage.setDisplayPower(on: true))
        }
    }

    private func revealPhysicalDisplay() {
        displayBlackoutTask?.cancel()
        let brightness = originalDisplayBrightness ?? 0.05
        displayBlackoutTask = Task { [weak self, adb, serial] in
            await Task.detached(priority: .utility) {
                try? adb.setDisplayBrightness(serial: serial, brightness: brightness)
                try? adb.wakePhysicalDisplay(serial: serial)
            }.value
            guard !Task.isCancelled, let self else { return }
            sendControl(ScrcpyControlMessage.setDisplayPower(on: true))
        }
    }

    private func restorePhysicalDisplay() {
        displayBlackoutTask?.cancel()
        displayBlackoutTask = nil
        let brightness = originalDisplayBrightness
        originalDisplayBrightness = nil
        sendControl(ScrcpyControlMessage.setDisplayPower(on: true))
        guard let brightness else { return }
        scheduleCleanup { [adb, serial] in
            await Task.detached(priority: .utility) {
                try? adb.setDisplayBrightness(serial: serial, brightness: brightness)
            }.value
        }
    }

    private func scheduleCleanup(_ operation: @escaping @Sendable () async -> Void) {
        let precedingCleanup = cleanupTask
        cleanupTask = Task {
            await precedingCleanup?.value
            await operation()
        }
    }

    private func startPhysicalDisplayMonitoring() {
        guard physicalDisplayMonitoringTask == nil else { return }
        physicalDisplayMonitoringTask = Task { [weak self, adb, serial] in
            // Give scrcpy's SurfaceControl power command time to reach the
            // compositor before the first observation, avoiding a transient
            // active-device placeholder on a successful screen-off request.
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                let displayState = await Task.detached(priority: .utility) {
                    (try? adb.physicalDisplayState(serial: serial)) ?? .unknown
                }.value
                guard !Task.isCancelled, let self else { return }
                handleScreenInterlock(.physicalDisplayChanged(displayState))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopPhysicalDisplayMonitoring() {
        physicalDisplayMonitoringTask?.cancel()
        physicalDisplayMonitoringTask = nil
    }

    private func fail(_ error: Error, component: String) {
        preparationID = UUID()
        let precedingPreparation = preparationTask
        precedingPreparation?.cancel()
        preparationTask = nil
        let diagnostic = "\(component): \(String(reflecting: error))"
        logger.error("\(diagnostic, privacy: .private)")
        // Decoder errors are protocol diagnostics, not localized product copy.
        let message = error is ScrcpyDeviceMessageError
            ? String(localized: "ERROR_SCREEN_CONNECTION")
            : error.localizedDescription
        stopResources()
        if let precedingPreparation { scheduleCleanup { await precedingPreparation.value } }
        state = .failed(message)
    }

    private func stopResources() {
        cancelPlaybackEvidence()
        if let transport = quicTransport {
            transport.retire(); quicTransport = nil; retiredQuicTransport = transport
            scheduleCleanup { [weak self, transport] in
                let result = await transport.waitForCleanup()
                await self?.recordQuicRetirement(result)
            }
        }
        if let owner = nativeOwner {
            let retirement = owner.retire()
            nativeOwner = nil
            retiredNativeOwner = owner
            retiredNativeHandle = retirement
            scheduleCleanup { [weak self, owner] in
                let result = await retirement.wait()
                await self?.recordNativeRetirement(result)
                withExtendedLifetime(owner) {}
            }
        }
        primaryDiagnostics?.terminate()
        primaryDiagnostics = nil
        handleScreenInterlock(.stopped)
        hasDeliveredFirstFrameEvent = false
        mediaHealth=[:];lastMediaFrame=nil
        videoSocket?.cancel()
        audioSocket?.cancel()
        controlSocket?.cancel()
        videoSocket = nil
        audioSocket = nil
        controlSocket = nil
        resetKeyboardInput()
        clipboardPollingTask?.cancel()
        clipboardPollingTask = nil
        clipboardRequestTask?.cancel()
        clipboardRequestTask = nil
        lastObservedClipboardContent = nil
        forceNextClipboardForward = false
        displayBlackoutTask?.cancel()
        displayBlackoutTask = nil
        if hasRemoteKeyboardPreferenceLease {
            hasRemoteKeyboardPreferenceLease = false
            let adb = adb
            let serial = serial
            scheduleCleanup {
                try? await EnhancedRemoteKeyboardPreferenceCoordinator.shared.release(
                    adb: adb,
                    serial: serial
                )
            }
        }
        injectedClipboardEchoes = ScrcpyInjectedClipboardEchoSuppressor()
        injectedClipboardEchoesBySequence.removeAll(keepingCapacity: true)
        serverProcess?.terminate()
        serverProcess = nil
        if let scid = serverSCID {
            let adb = adb
            let serial = serial
            scheduleCleanup {
                await Task.detached {
                    try? adb.retireScrcpyServer(serial: serial, scid: scid)
                }.value
            }
        }
        serverSCID = nil
        invalidateApplicationDisplayObservation()
        if let port = forwardedPort {
            let adb = adb
            let serial = serial
            scheduleCleanup {
                await Task.detached { try? adb.removeForward(serial: serial, port: port) }.value
            }
        }
        forwardedPort = nil
        if let tunnel = reverseTunnel, let socketName = configuration?.socketName {
            tunnel.cancel()
            let adb = adb
            let serial = serial
            scheduleCleanup {
                await Task.detached {
                    try? adb.removeReverse(serial: serial, socketName: socketName)
                }.value
            }
        }
        reverseTunnel = nil
    }

    private func recordNativeRetirement(_ outcome: NativeMediaSettlement) {
        nativeRetirementOutcome = outcome
        if outcome.snapshot.actuallySettled, retiredNativeOwner?.attempt.id == outcome.attemptID {
            retiredNativeOwner = nil
        }
    }
    private func recordQuicRetirement(_ outcome: ScrcpyTransportSettlement) { quicRetirementOutcome = outcome }

    private func checkPreparation(_ request: UUID) throws {
        try Task.checkCancellation()
        guard preparationID == request else { throw CancellationError() }
        if let owner = nativeOwner, !owner.attempt.isAdmitted { throw NativeMediaFailure.cleanupIncomplete }
    }

    func resetKeyboardInput() {
        keyboardInputQueue.reset()
        keyboardSettlementTask?.cancel()
        keyboardSettlementTask = nil
    }
}

/// Several independent application windows may share one phone. Keep the
/// user's original "show software keyboard with a hardware keyboard" choice
/// until the last remote-keyboard session closes, then restore it exactly.
private actor EnhancedRemoteKeyboardPreferenceCoordinator {
    static let shared = EnhancedRemoteKeyboardPreferenceCoordinator()

    private struct LeaseState {
        var count: Int
        let originalValue: Bool?
    }

    private var leases: [String: LeaseState] = [:]

    func acquire(adb: ADBClient, serial: String) throws {
        if var lease = leases[serial] {
            lease.count += 1
            leases[serial] = lease
            return
        }
        let original = try adb.showsSoftwareKeyboardWithHardware(serial: serial)
        try adb.setShowsSoftwareKeyboardWithHardware(serial: serial, enabled: false)
        leases[serial] = LeaseState(count: 1, originalValue: original)
    }

    func release(adb: ADBClient, serial: String) throws {
        guard var lease = leases[serial] else { return }
        if lease.count > 1 {
            lease.count -= 1
            leases[serial] = lease
            return
        }
        leases.removeValue(forKey: serial)
        try adb.setShowsSoftwareKeyboardWithHardware(serial: serial, enabled: lease.originalValue)
    }
}

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

/// This is the existing socket→MainActor hop, shared with focused synthetic tests.
enum ScrcpyPrimaryMediaDelivery {
    static func deliver(_ event: ScrcpyStreamEvent, trace: PrimaryMediaTrace?,
                        handler: @escaping @MainActor @Sendable (ScrcpyStreamEvent, PrimaryMediaTrace?) -> Void) {
        if let trace { trace.collector.enter(.event, trace: trace) }
        Task { @MainActor in
            if let trace {
                trace.collector.leave(.event, trace: trace)
                trace.collector.mark(.actor, trace: trace)
            }
            handler(event, trace)
        }
    }
}

enum ScrcpyPrimaryControlDelivery {
    static func send(_ data: Data, queue: DispatchQueue, trace: PrimaryMediaTrace?, correlated: Bool,
                     now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                     sender: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Bool) {
        if let trace { trace.collector.enter(.control, trace: trace) }
        queue.async {
            let sentAt = now()
            if correlated, let trace, let received = trace.collector.stageTime(.received, trace: trace) {
                trace.collector.duration(.inputToDispatch, seconds: sentAt - received)
            }
            if correlated, let trace {
                trace.collector.inputDispatched(trace: trace, at: sentAt)
            }
            let accepted = sender(data) { error in
                if let trace {
                    if error != nil { trace.collector.cancelInputProbe(trace: trace) }
                    trace.collector.duration(.dispatchToProcessed, seconds: now() - sentAt)
                    trace.collector.leave(.control, trace: trace)
                    trace.collector.finish(trace, reason: error == nil ? .controlProcessed : .controlFailed)
                }
            }
            if !accepted, let trace {
                trace.collector.cancelInputProbe(trace: trace)
                trace.collector.leave(.control, trace: trace)
                trace.collector.finish(trace, reason: .dropped)
            }
        }
    }
}

private enum ScrcpySessionError: Error, LocalizedError {
    case serverNotFound
    case serverChecksumMismatch
    case invalidPreamble

    var errorDescription: String? {
        switch self {
        case .serverNotFound, .serverChecksumMismatch: String(localized: "ERROR_SCREEN_COMPONENT")
        case .invalidPreamble: String(localized: "ERROR_SCREEN_CONNECTION")
        }
    }
}

enum ScrcpyServerLocator {
    static func locate() throws -> URL {
        let environment = ProcessInfo.processInfo.environment["GALAXYBRIDGE_SCRCPY_SERVER"].map(URL.init(fileURLWithPath:))
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("third_party/scrcpy/scrcpy-server-v4.1")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("scrcpy-server-v4.1")
        var foundReadableCandidate = false
        for candidate in [environment, bundled, workingDirectory].compactMap({ $0 }) {
            guard FileManager.default.isReadableFile(atPath: candidate.path) else { continue }
            foundReadableCandidate = true
            guard let data = try? Data(contentsOf: candidate) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if digest == ScrcpyLaunchConfiguration.serverSHA256Hex { return candidate }
        }
        if foundReadableCandidate { throw ScrcpySessionError.serverChecksumMismatch }
        throw ScrcpySessionError.serverNotFound
    }
}

/// The socket's existing preamble/decoder sequence, without creating a connection.
struct ScrcpyPrimaryStreamParser {
    private var decoder: ScrcpyStreamDecoder
    private var remainingPreamble: Int
    private let expectsLeadingDummyByte: Bool
    private var preamble = Data()
    private let diagnostics: PrimaryMediaDiagnostics?
    private let diagnosticStream: PrimaryMediaStream
    private var diagnosticEpoch: UInt32 = 0

    init(
        kind: ScrcpyStreamKind,
        initialPreambleLength: Int,
        expectsLeadingDummyByte: Bool = true,
        diagnostics: PrimaryMediaDiagnostics? = nil
    ) {
        decoder = ScrcpyStreamDecoder(kind: kind, maxPayloadLength: 16 * 1024 * 1024)
        remainingPreamble = initialPreambleLength
        self.expectsLeadingDummyByte = expectsLeadingDummyByte
        self.diagnostics = diagnostics
        diagnosticStream = kind == .video ? .video : .audio
    }

    mutating func consume(_ input: Data, eventHandler: (ScrcpyStreamEvent, PrimaryMediaTrace?) -> Void) throws {
        var data = input
        guard !data.isEmpty else { return }
        diagnostics?.parser(rawBytes: data.count, retainedBytes: decoder.retainedStorageByteCount)
        defer { diagnostics?.emitIfDue() }
        if remainingPreamble > 0 {
            let consumed = min(remainingPreamble, data.count)
            preamble.append(data.prefix(consumed))
            data.removeFirst(consumed)
            remainingPreamble -= consumed
            if remainingPreamble == 0, expectsLeadingDummyByte, preamble.first != 0 {
                throw ScrcpySessionError.invalidPreamble
            }
        }
        if remainingPreamble == 0, !data.isEmpty {
            diagnostics?.parser(rawBytes: 0, retainedBytes: decoder.retainedStorageByteCount + data.count)
            for event in try decoder.append(data) {
                if case .videoSession = event, diagnosticEpoch < UInt32.max { diagnosticEpoch += 1 }
                let pts: UInt64?
                let length: Int
                let isPacket: Bool
                if case let .packet(packet) = event {
                    isPacket = true
                    pts = packet.isConfiguration ? nil : packet.presentationTimeUs
                    length = packet.payload.count
                    if packet.isConfiguration {
                        diagnostics?.count(.configuration)
                        if diagnosticStream == .audio, diagnosticEpoch < UInt32.max { diagnosticEpoch += 1 }
                    }
                    if packet.isKeyFrame { diagnostics?.count(.keyFrames) }
                } else { pts = nil; length = 0; isPacket = false }
                let trace = diagnostics?.received(stream: diagnosticStream, bytes: length, pts: pts,
                    epoch: diagnosticEpoch == 0 ? nil : diagnosticEpoch, isPacket: isPacket)
                eventHandler(event, trace)
            }
        }
        diagnostics?.parser(rawBytes: 0, retainedBytes: decoder.retainedStorageByteCount)
    }

    func recordFailure() { diagnostics?.count(.failed) }
}

enum ScrcpyTCPParameters {
    static func make() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // scrcpy carries latency-sensitive control messages and encoded access
        // units over separate ADB forwards. Delaying small writes here makes a
        // Wi-Fi gesture wait behind Nagle/coalescing even though the decoder and
        // renderer are idle. USB largely hides that delay, so keep one explicit
        // low-latency socket policy for both transports.
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }
}

enum ScrcpyReverseTunnelError: Error, LocalizedError {
    case listenerFailed(String)
    case listenerTimeout
    case connectionTimeout

    var errorDescription: String? { String(localized: "ERROR_SCREEN_CONNECTION") }
}

/// Accepts scrcpy's video, audio and control sockets in their documented order
/// when modern Wireless ADB supports reverse redirection. Keeping the listener
/// loopback-only prevents another LAN peer from entering the unauthenticated
/// scrcpy socket while ADB remains the authenticated carrier.
private final class ScrcpyReverseTunnel: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.scrcpy-reverse")
    private let lock = NSLock()
    private var acceptedConnections: [NWConnection] = []
    private var failure: ScrcpyReverseTunnelError?
    private var ready = false

    private init(listener: NWListener) {
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.enqueue(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.recordReady()
            case let .failed(error):
                self?.recordFailure(error.localizedDescription)
            default:
                break
            }
        }
    }

    var port: UInt16 { listener.port!.rawValue }

    static func start(timeout: Duration = .seconds(3)) async throws -> ScrcpyReverseTunnel {
        let parameters = ScrcpyTCPParameters.make()
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address.loopback),
            port: .any
        )
        let tunnel = try ScrcpyReverseTunnel(listener: NWListener(using: parameters))
        tunnel.listener.start(queue: tunnel.queue)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let failure = tunnel.currentFailure() {
                tunnel.cancel()
                throw failure
            }
            if tunnel.isReady(), tunnel.port != 0 { return tunnel }
            try await Task.sleep(for: .milliseconds(10))
        }
        tunnel.cancel()
        throw ScrcpyReverseTunnelError.listenerTimeout
    }

    func nextConnection(timeout: Duration = .seconds(4)) async throws -> NWConnection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let failure = currentFailure() { throw failure }
            if let connection = dequeueConnection() { return connection }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ScrcpyReverseTunnelError.connectionTimeout
    }

    func cancel() {
        listener.cancel()
        let pending = lock.withLock { () -> [NWConnection] in
            let pending = acceptedConnections
            acceptedConnections.removeAll()
            return pending
        }
        pending.forEach { $0.cancel() }
    }

    private func enqueue(_ connection: NWConnection) {
        lock.withLock { acceptedConnections.append(connection) }
    }

    private func dequeueConnection() -> NWConnection? {
        lock.withLock {
            guard !acceptedConnections.isEmpty else { return nil }
            return acceptedConnections.removeFirst()
        }
    }

    private func recordFailure(_ message: String) {
        lock.withLock { failure = .listenerFailed(message) }
    }

    private func recordReady() {
        lock.withLock { ready = true }
    }

    private func isReady() -> Bool {
        lock.withLock { ready }
    }

    private func currentFailure() -> ScrcpyReverseTunnelError? {
        lock.withLock { failure }
    }
}

private final class ScrcpyStreamSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let eventHandler: @Sendable (ScrcpyStreamEvent, PrimaryMediaTrace?) -> Void
    private let failureHandler: @Sendable (Error) -> Void
    private let diagnostics: PrimaryMediaDiagnostics?
    private let diagnosticStream: PrimaryMediaStream
    private var parser: ScrcpyPrimaryStreamParser

    init(
        connection: NWConnection,
        kind: ScrcpyStreamKind,
        initialPreambleLength: Int,
        expectsLeadingDummyByte: Bool = true,
        diagnostics: PrimaryMediaDiagnostics? = nil,
        eventHandler: @escaping @Sendable (ScrcpyStreamEvent, PrimaryMediaTrace?) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        self.connection = connection
        queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.scrcpy-stream.\(UUID().uuidString)")
        parser = ScrcpyPrimaryStreamParser(
            kind: kind,
            initialPreambleLength: initialPreambleLength,
            expectsLeadingDummyByte: expectsLeadingDummyByte,
            diagnostics: diagnostics
        )
        self.eventHandler = eventHandler
        self.failureHandler = failureHandler
        self.diagnostics = diagnostics
        diagnosticStream = kind == .video ? .video : .audio
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.receive()
            case let .failed(error): self?.failureHandler(error)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        let armedAt = ProcessInfo.processInfo.systemUptime
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            let callbackAt = ProcessInfo.processInfo.systemUptime
            diagnostics?.socketReceived(stream: diagnosticStream, bytes: data?.count ?? 0,
                                        armedAt: armedAt, callbackAt: callbackAt)
            defer {
                diagnostics?.socketCallbackCompleted(stream: diagnosticStream, callbackAt: callbackAt,
                                                     completedAt: ProcessInfo.processInfo.systemUptime)
            }
            do {
                if let data { try parser.consume(data, eventHandler: eventHandler) }
                if let error { throw error }
                if complete { return }
                receive()
            } catch {
                parser.recordFailure()
                failureHandler(error)
                connection.cancel()
            }
        }
    }
}

enum ScrcpyControlSocketError: Error, LocalizedError {
    case closed

    var errorDescription: String? { String(localized: "ERROR_SCREEN_CONNECTION") }
}

final class ScrcpyControlSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let readyHandler: @Sendable () -> Void
    private let controlReceivePipeline: ScrcpyControlReceivePipeline
    private let diagnostics: PrimaryMediaDiagnostics?
    private let initialPreambleLength: Int
    private var remainingPreambleLength: Int

    convenience init(
        port: UInt16,
        initialPreambleLength: Int = 0,
        diagnostics: PrimaryMediaDiagnostics? = nil,
        readyHandler: @escaping @Sendable () -> Void,
        messageHandler: @escaping @Sendable (ScrcpyDeviceMessage) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        self.init(
            connection: NWConnection(
                host: .ipv4(IPv4Address.loopback),
                port: NWEndpoint.Port(rawValue: port)!,
                using: ScrcpyTCPParameters.make()
            ),
            initialPreambleLength: initialPreambleLength,
            diagnostics: diagnostics,
            readyHandler: readyHandler,
            messageHandler: messageHandler,
            failureHandler: failureHandler
        )
    }

    init(
        connection: NWConnection,
        initialPreambleLength: Int = 0,
        diagnostics: PrimaryMediaDiagnostics? = nil,
        readyHandler: @escaping @Sendable () -> Void,
        messageHandler: @escaping @Sendable (ScrcpyDeviceMessage) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        self.connection = connection
        queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.scrcpy-control.\(UUID().uuidString)")
        self.readyHandler = readyHandler
        self.diagnostics = diagnostics
        self.initialPreambleLength = initialPreambleLength
        remainingPreambleLength = initialPreambleLength
        controlReceivePipeline = ScrcpyControlReceivePipeline(
            messageHandler: messageHandler,
            failureHandler: failureHandler
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readyHandler()
                self?.receiveControl()
            case let .failed(error): self?.controlReceivePipeline.terminate(error)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data, diagnosticTrace: PrimaryMediaTrace? = nil) {
        let trace = diagnosticTrace ?? diagnostics?.received(stream: .control, bytes: data.count, pts: nil, epoch: nil)
        if diagnosticTrace == nil { diagnostics?.count(.uncorrelatedControl) }
        ScrcpyPrimaryControlDelivery.send(data, queue: queue, trace: trace, correlated: diagnosticTrace != nil) { [weak self] data, completion in
            guard let self else { return false }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                completion(error)
                if let error { self?.controlReceivePipeline.terminate(error) }
            })
            return true
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            controlReceivePipeline.cancel()
            connection.cancel()
        }
    }

    private func receiveControl() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var payload = data ?? Data()
            if remainingPreambleLength > 0, !payload.isEmpty {
                let consumed = min(remainingPreambleLength, payload.count)
                if remainingPreambleLength == initialPreambleLength,
                   payload.first != 0 {
                    controlReceivePipeline.terminate(ScrcpySessionError.invalidPreamble)
                    connection.cancel()
                    return
                }
                payload.removeFirst(consumed)
                remainingPreambleLength -= consumed
            }
            if !payload.isEmpty, !controlReceivePipeline.consume(payload) {
                connection.cancel()
                return
            }
            if let error {
                controlReceivePipeline.terminate(error)
                connection.cancel()
                return
            }
            if complete {
                controlReceivePipeline.terminate(ScrcpyControlSocketError.closed)
                connection.cancel()
                return
            }
            receiveControl()
        }
    }
}
#endif
