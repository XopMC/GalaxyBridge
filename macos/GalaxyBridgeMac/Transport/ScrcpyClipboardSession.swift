#if !GALAXYBRIDGE_APP_STORE
import CryptoKit
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import OSLog
import Security

/// A capture-free scrcpy control connection used only for clipboard sync.
/// It does not open video/audio encoders, change display power, create a UHID
/// keyboard, or alter the phone's IME policy.
@MainActor
final class ScrcpyClipboardSession {
    private static let logger = Logger(
        subsystem: "com.xopmc.GalaxyBridge",
        category: "capture-free-clipboard"
    )
    enum State: Equatable {
        case idle
        case preparing
        case ready
        case stopped
        case failed
    }

    let serial: String
    var clipboardTrustGeneration: UUID { generation }
    var clipboardTrustPeer: PairedPeer? { shellLease?.context.peer }
    private let adb: ADBClient
    private let shellProvider: ShellCapabilityBridgeProvider?
    private var shellLease: ShellCapabilityBridgeLease?
    private var shellCleanup: Task<Void, Never>?
    private let sessionID = UUID().uuidString.lowercased()
    private let readyHandler: @MainActor @Sendable (String) -> Void
    private let failureHandler: @MainActor @Sendable (String) -> Void
    private var state: State = .idle
    private var generation = UUID()
    private var preparationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var serverProcess: Process?
    private var serverOwnerLifetime: ScrcpyADBOwnerLifetime?
    private var serverSCID: UInt32?
    private var forwardedPort: UInt16?
    private var agentForwardedPort: UInt16?
    private var controlSocket: ScrcpyControlSocket?
    private var agentSocket: ClipboardAgentSocket?
    private var agentProcess: Process?
    private var agentOwnerLifetime: ScrcpyADBOwnerLifetime?
    private var receiveSequence: UInt64 = 1
    private var sendSequence: UInt64 = 1
    private var lastObservedContent: Data?
    private var pendingAgentMessage: ScrcpyClipboardAgentMessage?
    private(set) var usesClipboardOccurrences = false
    private(set) var supportsClipboardAvailability = false
    private var injectedEchoes = ScrcpyInjectedClipboardEchoSuppressor(capacity: 16)

    var clipboardEventHandler: (@MainActor @Sendable (ScrcpyClipboardUpdate) -> Void)?
    var clipboardUnavailableHandler: (@MainActor @Sendable () -> Void)?

    init(
        serial: String,
        adb: ADBClient,
        readyHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        failureHandler: @escaping @MainActor @Sendable (String) -> Void,
        shellProvider: ShellCapabilityBridgeProvider? = nil
    ) {
        self.serial = serial
        self.adb = adb
        self.shellProvider = shellProvider
        self.readyHandler = readyHandler
        self.failureHandler = failureHandler
    }

