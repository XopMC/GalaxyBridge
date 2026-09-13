import AppKit
import GalaxyBridgeCore
import OSLog
import SwiftUI

enum RemoteClipboardCommand: Equatable {
    case copy
    case cut
}

struct DeviceInputSurface: NSViewRepresentable {
    let aspectRatio: CGFloat
    let contentInset: CGFloat
    var videoContentMode: ContentMode = .fit
    var preciseScrollUsesTouch = true
    let onTouch: (ScrcpyMotionAction, Double, Double) -> Void
    let onTrackpadTouch: (ScrcpyMotionAction, Double, Double) -> Void
    let onScroll: (Double, Double, Double, Double) -> Void
    let onPinch: (ScrcpyMotionAction, Double, Double, Double) -> Void
    let onKey: (ScrcpyKeyAction, UInt32, UInt32, UInt32) -> Void
    let onText: (String) -> Void
    let onNavigation: (UInt32) -> Void
    var onClipboardCommand: (RemoteClipboardCommand) -> Bool = { _ in false }
    var onTopEdgeHover: (Bool) -> Void = { _ in }
    var primaryInputReceipt: ((Double) -> PrimaryMediaTrace?)? = nil
    var primaryTouch: ((ScrcpyMotionAction, Double, Double, PrimaryMediaTrace?) -> Void)? = nil
    var primaryTrackpadTouch: ((ScrcpyMotionAction, Double, Double, PrimaryMediaTrace?) -> Void)? = nil

    func makeNSView(context: Context) -> DeviceInputNSView {
        let view = DeviceInputNSView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ nsView: DeviceInputNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DeviceInputNSView) {
        if aspectRatio.isFinite, aspectRatio > 0 {
            view.videoAspectRatio = aspectRatio
        }
        view.contentInset = max(0, contentInset)
        view.videoFillsBounds = videoContentMode == .fill
        view.preciseScrollUsesTouch = preciseScrollUsesTouch
        view.onTouch = onTouch
        view.onTrackpadTouch = onTrackpadTouch
        view.onScroll = onScroll
        view.onPinch = onPinch
        view.onKey = onKey
        view.onText = onText
        view.onNavigation = onNavigation
        view.onClipboardCommand = onClipboardCommand
        view.onTopEdgeHover = onTopEdgeHover
        view.primaryInputReceipt = primaryInputReceipt
        view.primaryTouch = primaryTouch
        view.primaryTrackpadTouch = primaryTrackpadTouch
    }
}

struct TrackpadMotionFilter {
    private enum Axis {
        case horizontal
        case vertical
    }

    private var accumulated = CGPoint.zero
    private var lockedAxis: Axis?

    mutating func consume(deltaX: Double, deltaY: Double, renderedSize: CGSize) -> CGPoint {
        guard deltaX.isFinite, deltaY.isFinite, renderedSize.width > 0, renderedSize.height > 0 else {
            return .zero
        }
        accumulated.x += deltaX
        accumulated.y += deltaY

        if lockedAxis == nil {
            let horizontalStrength = abs(accumulated.x)
            let verticalStrength = abs(accumulated.y)
            guard max(horizontalStrength, verticalStrength) >= 3 else { return .zero }
            lockedAxis = horizontalStrength >= verticalStrength ? .horizontal : .vertical
        }

        let gain = 0.65
        switch lockedAxis {
        case .horizontal:
            return CGPoint(x: -deltaX * gain / renderedSize.width, y: 0)
        case .vertical:
            // AppKit physical Y grows upward; the flipped Android surface grows downward.
            return CGPoint(x: 0, y: -deltaY * gain / renderedSize.height)
        case nil:
            return .zero
        }
    }

    mutating func reset() {
        accumulated = .zero
        lockedAxis = nil
    }
}

