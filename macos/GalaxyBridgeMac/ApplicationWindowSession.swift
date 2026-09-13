#if !GALAXYBRIDGE_APP_STORE
import Combine
import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore

@MainActor
final class ApplicationWindowSession: ObservableObject {
    @Published private(set) var state: ScrcpySessionState = .idle
    @Published private(set) var aspectRatio: CGFloat = 16 / 9
    @Published private(set) var presentationState = ApplicationWindowPresentationState()
    let surface = VideoSurfaceModel()
    let application: ApplicationCatalogItem

    private let scrcpy: ScrcpySession
    var nativeSession: ScrcpySession { scrcpy }
    private let target: ScrcpyApplicationTarget
    private let companionTextHandler: @MainActor (String) -> Bool
    private let companionKeyHandler: @MainActor (Bool, UInt32, UInt32, UInt32) -> Bool
    private let companionClipboardHandler: @MainActor (EnhancedClipboardOperation) -> Bool
    private var reconnectBackoff = ReconnectBackoff()
    private var reconnectTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var resizeDeliveryState = ApplicationWindowResizeDeliveryState()
    private var cancellables = Set<AnyCancellable>()
    private var closed = false

    init(
        application: ApplicationCatalogItem,
        serial: String,
        adb: ADBClient,
        quicSelection: QuicWirelessSelection? = nil,
        companionTextHandler: @escaping @MainActor (String) -> Bool,
        companionKeyHandler: @escaping @MainActor (Bool, UInt32, UInt32, UInt32) -> Bool,
        companionClipboardHandler: @escaping @MainActor (EnhancedClipboardOperation) -> Bool,
        clipboardEventHandler: @escaping @MainActor @Sendable (ScrcpyClipboardUpdate) -> Void,
        freshFramePresentationReceipt: (@MainActor () -> (@MainActor @Sendable () -> Void)?)? = nil
    ) throws {
        self.application = application
        self.companionTextHandler = companionTextHandler
        self.companionKeyHandler = companionKeyHandler
        self.companionClipboardHandler = companionClipboardHandler
        target = try ScrcpyApplicationTarget(packageName: application.packageName)
        scrcpy = ScrcpySession(
            serial: serial,
            adb: adb,
            physicalDisplayPolicy: .leaveUnchanged,
            quicSelection: quicSelection
        )
        surface.freshFramePresentationReceipt = { [weak self] in
            guard let self, !self.closed,
                  let owner = self.scrcpy.nativeOwner, owner.attempt.isAdmitted,
                  let identity = self.scrcpy.applicationDisplayIdentity,
                  let receipt = freshFramePresentationReceipt?() else { return nil }
            return { [weak self, weak owner] in
                guard let self, let owner, !self.closed, owner.attempt.isAdmitted,
                      self.scrcpy.nativeOwner === owner,
                      self.scrcpy.applicationDisplayIdentity == identity else { return }
                receipt()
            }
        }
        scrcpy.controlReadyHandler = { [weak self] in
            guard let self else { return }
            self.handlePresentation(.controlReady)
            self.deliverResize(self.resizeDeliveryState.controlBecameReady())
        }
        scrcpy.clipboardEventHandler = { update in
            Task { @MainActor in clipboardEventHandler(update) }
        }
        scrcpy.ownedDecodedFrameHandler = { [weak self] frame in
            guard let self, !self.closed, frame.isAdmitted else {
                if let trace = frame.trace { trace.collector.finish(trace, reason: .dropped) }
                return
            }
            if let frameAspectRatio = ApplicationWindowVideoGeometry.aspectRatio(
                pixelWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
                pixelHeight: CVPixelBufferGetHeight(frame.pixelBuffer)
            ) {
                self.aspectRatio = frameAspectRatio
            }
            self.surface.present(frame.pixelBuffer, presentationTime: frame.presentationTime,
                                 epoch: frame.epoch, diagnosticTrace: frame.trace)
            self.handlePresentation(.firstDecodedFrame)
        }
        scrcpy.$state.sink { [weak self] state in
            guard let self else { return }
            self.state = state
            switch state {
            case .preparing:
                // ScrcpySession may retry H.264 internally without another
                // ApplicationWindowSession.start() call. Treat every prepare
                // attempt as a fresh pair of control/video readiness gates.
                self.resizeDeliveryState.beginConnection()
            case .streaming:
                self.reconnectBackoff = ReconnectBackoff()
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
            case .failed:
                self.scheduleReconnect()
            default:
                break
            }
        }.store(in: &cancellables)
        scrcpy.$videoSize.sink { [weak self] size in
            guard let self, size.width > 0, size.height > 0 else { return }
            self.deliverResize(self.resizeDeliveryState.videoBecameReady())
        }.store(in: &cancellables)
    }

    func start() {
        guard !closed else { return }
        var next = presentationState
        next.reset()
        presentationState = next
        resizeDeliveryState.beginConnection()
        let initialSize = resizeDeliveryState.launchSize(
            fallback: ApplicationWindowPixelSize(width: 1_920, height: 1_080)
        )
        scrcpy.start(
            captureTarget: .virtualDisplay(width: initialSize.width, height: initialSize.height, dpi: 420),
            applicationTarget: target
        )
    }

