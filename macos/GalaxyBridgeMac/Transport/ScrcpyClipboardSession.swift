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
    private let adb: ADBClient
    private let sessionID = UUID().uuidString.lowercased()
    private let readyHandler: @MainActor @Sendable (String) -> Void
    private let failureHandler: @MainActor @Sendable (String) -> Void
    private var state: State = .idle
    private var generation = UUID()
    private var preparationTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var serverProcess: Process?
    private var serverSCID: UInt32?
    private var forwardedPort: UInt16?
    private var agentForwardedPort: UInt16?
    private var controlSocket: ScrcpyControlSocket?
    private var agentSocket: ClipboardAgentSocket?
    private var agentProcess: Process?
    private var receiveSequence: UInt64 = 1
    private var sendSequence: UInt64 = 1
    private var lastObservedContent: Data?
    private var pendingAgentMessage: ScrcpyClipboardAgentMessage?
    private var injectedEchoes = ScrcpyInjectedClipboardEchoSuppressor(capacity: 16)

    var clipboardEventHandler: (@Sendable (ScrcpyClipboardUpdate) -> Void)?

    init(
        serial: String,
        adb: ADBClient,
        readyHandler: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        failureHandler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.serial = serial
        self.adb = adb
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
                serverProcess = try adb.launch(serial: serial, arguments: configuration.serverArguments)
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

                let agentName = "galaxybridge_clipboard_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
                let agentPort = try await Task.detached(priority: .utility) { [adb, serial] in
                    try adb.forwardAutomatically(serial: serial, socketName: agentName)
                }.value
                agentForwardedPort = agentPort
                agentProcess = try adb.launch(serial: serial, arguments: [
                    "shell",
                    "CLASSPATH=\(ScrcpyLaunchConfiguration.remoteServerPath)",
                    "app_process",
                    "/",
                    "com.genymobile.scrcpy.ClipboardAgent",
                    agentName,
                ])
                try await Task.detached(priority: .utility) { [adb, serial] in
                    try adb.waitForAbstractSocket(serial: serial, socketName: agentName)
                }.value
                guard generation == request, !Task.isCancelled else { throw CancellationError() }
                let clipboardAgent = ClipboardAgentSocket(
                    port: agentPort,
                    readyHandler: {},
                    messageHandler: { [weak self] message in
                        Task { @MainActor in self?.receiveAgent(message, request: request) }
                    },
                    failureHandler: { [weak self] error in
                        Task { @MainActor in self?.fail(request: request, reason: String(describing: error)) }
                    }
                )
                agentSocket = clipboardAgent
                clipboardAgent.start()
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
    func setText(_ value: String) -> Bool {
        guard state == .ready,
              !value.isEmpty,
              value.utf8.count <= ScrcpyDeviceMessageDecoder.maximumClipboardLength,
              let controlSocket
        else { return false }
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
        controlSocket?.send(ScrcpyControlMessage.getClipboard())
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.generation == request, self.state == .ready else { return }
                self.controlSocket?.send(ScrcpyControlMessage.getClipboard())
            }
        }
    }

    private func receive(_ message: ScrcpyDeviceMessage, request: UUID) {
        guard generation == request, state == .ready else { return }
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
        guard generation == request else { return }
        guard state == .ready else {
            if state == .preparing { pendingAgentMessage = message }
            return
        }
        guard message.content != lastObservedContent else { return }
        lastObservedContent = message.content
        if message.kind == .text, !injectedEchoes.shouldForward(message.content) { return }
        let update = ScrcpyClipboardUpdate(
            changeID: ScrcpyClipboardIdentity.changeID(
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
        preparationTask?.cancel()
        preparationTask = nil
        pollTask?.cancel()
        pollTask = nil
        controlSocket?.cancel()
        controlSocket = nil
        agentSocket?.cancel()
        agentSocket = nil
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