    func start() {
        guard state == .idle || state == .stopped || state == .failed else { return }
        stopResources()
        state = .preparing
        let request = UUID()
        generation = request
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                await shellCleanup?.value
                guard generation == request, !Task.isCancelled else { throw CancellationError() }
                if let shellProvider {
                    let config = ScrcpyLaunchConfiguration(scid: UInt32.random(in: 1...0x7fff_ffff),
                        videoEnabled: false, audioEnabled: false, sendDeviceMeta: false, keepActive: false,
                        hideDeviceIME: false, uhidKeyboardEnabled: false, cleanup: true)
                    let lease = try await shellProvider.prepare(configuration: config, operation: .startClipboard)
                    guard generation == request, !Task.isCancelled else { try? await shellProvider.retire(lease); throw CancellationError() }
                    shellLease = lease
                    guard let port = lease.port else { throw ShellCapabilityBridgeFailure.invalidResult }
                    let socket = ScrcpyControlSocket(port: port, initialPreambleLength: 1,
                        readyHandler: { [weak self] in Task { @MainActor in self?.didBecomeReady(request: request) } },
                        messageHandler: { [weak self] message in Task { @MainActor in self?.receive(message, request: request) } },
                        failureHandler: { [weak self] error in Task { @MainActor in self?.fail(request: request, reason: String(describing: error)) } })
                    controlSocket = socket
                    if let agentPort = lease.clipboardPort {
                        let agent = ClipboardAgentSocket(port: agentPort,
                            readyHandler: { [weak self] occurrences in Task { @MainActor in self?.didBecomeAgentReady(usesOccurrences: occurrences, request: request) } },
                            messageHandler: { [weak self] message in Task { @MainActor in self?.receiveAgent(message, request: request) } },
                            failureHandler: { [weak self] error in Task { @MainActor in self?.agentUnavailable(request: request, reason: String(describing: error)) } })
                        agentSocket = agent; agent.start()
                    }
                    socket.start(); return
                }
                let serverURL = try ScrcpyServerLocator.locate()
                try await Task.detached(priority: .utility) { [adb, serial] in
                    try adb.push(
                        serial: serial,
                        localURL: serverURL,
                        remotePath: ScrcpyLaunchConfiguration.remoteServerPath
                    )
                }.value
                try Task.checkCancellation()
                guard generation == request else { throw CancellationError() }

                var scid = UInt32.random(in: 1 ... 0x7FFF_FFFF)
                if SecRandomCopyBytes(kSecRandomDefault, MemoryLayout.size(ofValue: scid), &scid) != errSecSuccess {
                    scid = UInt32.random(in: 1 ... 0x7FFF_FFFF)
                }
                scid &= 0x7FFF_FFFF
                if scid == 0 { scid = 1 }
                let configuration = ScrcpyLaunchConfiguration(
                    scid: scid,
                    videoEnabled: false,
                    audioEnabled: false,
                    sendDeviceMeta: false,
                    keepActive: false,
                    hideDeviceIME: false,
                    uhidKeyboardEnabled: false,
                    // This helper owns no display/IME state. Keeping the pinned
                    // jar in place avoids deleting it underneath another
                    // screen/app session on the same phone.
                    cleanup: false
                )
                serverSCID = scid
                let port = try await Task.detached(priority: .utility) { [adb, serial] in
                    try adb.forwardAutomatically(serial: serial, socketName: configuration.socketName)
                }.value
                guard generation == request, !Task.isCancelled else {
                    await Task.detached { [adb, serial] in
                        try? adb.removeForward(serial: serial, port: port)
                    }.value
                    throw CancellationError()
                }
                forwardedPort = port
                let serverLifetime = try ScrcpyADBOwnerLifetime()
                serverOwnerLifetime = serverLifetime
                serverProcess = try adb.launch(serial: serial,
                    arguments: ScrcpyADBOwnerLifetime.launchArguments(configuration.serverArguments), inputPipe: serverLifetime.pipe)
                serverLifetime.start()
                try await Task.detached(priority: .utility) { [adb, serial] in
                    try adb.waitForAbstractSocket(serial: serial, socketName: configuration.socketName)
                }.value
                guard generation == request, !Task.isCancelled else { throw CancellationError() }

                // With video, audio, and device metadata disabled, scrcpy sends
                // only its one tunnel-forward dummy byte before device messages.
                let socket = ScrcpyControlSocket(
                    port: port,
                    initialPreambleLength: 1,
                    readyHandler: { [weak self] in
                        Task { @MainActor in self?.didBecomeReady(request: request) }
                    },
                    messageHandler: { [weak self] message in
                        Task { @MainActor in self?.receive(message, request: request) }
                    },
                    failureHandler: { [weak self] error in
                        Task { @MainActor in
                            self?.fail(request: request, reason: String(describing: error))
                        }
                    }
                )
                controlSocket = socket

                do {
                    let agentName = "galaxybridge_clipboard_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
                    let agentPort = try await Task.detached(priority: .utility) { [adb, serial] in
                        try adb.forwardAutomatically(serial: serial, socketName: agentName)
                    }.value
                    agentForwardedPort = agentPort
                    let agentLifetime = try ScrcpyADBOwnerLifetime()
                    agentOwnerLifetime = agentLifetime
                    agentProcess = try adb.launch(serial: serial, arguments: ScrcpyADBOwnerLifetime.launchArguments([
                        "shell",
                        "CLASSPATH=\(ScrcpyLaunchConfiguration.remoteServerPath)",
                        "app_process",
                        "/",
                        "com.genymobile.scrcpy.ClipboardAgent",
                        agentName,
                    ]), inputPipe: agentLifetime.pipe)
                    agentLifetime.start()
                    try await Task.detached(priority: .utility) { [adb, serial] in
                        try adb.waitForAbstractSocket(serial: serial, socketName: agentName)
                    }.value
                    guard generation == request, !Task.isCancelled else { throw CancellationError() }
                    let clipboardAgent = ClipboardAgentSocket(
                        port: agentPort,
                        readyHandler: { [weak self] occurrences in
                            Task { @MainActor in self?.didBecomeAgentReady(usesOccurrences: occurrences, request: request) }
                        },
                        messageHandler: { [weak self] message in
                            Task { @MainActor in self?.receiveAgent(message, request: request) }
                        },
                        failureHandler: { [weak self] error in
                            Task { @MainActor in self?.agentUnavailable(request: request, reason: String(describing: error)) }
                        }
                    )
                    agentSocket = clipboardAgent
                    clipboardAgent.start()
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard generation == request, !Task.isCancelled else { throw CancellationError() }
                    agentUnavailable(request: request, reason: String(describing: error))
                }
                socket.start()
            } catch is CancellationError {
                // Explicit retirement owns cleanup.
            } catch {
                fail(request: request, reason: String(describing: error))
            }
        }
    }

    func stop() {
        generation = UUID()
        state = .stopped
        stopResources()
    }

    /// Application termination must wait for ADB-server forward removal. A
    /// detached fire-and-forget task is correct during ordinary reconciliation
    /// but can be killed with the process and leak ports across launches.
    func stopAndWait() async {
        generation = UUID()
        state = .stopped
        let resources = stopResources(scheduleRemoteCleanup: false)
        await shellCleanup?.value
        guard resources.port != nil || resources.agentPort != nil || resources.scid != nil else { return }
        let adb = adb
        let serial = serial
        await Task.detached(priority: .utility) {
            if let scid = resources.scid {
                try? adb.retireScrcpyServer(serial: serial, scid: scid)
            }
            if let port = resources.port {
                try? adb.removeForward(serial: serial, port: port)
            }
            if let port = resources.agentPort {
                try? adb.removeForward(serial: serial, port: port)
            }
        }.value
    }

    @discardableResult
    func setText(_ value: String, changeID: String) -> Bool {
        guard state == .ready,
              !value.isEmpty,
              value.utf8.count <= ScrcpyDeviceMessageDecoder.maximumClipboardLength,
              let controlSocket
        else { return false }
        if usesClipboardOccurrences, let agentSocket {
            return agentSocket.setText(value, changeID: changeID)
        }
        let content = Data(value.utf8)
        injectedEchoes.markInjected(content)
        controlSocket.send(
            ScrcpyControlMessage.setClipboard(
                sequence: sendSequence,
                text: value,
                paste: false
            )
        )
        sendSequence &+= 1
        if sendSequence == 0 { sendSequence = 1 }
        return true
    }

    private func didBecomeReady(request: UUID) {
        guard generation == request, state == .preparing else { return }
        state = .ready
        readyHandler(serial)
        if let pendingAgentMessage {
            self.pendingAgentMessage = nil
            receiveAgent(pendingAgentMessage, request: request)
        }
        startLegacyClipboardPolling(request: request)
    }

    private func didBecomeAgentReady(usesOccurrences: Bool, request: UUID) {
        guard generation == request, agentSocket != nil, state == .preparing || state == .ready else { return }
        if usesOccurrences {
            usesClipboardOccurrences = true
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func startLegacyClipboardPolling(request: UUID) {
        guard generation == request, state == .ready, !usesClipboardOccurrences, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // Give the bounded agent preamble a chance before a content read.
            // A missing/legacy agent retains the stock text fallback.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            while !Task.isCancelled {
                guard let self, self.generation == request, self.state == .ready,
                      !self.usesClipboardOccurrences else { return }
                self.controlSocket?.send(ScrcpyControlMessage.getClipboard())
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func agentUnavailable(request: UUID, reason: String) {
        guard generation == request else { return }
        // Once GBC2 owns full text/image observation, reconnect it on failure.
        // Before protocol negotiation the existing stock text fallback is usable.
        if usesClipboardOccurrences { fail(request: request, reason: reason); return }
        agentSocket?.cancel()
        agentSocket = nil
        agentOwnerLifetime?.stop(); agentOwnerLifetime = nil
        if let agentProcess, agentProcess.isRunning { agentProcess.terminate() }
        agentProcess = nil
        if state == .ready { startLegacyClipboardPolling(request: request) }
    }

    private func receive(_ message: ScrcpyDeviceMessage, request: UUID) {
        guard generation == request, state == .ready else { return }
        guard !usesClipboardOccurrences else { return }
        guard case let .clipboard(content) = message,
              content != lastObservedContent
        else { return }
        lastObservedContent = content
        if Self.qaDiagnosticsEnabled {
            let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            print("GB_CLIPBOARD_QA observed serial=\(serial) sha256=\(digest)")
        }
        guard injectedEchoes.shouldForward(content) else { return }
        let update = ScrcpyClipboardUpdate(
            changeID: ScrcpyClipboardIdentity.changeID(
                serial: serial,
                sessionID: sessionID,
                sequence: receiveSequence,
                content: content
            ),
            content: content
        )
        receiveSequence &+= 1
        if receiveSequence == 0 { receiveSequence = 1 }
        clipboardEventHandler?(update)
    }

    private func receiveAgent(_ message: ScrcpyClipboardAgentMessage, request: UUID) {
        guard generation == request, agentSocket != nil else { return }
        guard state == .ready else {
            if state == .preparing { pendingAgentMessage = message }
            return
        }
        if message.timestamp != nil {
            didBecomeAgentReady(usesOccurrences: true, request: request)
        } else if message.content == lastObservedContent { return }
        guard message.isAvailable else {
            supportsClipboardAvailability = message.reportsAvailability
            lastObservedContent = nil
            clipboardUnavailableHandler?()
            return
        }
        supportsClipboardAvailability = message.reportsAvailability
        lastObservedContent = message.content
        if message.timestamp == nil, message.kind == .text, !injectedEchoes.shouldForward(message.content) { return }
        let update = ScrcpyClipboardUpdate(
            changeID: message.originChangeID ?? ScrcpyClipboardIdentity.changeID(
                serial: serial,
                sessionID: sessionID,
                sequence: receiveSequence,
                content: message.content
            ),
            kind: message.kind,
            content: message.content
        )
        receiveSequence &+= 1
        if receiveSequence == 0 { receiveSequence = 1 }
        clipboardEventHandler?(update)
    }

    private func fail(request: UUID, reason: String) {
        guard generation == request, state != .stopped, state != .failed else { return }
        Self.logger.error("Capture-free clipboard session failed: \(reason, privacy: .public)")
        state = .failed
        stopResources()
        failureHandler(serial)
    }

    @discardableResult
    private func stopResources(
        scheduleRemoteCleanup: Bool = true
    ) -> (port: UInt16?, agentPort: UInt16?, scid: UInt32?) {
        if let shellLease, let shellProvider {
            self.shellLease = nil; shellLease.cancelLocal()
            let preceding = shellCleanup
            shellCleanup = Task { await preceding?.value; try? await shellProvider.retire(shellLease) }
        }
        preparationTask?.cancel()
        preparationTask = nil
        pollTask?.cancel()
        pollTask = nil
        controlSocket?.cancel()
        controlSocket = nil
        agentSocket?.cancel()
        agentSocket = nil
        serverOwnerLifetime?.stop(); serverOwnerLifetime = nil
        agentOwnerLifetime?.stop(); agentOwnerLifetime = nil
        serverProcess?.terminate()
        serverProcess = nil
        agentProcess?.terminate()
        agentProcess = nil
        let scid = serverSCID
        serverSCID = nil
        let port = forwardedPort
        forwardedPort = nil
        let agentPort = agentForwardedPort
        agentForwardedPort = nil
        lastObservedContent = nil
        pendingAgentMessage = nil
        usesClipboardOccurrences = false
        supportsClipboardAvailability = false
        injectedEchoes = ScrcpyInjectedClipboardEchoSuppressor(capacity: 16)
        if scheduleRemoteCleanup, port != nil || agentPort != nil || scid != nil {
            let adb = adb
            let serial = serial
            Task.detached(priority: .utility) {
                if let scid {
                    try? adb.retireScrcpyServer(serial: serial, scid: scid)
                }
                if let port {
                    try? adb.removeForward(serial: serial, port: port)
                }
                if let agentPort {
                    try? adb.removeForward(serial: serial, port: agentPort)
                }
            }
        }
        return (port, agentPort, scid)
    }

    private static var qaDiagnosticsEnabled: Bool {
        Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal" &&
            ProcessInfo.processInfo.arguments.contains("--qa-clipboard-diagnostics")
    }
}
#endif