@MainActor
final class DeviceInputNSView: NSView, @preconcurrency NSTextInputClient {
    private let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "input")
    var videoAspectRatio: CGFloat = 9 / 19.5
    var contentInset: CGFloat = 0
    var videoFillsBounds = false
    var preciseScrollUsesTouch = true
    var onTouch: ((ScrcpyMotionAction, Double, Double) -> Void)?
    var onTrackpadTouch: ((ScrcpyMotionAction, Double, Double) -> Void)?
    var onScroll: ((Double, Double, Double, Double) -> Void)?
    var onPinch: ((ScrcpyMotionAction, Double, Double, Double) -> Void)?
    var onKey: ((ScrcpyKeyAction, UInt32, UInt32, UInt32) -> Void)?
    var onText: ((String) -> Void)?
    var onNavigation: ((UInt32) -> Void)?
    var onClipboardCommand: ((RemoteClipboardCommand) -> Bool)?
    var onTopEdgeHover: ((Bool) -> Void)?
    var primaryInputReceipt: ((Double) -> PrimaryMediaTrace?)?
    var primaryTouch: ((ScrcpyMotionAction, Double, Double, PrimaryMediaTrace?) -> Void)?
    var primaryTrackpadTouch: ((ScrcpyMotionAction, Double, Double, PrimaryMediaTrace?) -> Void)?
    var pasteTextProvider: () -> String? = {
        NSPasteboard.general.string(forType: .string)
    }

    private var activeKeys: [UInt16: (androidKeycode: UInt32, metaState: UInt32)] = [:]
    private var mouseTouchActive = false
    private var mouseTouchPosition = CGPoint(x: 0.5, y: 0.5)
    private var trackpadSequenceActive = false
    private var trackpadTouchActive = false
    private var trackpadTouchPosition = CGPoint(x: 0.5, y: 0.5)
    private var trackpadMotionFilter = TrackpadMotionFilter()
    private var trackpadReleaseWorkItem: DispatchWorkItem?
    private var pinchScale = 1.0
    private var pinchCenter = CGPoint(x: 0.5, y: 0.5)
    private var pinchActive = false
    private var trackingArea: NSTrackingArea?
    private var topEdgeHovered = false
    private var windowObservers: [NSObjectProtocol] = []
    private var preDispatchKeyMonitor: Any?
    private var markedText = NSAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var interpretedKeyEvent: NSEvent?
    private var didHandleInterpretedKeyEvent = false
    private var pendingText = ""
    private var pendingTextFlushTask: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers()
        installPreDispatchKeyMonitor()
        window?.acceptsMouseMovedEvents = true
        guard window?.isKeyWindow == true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            removePreDispatchKeyMonitor()
            removeWindowObservers()
            releaseInput(cancelled: true)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func becomeFirstResponder() -> Bool {
        focusRingType = .none
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseInput(cancelled: true)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let receipt = ProcessInfo.processInfo.systemUptime
        window?.makeFirstResponder(self)
        logger.info("Input focus after pointer down (key: \(self.window?.isKeyWindow == true, privacy: .public), first-responder: \(self.window?.firstResponder === self, privacy: .public))")
        updateTopEdgeHover(with: event)
        let point = normalized(event.locationInWindow)
        if mouseTouchActive { deliverTouch(.cancel, point: mouseTouchPosition, receipt: receipt) }
        mouseTouchActive = true
        mouseTouchPosition = point
        deliverTouch(.down, point: point, receipt: receipt)
    }

    override func mouseDragged(with event: NSEvent) {
        let receipt = ProcessInfo.processInfo.systemUptime
        guard mouseTouchActive else { return }
        let point = normalized(event.locationInWindow)
        mouseTouchPosition = point
        deliverTouch(.move, point: point, receipt: receipt)
    }

    override func mouseUp(with event: NSEvent) {
        let receipt = ProcessInfo.processInfo.systemUptime
        guard mouseTouchActive else { return }
        let point = normalized(event.locationInWindow)
        mouseTouchPosition = point
        deliverTouch(.up, point: point, receipt: receipt)
        mouseTouchActive = false
    }

    override func mouseEntered(with event: NSEvent) {
        if window?.isKeyWindow == true { window?.makeFirstResponder(self) }
        updateTopEdgeHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateTopEdgeHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setTopEdgeHovered(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        flushPendingText()
        onNavigation?(4)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.buttonNumber == 2 {
            flushPendingText()
            onNavigation?(3)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let receipt = ProcessInfo.processInfo.systemUptime
        window?.makeFirstResponder(self)
        let point = normalized(event.locationInWindow)
        guard event.hasPreciseScrollingDeltas else {
            let horizontal = Double(event.scrollingDeltaX)
            let vertical = Double(event.scrollingDeltaY)
            guard abs(horizontal) > 0.001 || abs(vertical) > 0.001 else { return }
            onScroll?(point.x, point.y, horizontal, vertical)
            return
        }

        if event.momentumPhase != [] {
            if trackpadSequenceActive { finishTrackpadGesture(cancelled: false) }
            return
        }

        if event.phase == .began || !trackpadSequenceActive {
            trackpadTouchPosition = CGPoint(
                x: point.x.clamped(to: 0.14 ... 0.86),
                y: point.y.clamped(to: 0.14 ... 0.86)
            )
            trackpadMotionFilter.reset()
            trackpadSequenceActive = true
        }

        if event.phase != .cancelled {
            let physicalDirection = event.isDirectionInvertedFromDevice ? -1.0 : 1.0
            let deltaX = Double(event.scrollingDeltaX) * physicalDirection
            let deltaY = Double(event.scrollingDeltaY) * physicalDirection
            let movement = trackpadMotionFilter.consume(
                deltaX: deltaX,
                deltaY: deltaY,
                renderedSize: renderedRect().size
            )
            if movement != .zero {
                if preciseScrollUsesTouch {
                    if !trackpadTouchActive {
                        trackpadTouchActive = true
                        deliverTouch(.down, point: trackpadTouchPosition, receipt: receipt, trackpad: true)
                    }
                    trackpadTouchPosition.x = (trackpadTouchPosition.x + movement.x).clamped(to: 0.03 ... 0.97)
                    trackpadTouchPosition.y = (trackpadTouchPosition.y + movement.y).clamped(to: 0.03 ... 0.97)
                    deliverTouch(.move, point: trackpadTouchPosition, receipt: receipt, trackpad: true)
                } else {
                    // The Companion mapper uses 0.025 normalized units per scroll unit.
                    onScroll?(point.x, point.y, movement.x / 0.025, movement.y / 0.025)
                }
            }
        }

        if event.phase == .ended {
            finishTrackpadGesture(cancelled: false, receipt: receipt)
        } else if event.phase == .cancelled {
            finishTrackpadGesture(cancelled: true, receipt: receipt)
        } else if event.phase == [] {
            scheduleTrackpadRelease()
        }
    }

    override func magnify(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = normalized(event.locationInWindow)
        switch event.phase {
        case .began:
            finishTrackpadGesture(cancelled: false)
            pinchScale = 1
            pinchCenter = point
            pinchActive = true
            onPinch?(.down, point.x, point.y, pinchScale)
        case .changed:
            pinchScale = (pinchScale * (1 + Double(event.magnification))).clamped(to: 0.1 ... 4)
            onPinch?(.move, pinchCenter.x, pinchCenter.y, pinchScale)
        case .ended:
            onPinch?(.up, pinchCenter.x, pinchCenter.y, pinchScale)
            pinchScale = 1
            pinchActive = false
        case .cancelled:
            onPinch?(.cancel, pinchCenter.x, pinchCenter.y, pinchScale)
            pinchScale = 1
            pinchActive = false
        default:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        logger.info("Input keyDown received (key-code: \(event.keyCode, privacy: .public))")
        if handleCommandShortcut(event) { return }

        // Keep physical control keys down until AppKit delivers keyUp. This
        // preserves key holds/repeat for Enhanced ADB while the same callbacks
        // remain usable by Companion LAN, which acts on the down edge. When an
        // IME composition is active, Cocoa must see the key first so Delete,
        // Escape, arrows, and Return can edit or commit the marked text.
        if !hasMarkedText(), let keycode = Self.androidKeycode(for: event.keyCode) {
            flushPendingText()
            let metaState = Self.androidMetaState(for: event.modifierFlags)
            activeKeys[event.keyCode] = (keycode, metaState)
            onKey?(.down, keycode, event.isARepeat ? 1 : 0, metaState)
            return
        }

        interpretedKeyEvent = event
        didHandleInterpretedKeyEvent = false
        interpretKeyEvents([event])
        interpretedKeyEvent = nil
        if didHandleInterpretedKeyEvent { return }

        // An unknown function key can bypass Cocoa's key bindings. Keep the
        // raw fallback so navigation never regresses when a custom key map is
        // installed, while printable text always goes through Text Input
        // Services first (dead keys, composed text and IMEs included).
        if let keycode = Self.androidKeycode(for: event.keyCode) {
            flushPendingText()
            let metaState = Self.androidMetaState(for: event.modifierFlags)
            activeKeys[event.keyCode] = (keycode, metaState)
            onKey?(.down, keycode, event.isARepeat ? 1 : 0, metaState)
            return
        }
        guard let text = event.characters, !text.isEmpty else { return }
        enqueueText(text)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        didHandleInterpretedKeyEvent = true
        let wasComposing = hasMarkedText()
        discardMarkedText()
        let text = Self.plainText(from: string)
        guard !text.isEmpty else { return }
        if wasComposing {
            flushPendingText()
            onText?(text)
        } else {
            enqueueText(text)
        }
    }

    override func doCommand(by selector: Selector) {
        let command = NSStringFromSelector(selector)
        if command == "cancelOperation:", hasMarkedText() {
            didHandleInterpretedKeyEvent = true
            discardMarkedText()
            return
        }

        guard let mapping = Self.androidCommand(for: command) else { return }
        didHandleInterpretedKeyEvent = true
        flushPendingText()
        if let navigation = mapping.navigation {
            onNavigation?(navigation)
            return
        }

        var metaState = Self.androidMetaState(for: interpretedKeyEvent?.modifierFlags ?? [])
        if mapping.modifiesSelection {
            metaState |= 0x0000_0001 | 0x0000_0040
        }
        sendKeyPair(keycode: mapping.keycode, metaState: metaState)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        didHandleInterpretedKeyEvent = true
        if !hasMarkedText() { flushPendingText() }
        markedText = Self.attributedText(from: string)
        let length = markedText.length
        let location = min(selectedRange.location == NSNotFound ? length : selectedRange.location, length)
        let selectionLength = min(selectedRange.length, length - location)
        markedSelection = NSRange(location: location, length: selectionLength)
    }

    func unmarkText() {
        didHandleInterpretedKeyEvent = true
        let text = markedText.string
        discardMarkedText()
        guard !text.isEmpty else { return }
        flushPendingText()
        onText?(text)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location <= markedText.length else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let bounded = NSRange(
            location: range.location,
            length: min(range.length, markedText.length - range.location)
        )
        actualRange?.pointee = bounded
        return markedText.attributedSubstring(from: bounded)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = selectedRange()
        guard let window else { return .zero }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let anchor = bounds.contains(pointer)
            ? pointer
            : CGPoint(x: bounds.midX, y: bounds.midY)
        let localRect = NSRect(x: anchor.x, y: anchor.y, width: 1, height: 22)
        return window.convertToScreen(convert(localRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        selectedRange().location
    }

    override func keyUp(with event: NSEvent) {
        guard let active = activeKeys.removeValue(forKey: event.keyCode) else { return }
        onKey?(.up, active.androidKeycode, 0, active.metaState)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handlePreDispatchKeyEvent(event)
    }

    func handlePreDispatchKeyEvent(_ event: NSEvent) -> Bool {
        logger.info("Input pre-dispatch keyDown received (key-code: \(event.keyCode, privacy: .public))")
        if handleCommandShortcut(event) { return true }
        return handlePreDispatchPrintableText(
            characters: event.characters,
            modifierRawValue: event.modifierFlags.rawValue
        )
    }

    private func handlePreDispatchPrintableText(
        characters: String?,
        modifierRawValue: UInt
    ) -> Bool {
        let modifiers = NSEvent.ModifierFlags(rawValue: modifierRawValue)
            .intersection(.deviceIndependentFlagsMask)
        guard !hasMarkedText(),
              !modifiers.contains(.command),
              !modifiers.contains(.control),
              let text = characters,
              !text.isEmpty,
              text.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && !(0xF700 ... 0xF8FF).contains(scalar.value)
              })
        else { return false }
        window?.makeFirstResponder(self)
        enqueueText(text)
        return true
    }

    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }
        if event.keyCode == 9,
           let onText,
           let clipboardText = pasteTextProvider(),
           !clipboardText.isEmpty {
            flushPendingText()
            onText(clipboardText)
            return true
        }
        let remoteClipboardCommand: RemoteClipboardCommand? = switch event.keyCode {
        case 8: .copy
        case 7: .cut
        default: nil
        }
        if let remoteClipboardCommand {
            flushPendingText()
            if onClipboardCommand?(remoteClipboardCommand) == true { return true }
        }
        guard
              let keycode = Self.androidShortcutKeycode(for: event.keyCode)
        else { return false }
        flushPendingText()
        let controlMeta: UInt32 = 0x1000 | 0x2000
        onKey?(.down, keycode, event.isARepeat ? 1 : 0, controlMeta)
        onKey?(.up, keycode, 0, controlMeta)
        return true
    }

    private func finishTrackpadGesture(cancelled: Bool, receipt: Double? = nil) {
        trackpadReleaseWorkItem?.cancel()
        trackpadReleaseWorkItem = nil
        if trackpadTouchActive {
            deliverTouch(cancelled ? .cancel : .up, point: trackpadTouchPosition, receipt: receipt, trackpad: true)
        }
        trackpadTouchActive = false
        trackpadSequenceActive = false
        trackpadMotionFilter.reset()
    }

    private func deliverTouch(_ action: ScrcpyMotionAction, point: CGPoint, receipt: Double?, trackpad: Bool = false) {
        let measured = trackpad ? primaryTrackpadTouch : primaryTouch
        if let measured {
            // Keep UP/CANCEL in protocol order, but do not treat them as the
            // cause of the fixture's ACTION_DOWN visual response. MOVE remains
            // measurable so continuous gestures still produce latency probes.
            let trace = action == .up || action == .cancel
                ? nil
                : receipt.flatMap { primaryInputReceipt?($0) }
            measured(action, point.x, point.y, trace)
        } else if trackpad {
            onTrackpadTouch?(action, point.x, point.y)
        } else {
            onTouch?(action, point.x, point.y)
        }
    }

    private func scheduleTrackpadRelease() {
        trackpadReleaseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishTrackpadGesture(cancelled: false) }
        trackpadReleaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80), execute: work)
    }

    private func installWindowObservers() {
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let activatedObject = note.object as AnyObject? else { return }
                let activatedWindowID = ObjectIdentifier(activatedObject)
                MainActor.assumeIsolated { [weak self] in
                    guard let self,
                          let phoneWindow = self.window
                    else { return }
                    let activatedPhone = ObjectIdentifier(phoneWindow) == activatedWindowID
                    let activatedHeader = phoneWindow.childWindows?.contains {
                        ObjectIdentifier($0) == activatedWindowID
                    } == true
                    guard activatedPhone || activatedHeader else { return }
                    if activatedHeader { phoneWindow.makeKey() }
                    phoneWindow.makeFirstResponder(self)
                }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.releaseInput(cancelled: true) }
            },
        ]
    }

    private func installPreDispatchKeyMonitor() {
        removePreDispatchKeyMonitor()
        preDispatchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let eventWindowNumber = event.windowNumber
            let consumed: Bool = MainActor.assumeIsolated {
                guard self.window?.windowNumber == eventWindowNumber,
                      self.window?.firstResponder === self
                else { return false }
                return self.handlePreDispatchKeyEvent(event)
            }
            return consumed ? nil : event
        }
    }

    private func removePreDispatchKeyMonitor() {
        if let preDispatchKeyMonitor {
            NSEvent.removeMonitor(preDispatchKeyMonitor)
            self.preDispatchKeyMonitor = nil
        }
    }

    private func removeWindowObservers() {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers.removeAll()
    }

    private func releaseInput(cancelled: Bool) {
        flushPendingText()
        if mouseTouchActive {
            onTouch?(cancelled ? .cancel : .up, mouseTouchPosition.x, mouseTouchPosition.y)
            mouseTouchActive = false
        }
        finishTrackpadGesture(cancelled: cancelled)
        if pinchActive {
            onPinch?(cancelled ? .cancel : .up, pinchCenter.x, pinchCenter.y, pinchScale)
            pinchActive = false
            pinchScale = 1
        }
        for active in activeKeys.values {
            onKey?(.up, active.androidKeycode, 0, active.metaState)
        }
        activeKeys.removeAll()
        discardMarkedText()
        inputContext?.discardMarkedText()
    }

    private func discardMarkedText() {
        markedText = NSAttributedString()
        markedSelection = NSRange(location: 0, length: 0)
    }

    private func enqueueText(_ text: String) {
        guard !text.isEmpty else { return }
        pendingText.append(text)
        pendingTextFlushTask?.cancel()
        pendingTextFlushTask = Task { @MainActor [weak self] in
            do {
                // Coalesce the inter-key spacing AppKit uses for real hardware
                // typing. A single scrcpy clipboard/paste transaction is
                // lossless; several overlapping Android clipboard updates are
                // not. Keep committed text within the 80 ms input budget;
                // pointer, navigation and held-key events remain immediate.
                try await Task.sleep(for: .milliseconds(75))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.flushPendingText()
        }
    }

    private func flushPendingText() {
        pendingTextFlushTask?.cancel()
        pendingTextFlushTask = nil
        guard !pendingText.isEmpty else { return }
        let text = pendingText
        pendingText.removeAll(keepingCapacity: true)
        logger.info("Dispatching committed text (bytes: \(text.utf8.count, privacy: .public))")
        onText?(text)
    }

    private func sendKeyPair(keycode: UInt32, metaState: UInt32) {
        onKey?(.down, keycode, interpretedKeyEvent?.isARepeat == true ? 1 : 0, metaState)
        onKey?(.up, keycode, 0, metaState)
    }

    private func updateTopEdgeHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setTopEdgeHovered(bounds.contains(point) && point.y <= 10)
    }

    private func setTopEdgeHovered(_ hovered: Bool) {
        guard hovered != topEdgeHovered else { return }
        topEdgeHovered = hovered
        onTopEdgeHover?(hovered)
    }

    private func normalized(_ windowPoint: CGPoint) -> CGPoint {
        let point = convert(windowPoint, from: nil)
        let rendered = renderedRect()
        return CGPoint(
            x: ((point.x - rendered.origin.x) / rendered.width).clamped(to: 0 ... 1),
            y: ((point.y - rendered.origin.y) / rendered.height).clamped(to: 0 ... 1)
        )
    }

    private func renderedRect() -> CGRect {
        let available = CGSize(
            width: max(1, bounds.width - contentInset * 2),
            height: max(1, bounds.height - contentInset * 2)
        )
        let rendered: CGSize
        let containerAspectRatio = available.width / available.height
        if videoFillsBounds {
            if containerAspectRatio > videoAspectRatio {
                rendered = CGSize(width: available.width, height: available.width / videoAspectRatio)
            } else {
                rendered = CGSize(width: available.height * videoAspectRatio, height: available.height)
            }
        } else if containerAspectRatio > videoAspectRatio {
            rendered = CGSize(width: available.height * videoAspectRatio, height: available.height)
        } else {
            rendered = CGSize(width: available.width, height: available.width / videoAspectRatio)
        }
        let origin = CGPoint(x: (bounds.width - rendered.width) / 2, y: (bounds.height - rendered.height) / 2)
        return CGRect(origin: origin, size: rendered)
    }

    private static func androidMetaState(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.shift) { result |= 0x0000_0001 | 0x0000_0040 }
        if flags.contains(.option) { result |= 0x0000_0002 | 0x0000_0010 }
        if flags.contains(.control) || flags.contains(.command) { result |= 0x0000_1000 | 0x0000_2000 }
        return result
    }

    private static func androidKeycode(for macKeycode: UInt16) -> UInt32? {
        switch macKeycode {
        case 36, 76: 66 // return / keypad enter
        case 48: 61 // tab
        case 51: 67 // delete
        case 53: 4 // escape -> Android back
        case 115: 122 // move home
        case 116: 92 // page up
        case 117: 112 // forward delete
        case 119: 123 // move end
        case 121: 93 // page down
        case 123: 21 // left
        case 124: 22 // right
        case 125: 20 // down
        case 126: 19 // up
        default: nil
        }
    }

    private static func androidShortcutKeycode(for macKeycode: UInt16) -> UInt32? {
        switch macKeycode {
        case 0: 29 // A
        case 8: 31 // C
        case 9: 50 // V
        case 7: 52 // X
        case 6: 54 // Z
        default: nil
        }
    }

    private static func attributedText(from value: Any) -> NSAttributedString {
        if let attributed = value as? NSAttributedString { return attributed }
        if let string = value as? String { return NSAttributedString(string: string) }
        if let string = value as? NSString { return NSAttributedString(string: string as String) }
        return NSAttributedString(string: String(describing: value))
    }

    private static func plainText(from value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        return String(describing: value)
    }

    private struct AndroidTextCommand {
        let keycode: UInt32
        var navigation: UInt32?
        var modifiesSelection = false
    }

    private static func androidCommand(for selector: String) -> AndroidTextCommand? {
        let modifiesSelection = selector.contains("AndModifySelection:")
        let keycode: UInt32?
        switch selector {
        case "insertNewline:", "insertLineBreak:", "insertParagraphSeparator:":
            keycode = 66
        case "insertTab:", "insertTabIgnoringFieldEditor:", "insertBacktab:":
            keycode = 61
        case "deleteBackward:", "deleteWordBackward:", "deleteToBeginningOfLine:":
            keycode = 67
        case "deleteForward:", "deleteWordForward:", "deleteToEndOfLine:":
            keycode = 112
        case "moveLeft:", "moveBackward:",
             "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:",
             "moveWordBackward:", "moveWordBackwardAndModifySelection:":
            keycode = 21
        case "moveRight:", "moveForward:",
             "moveRightAndModifySelection:", "moveForwardAndModifySelection:",
             "moveWordForward:", "moveWordForwardAndModifySelection:":
            keycode = 22
        case "moveUp:", "moveUpAndModifySelection:":
            keycode = 19
        case "moveDown:", "moveDownAndModifySelection:":
            keycode = 20
        case "moveToBeginningOfLine:", "moveToBeginningOfParagraph:", "moveToBeginningOfDocument:",
             "moveToBeginningOfLineAndModifySelection:", "moveToBeginningOfParagraphAndModifySelection:",
             "moveToBeginningOfDocumentAndModifySelection:":
            keycode = 122
        case "moveToEndOfLine:", "moveToEndOfParagraph:", "moveToEndOfDocument:",
             "moveToEndOfLineAndModifySelection:", "moveToEndOfParagraphAndModifySelection:",
             "moveToEndOfDocumentAndModifySelection:":
            keycode = 123
        case "pageUp:", "pageUpAndModifySelection:":
            keycode = 92
        case "pageDown:", "pageDownAndModifySelection:":
            keycode = 93
        case "cancelOperation:":
            return AndroidTextCommand(keycode: 0, navigation: 4)
        default:
            keycode = nil
        }
        guard let keycode else { return nil }
        return AndroidTextCommand(keycode: keycode, navigation: nil, modifiesSelection: modifiesSelection)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