    func updateContentGeometry(contentSize: CGSize, backingScale: CGFloat) {
        guard !closed,
              let pixelSize = ApplicationWindowPixelSize(
                  contentSize: contentSize,
                  backingScale: backingScale
              ),
              let revision = resizeDeliveryState.observe(pixelSize)
        else { return }

        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .milliseconds(ApplicationWindowResizeDeliveryState.quietPeriodMilliseconds)
                )
            } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.resizeTask = nil
            self.deliverResize(self.resizeDeliveryState.quietPeriodElapsed(revision: revision))
        }
    }

    func close() {
        closed = true
        surface.freshFramePresentationReceipt = nil
        scrcpy.ownedDecodedFrameHandler = nil
        resizeTask?.cancel()
        resizeTask = nil
        resizeDeliveryState.close()
        reconnectTask?.cancel()
        reconnectTask = nil
        scrcpy.stop()
    }

    func closeAndWaitForCleanup() async {
        closed = true
        surface.freshFramePresentationReceipt = nil
        scrcpy.ownedDecodedFrameHandler = nil
        resizeTask?.cancel()
        resizeTask = nil
        resizeDeliveryState.close()
        reconnectTask?.cancel()
        reconnectTask = nil
        await scrcpy.stopAndWaitForCleanup()
    }

    func sendTouch(
        action: ScrcpyMotionAction,
        normalizedX: Double,
        normalizedY: Double,
        pointerID: UInt64 = ScrcpyControlMessage.virtualFingerPointerID
    ) {
        guard scrcpy.videoSize != .zero else { return }
        let dimensions = videoDimensions
        let x = Int32(clamping: Int(clamp(normalizedX, to: 0 ... 1) * Double(max(0, Int(dimensions.width) - 1))))
        let y = Int32(clamping: Int(clamp(normalizedY, to: 0 ... 1) * Double(max(0, Int(dimensions.height) - 1))))
        let released = action == .up || action == .cancel
        scrcpy.sendControl(
            ScrcpyControlMessage.virtualFingerTouch(
                action: action,
                pointerID: pointerID,
                x: x,
                y: y,
                screenWidth: dimensions.width,
                screenHeight: dimensions.height,
                pressure: released ? 0 : 1
            )
        )
    }

    func sendScroll(x: Double, y: Double, horizontal: Double, vertical: Double) {
        guard scrcpy.videoSize != .zero else { return }
        let dimensions = videoDimensions
        scrcpy.sendControl(
            ScrcpyControlMessage.scroll(
                x: Int32(clamping: Int(clamp(x, to: 0 ... 1) * Double(max(0, Int(dimensions.width) - 1)))),
                y: Int32(clamping: Int(clamp(y, to: 0 ... 1) * Double(max(0, Int(dimensions.height) - 1)))),
                screenWidth: dimensions.width,
                screenHeight: dimensions.height,
                horizontal: horizontal,
                vertical: vertical
            )
        )
    }

    func sendPinch(action: ScrcpyMotionAction, x: Double, y: Double, scale: Double) {
        let radius = clamp(0.08 * clamp(scale, to: 0.1 ... 4), to: 0.01 ... 0.32)
        sendTouch(
            action: action,
            normalizedX: x - radius,
            normalizedY: y,
            pointerID: ScrcpyControlMessage.virtualFingerPointerID
        )
        sendTouch(
            action: action,
            normalizedX: x + radius,
            normalizedY: y,
            pointerID: ScrcpyControlMessage.virtualSecondFingerPointerID
        )
    }

    func sendKey(action: ScrcpyKeyAction, keycode: UInt32, repeatCount: UInt32, modifiers: UInt32) {
        EnhancedKeyInputDispatcher.send(
            isDown: action == .down,
            keycode: keycode,
            repeatCount: repeatCount,
            modifiers: modifiers,
            companion: companionKeyHandler,
            scrcpy: { [scrcpy] in
                scrcpy.sendKeyboardControl(
                    ScrcpyControlMessage.keycode(
                        action: action,
                        androidKeycode: keycode,
                        repeatCount: repeatCount,
                        metaState: modifiers
                    )
                )
            }
        )
    }

    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        let boundedText = String(text.prefix(4_096))
        EnhancedTextInputDispatcher.send(
            boundedText,
            context: .independentApplicationDisplay,
            companion: companionTextHandler,
            scrcpy: scrcpy.sendVirtualDisplayText
        )
    }

    @discardableResult
    func requestRemoteClipboard(_ command: RemoteClipboardCommand) -> Bool {
        let operation: EnhancedClipboardOperation = command == .cut ? .cut : .copy
        EnhancedClipboardRequestDispatcher.request(
            operation,
            companion: companionClipboardHandler,
            scrcpy: { [scrcpy] request in
                switch request {
                case .readCurrent:
                    scrcpy.requestClipboard(copyKey: .none, afterExternalCopy: true)
                case .atomicCopy:
                    scrcpy.requestClipboard(copyKey: .copy)
                case .atomicCut:
                    scrcpy.requestClipboard(copyKey: .cut)
                }
            }
        )
        return true
    }

    func sendNavigation(_ keycode: UInt32) {
        sendKey(action: .down, keycode: keycode, repeatCount: 0, modifiers: 0)
        sendKey(action: .up, keycode: keycode, repeatCount: 0, modifiers: 0)
    }

    private var videoDimensions: (width: UInt16, height: UInt16) {
        (
            UInt16(clamping: Int(scrcpy.videoSize.width)),
            UInt16(clamping: Int(scrcpy.videoSize.height))
        )
    }

    private func deliverResize(_ size: ApplicationWindowPixelSize?) {
        guard let size else { return }
        scrcpy.sendControl(
            ScrcpyControlMessage.resizeDisplay(width: size.width, height: size.height)
        )
    }

    private func scheduleReconnect() {
        guard !closed, reconnectTask == nil else { return }
        let delay = reconnectBackoff.nextDelay()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !self.closed else { return }
            self.reconnectTask = nil
            self.start()
        }
    }

    private func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func handlePresentation(_ event: ApplicationWindowPresentationEvent) {
        var next = presentationState
        next.handle(event)
        if next != presentationState { presentationState = next }
    }
}

private struct ApplicationWindowPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}
#endif
