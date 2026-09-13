import AppKit
import GalaxyBridgeCore
import SwiftUI

struct PresentedDeviceMirror: View {
    let lease: UUID
    @ObservedObject var model: AppModel

    var body: some View {
        if let device = model.row(id: model.primaryMirrorDeviceID(for: lease)) {
            DeviceMirrorWindow(device: device)
                .environmentObject(model)
        } else {
            ContentUnavailableView("NO_DEVICE", systemImage: "iphone.slash")
        }
    }
}

@MainActor
private final class MirrorHeaderVisibilityModel: ObservableObject {
    @Published private(set) var isVisible: Bool
    private var topEdgeHovered = false
    private var headerHovered = false
    private var hideTask: Task<Void, Never>?

    init(initiallyVisible: Bool) {
        isVisible = initiallyVisible
    }

    func topEdgeChanged(_ hovering: Bool) {
        topEdgeHovered = hovering
        reconcile()
    }

    func headerChanged(_ hovering: Bool) {
        headerHovered = hovering
        reconcile()
    }

    private func reconcile() {
        hideTask?.cancel()
        hideTask = nil
        if topEdgeHovered || headerHovered {
            isVisible = true
            return
        }
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard let self, !self.topEdgeHovered, !self.headerHovered else { return }
            self.isVisible = false
            self.hideTask = nil
        }
    }
}

struct DeviceMirrorWindow: View {
    @EnvironmentObject private var model: AppModel
    let device: DeviceRow
    @StateObject private var headerVisibility = MirrorHeaderVisibilityModel(initiallyVisible: false)
    @State private var isPinned = false
    @StateObject private var windowTarget = MirrorWindowTarget()
    private let resizeAcquisitionThickness = MirrorResizeAcquisitionPolicy.externalHaloWidth

    private var screenAspectRatio: CGFloat {
        max(0.25, min(2.5, model.videoAspectRatios[device.id] ?? (9 / 19.5)))
    }

    var body: some View {
        ScreenSurface(
            device: device,
            showsControls: false,
            contentInset: 0,
            videoContentMode: .fill,
            onTopEdgeHover: headerVisibility.topEdgeChanged
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .ignoresSafeArea()
        .background(
            DeviceWindowConfigurator(
                title: device.name,
                contentAspectRatio: screenAspectRatio,
                resizeAcquisitionThickness: resizeAcquisitionThickness,
                cornerArmLength: MirrorResizeAcquisitionPolicy.cornerArmLength,
                isPinned: isPinned,
                showsHeader: headerVisibility.isVisible,
                windowTarget: windowTarget,
                headerContent: headerPanelContent
            )
        )
        .frame(minWidth: 280)
    }

    private var headerPanelContent: AnyView {
        AnyView(
            VStack(spacing: 0) {
                MirrorHoverHeader(device: device, isPinned: $isPinned)
                    .environmentObject(model)
                    .environmentObject(windowTarget)
                Color.clear.frame(height: 8)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                headerVisibility.headerChanged(hovering)
            }
            .applicationLanguageLayout()
        )
    }
}

private struct MirrorHoverHeader: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var windowTarget: MirrorWindowTarget
    let device: DeviceRow
    @Binding var isPinned: Bool

    private var primaryControls: [MirrorHeaderControlID] {
        MirrorHeaderControlID.primaryControls(enhanced: device.transport != .companionLAN)
    }

    var body: some View {
        ZStack {
            WindowDragHandle()
            HStack(spacing: 3) {
                windowButton(color: .red, help: "CLOSE") { perform(.close) }
                windowButton(color: .yellow, help: "MINIMIZE") { perform(.minimize) }
                windowButton(color: .green, help: "ZOOM") { perform(.zoom) }
                Spacer()
            }
            .padding(.leading, 12)

            HStack(spacing: MirrorHeaderLayout.controlPitch - MirrorHeaderLayout.controlDiameter) {
                ForEach(primaryControls) { controlID in
                    primaryControl(controlID)
                }
            }
            .frame(width: MirrorHeaderLayout.controlGroupWidth(count: primaryControls.count))
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    @ViewBuilder
    private func primaryControl(_ controlID: MirrorHeaderControlID) -> some View {
        if controlID == .displayTarget {
            Menu {
                ForEach(
                    model.enhancedDisplaysByDevice[device.id] ?? [ScrcpyDisplay(id: 0, width: nil, height: nil)],
                    id: \.id
                ) { display in
                    Button {
                        model.selectCaptureTarget(deviceID: device.id, target: .display(id: display.id))
                    } label: {
                        Text(displayLabel(display))
                    }
                }
                Divider()
                Button("VIRTUAL_DISPLAY_1080P") {
                    model.selectCaptureTarget(
                        deviceID: device.id,
                        target: .virtualDisplay(width: 1_920, height: 1_080, dpi: 420)
                    )
                }
            } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(
                        width: MirrorHeaderLayout.controlDiameter,
                        height: MirrorHeaderLayout.controlDiameter
                    )
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .focusable(false)
            .help("DISPLAY_TARGET")
        } else {
            control(controlHelp(controlID), symbol: controlSymbol(controlID)) {
                perform(controlID)
            }
        }
    }

    private func control(_ help: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(
                    width: MirrorHeaderLayout.controlDiameter,
                    height: MirrorHeaderLayout.controlDiameter
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }

    private func controlHelp(_ controlID: MirrorHeaderControlID) -> LocalizedStringKey {
        switch controlID {
        case .back: "BACK"
        case .home: "HOME"
        case .recents: "RECENTS"
        case .pin: isPinned ? "UNPIN_WINDOW" : "PIN_WINDOW"
        case .record: "RECORD_SCREEN"
        case .displayTarget: "DISPLAY_TARGET"
        case .rotate: "ROTATE"
        case .screenOff: "SCREEN_OFF"
        case .screenOn: "SCREEN_ON"
        case .close: "CLOSE"
        case .minimize: "MINIMIZE"
        case .zoom: "ZOOM"
        }
    }

    private func controlSymbol(_ controlID: MirrorHeaderControlID) -> String {
        switch controlID {
        case .back: "chevron.backward"
        case .home: "circle"
        case .recents: "square.on.square"
        case .pin: isPinned ? "pin.fill" : "pin"
        case .record: model.recordingDeviceIDs.contains(device.id) ? "stop.circle.fill" : "record.circle"
        case .displayTarget: "rectangle.on.rectangle"
        case .rotate: "rotate.right"
        case .screenOff: "moon.fill"
        case .screenOn: "sun.max.fill"
        case .close, .minimize, .zoom: "circle.fill"
        }
    }

    private func perform(_ controlID: MirrorHeaderControlID) {
        switch MirrorHeaderActionRouting.effect(for: controlID) {
        case .closeWindow:
            viewerWindow?.close()
        case .minimizeWindow:
            viewerWindow?.miniaturize(nil)
        case .toggleWindowZoom:
            windowTarget.toggleZoom()
        case let .androidKeycode(keycode):
            model.sendNavigation(deviceID: device.id, keycode: keycode)
        case .togglePin:
            isPinned.toggle()
        case .toggleRecording:
            model.toggleRecording(deviceID: device.id)
        case .presentDisplayMenu:
            break
        case .rotateDevice:
            model.rotateDevice(deviceID: device.id)
        case let .setDisplayPower(on):
            model.setDisplayPower(deviceID: device.id, on: on)
        }
    }

    private func displayLabel(_ display: ScrcpyDisplay) -> String {
        UserFacingText.displayName(id: display.id, width: display.width, height: display.height)
    }

    private func windowButton(color: Color, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay { Circle().strokeBorder(.black.opacity(0.16), lineWidth: 0.5) }
                .frame(width: 18, height: MirrorHeaderLayout.controlDiameter)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }

    private var viewerWindow: NSWindow? {
        windowTarget.window
    }
}

@MainActor
private final class MirrorWindowTarget: ObservableObject {
    weak var window: NSWindow?
    private var zoomState = MirrorWindowZoomState()

    func toggleZoom() {
        guard let window,
              let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let target = zoomState.toggledFrame(
            currentFrame: window.frame,
            visibleFrame: visibleFrame,
            headerClearance: 48
        )
        window.setFrame(target, display: true, animate: true)
        window.makeKey()
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override func mouseDown(with event: NSEvent) {
            MirrorWindowDragTarget.resolve(from: window)?.performDrag(with: event)
        }
    }
}

private struct DeviceWindowConfigurator: NSViewRepresentable {
    let title: String
    let contentAspectRatio: CGFloat
    let resizeAcquisitionThickness: CGFloat
    let cornerArmLength: CGFloat
    let isPinned: Bool
    let showsHeader: Bool
    let windowTarget: MirrorWindowTarget
    let headerContent: AnyView

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        weak var window: NSWindow?
        var appliedAspectRatio: CGFloat?
        var resizeAcquisitionThickness = MirrorResizeAcquisitionPolicy.externalHaloWidth
        var cornerArmLength = MirrorResizeAcquisitionPolicy.cornerArmLength
        private var pendingAspectRatio: CGFloat?
        private var resizeActivity = MirrorResizeActivity()
        private var baseCollectionBehavior: NSWindow.CollectionBehavior?
        private weak var observedWindow: NSWindow?
        private var panel: NSPanel?
        private var hostingView: NSHostingView<AnyView>?
        private var resizePanels: [ExternalCornerResizePanel] = []

        func updateHeader(
            parent: NSWindow,
            content: AnyView,
            isVisible: Bool,
            isPinned: Bool
        ) {
            observe(parent)
            let panel = headerPanel(content: content)
            hostingView?.rootView = content
            panel.level = isPinned ? .floating : parent.level
            panel.collectionBehavior = MirrorWindowPinPolicy.collectionBehavior(
                base: [.fullScreenAuxiliary],
                isPinned: isPinned
            )
            updatePanelFrame()

            if isVisible {
                if panel.parent !== parent {
                    panel.parent?.removeChildWindow(panel)
                    parent.addChildWindow(panel, ordered: .above)
                }
                panel.orderFront(nil)
            } else {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        }

        func tearDown() {
            NotificationCenter.default.removeObserver(self)
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            panel = nil
            hostingView = nil
            for resizePanel in resizePanels {
                resizePanel.parent?.removeChildWindow(resizePanel)
                resizePanel.orderOut(nil)
            }
            resizePanels.removeAll()
            observedWindow = nil
            pendingAspectRatio = nil
            resizeActivity.endManualResize()
            baseCollectionBehavior = nil
        }

        func captureBaseCollectionBehavior(from window: NSWindow) {
            if baseCollectionBehavior == nil { baseCollectionBehavior = window.collectionBehavior }
        }

        func updatePinPolicy(for window: NSWindow, isPinned: Bool) {
            captureBaseCollectionBehavior(from: window)
            window.collectionBehavior = MirrorWindowPinPolicy.collectionBehavior(
                base: baseCollectionBehavior ?? [],
                isPinned: isPinned
            )
            window.level = MirrorWindowPinPolicy.level(isPinned: isPinned)
            for resizePanel in resizePanels {
                resizePanel.level = window.level
                resizePanel.collectionBehavior = window.collectionBehavior
            }
        }

        func updateResizePanels(
            parent: NSWindow,
            aspectRatio: CGFloat,
            thickness: CGFloat,
            armLength: CGFloat
        ) {
            resizeAcquisitionThickness = max(1, thickness)
            cornerArmLength = max(resizeAcquisitionThickness, armLength)
            let zones = MirrorWindowGeometry.externalCornerAcquisitionZones(
                around: parent.frame,
                thickness: resizeAcquisitionThickness,
                armLength: cornerArmLength
            )
            if resizePanels.count != zones.count {
                for panel in resizePanels {
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                }
                resizePanels = zones.map { ExternalCornerResizePanel(edges: $0.edges) }
            }

            for (panel, zone) in zip(resizePanels, zones) {
                panel.resizeView.targetWindow = parent
                panel.resizeView.edges = zone.edges
                panel.resizeView.aspectRatio = aspectRatio
                panel.resizeView.acquisitionThickness = resizeAcquisitionThickness
                panel.level = parent.level
                panel.collectionBehavior = parent.collectionBehavior
                panel.setFrame(zone.frame, display: true)
                // A borderless transparent child window does not always resize
                // its manually supplied content view on every WindowServer
                // path. Keep the event surface explicit so the whole outside
                // corner zone, rather than a stale zero-sized sub-rect, accepts
                // mouse-down and cursor-update events.
                panel.resizeView.frame = NSRect(origin: .zero, size: zone.frame.size)
                if panel.parent !== parent {
                    panel.parent?.removeChildWindow(panel)
                    parent.addChildWindow(panel, ordered: .above)
                }
                panel.orderFront(nil)
            }
        }

        func updateAspectRatio(for window: NSWindow, requestedAspectRatio: CGFloat) {
            switch MirrorAspectUpdateDecision.resolve(
                appliedAspectRatio: appliedAspectRatio,
                requestedAspectRatio: requestedAspectRatio,
                isLiveResize: resizeActivity.isActive(systemLiveResize: window.inLiveResize)
            ) {
            case .unchanged:
                pendingAspectRatio = nil
            case let .deferUntilResizeEnds(ratio):
                pendingAspectRatio = ratio
            case let .apply(ratio):
                applyAspectRatio(ratio, to: window)
            }
        }

        private func applyAspectRatio(_ ratio: CGFloat, to window: NSWindow) {
            let minimumShortEdge: CGFloat = 280
            let minimumPhoneSize = MirrorWindowGeometry.minimumContentSize(
                aspectRatio: ratio,
                minimumShortEdge: minimumShortEdge
            )
            window.contentAspectRatio = .zero
            window.contentMinSize = minimumPhoneSize

            let visible = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
            let targetPhoneSize = MirrorWindowGeometry.fittedContentSize(
                preservingAreaOf: window.contentLayoutRect.size,
                aspectRatio: ratio,
                visibleFrame: visible.insetBy(
                    dx: resizeAcquisitionThickness,
                    dy: resizeAcquisitionThickness
                ),
                minimumShortEdge: minimumShortEdge
            )
            if abs(window.contentLayoutRect.width - targetPhoneSize.width) > 0.5 ||
                abs(window.contentLayoutRect.height - targetPhoneSize.height) > 0.5 {
                window.setContentSize(targetPhoneSize)
            }
            window.setFrame(
                MirrorWindowGeometry.frameReservingHeader(
                    window.frame,
                    visibleFrame: visible,
                    headerClearance: 48
                ),
                display: false
            )
            appliedAspectRatio = ratio
            pendingAspectRatio = nil
            updatePanelFrame()
            updateResizePanels(
                parent: window,
                aspectRatio: ratio,
                thickness: resizeAcquisitionThickness,
                armLength: cornerArmLength
            )
        }

        private func headerPanel(content: AnyView) -> NSPanel {
            if let panel { return panel }
            let hostingView = NSHostingView(rootView: content)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hostingView
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.isReleasedWhenClosed = false
            self.hostingView = hostingView
            self.panel = panel
            return panel
        }

        private func observe(_ parent: NSWindow) {
            guard observedWindow !== parent else { return }
            NotificationCenter.default.removeObserver(self)
            observedWindow = parent
            for name in [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didEndLiveResizeNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(parentFrameChanged(_:)),
                    name: name,
                    object: parent
                )
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(manualResizeBegan(_:)),
                name: .galaxyBridgeMirrorManualResizeBegan,
                object: parent
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(manualResizeEnded(_:)),
                name: .galaxyBridgeMirrorManualResizeEnded,
                object: parent
            )
        }

        @objc private func parentFrameChanged(_ notification: Notification) {
            updatePanelFrame()
            if let parent = observedWindow, let appliedAspectRatio {
                updateResizePanels(
                    parent: parent,
                    aspectRatio: appliedAspectRatio,
                    thickness: resizeAcquisitionThickness,
                    armLength: cornerArmLength
                )
            }
            if notification.name == NSWindow.didEndLiveResizeNotification,
               let parent = observedWindow,
               let pendingAspectRatio {
                applyAspectRatio(pendingAspectRatio, to: parent)
            }
        }

        @objc private func manualResizeBegan(_ notification: Notification) {
            resizeActivity.beginManualResize()
        }

        @objc private func manualResizeEnded(_ notification: Notification) {
            resizeActivity.endManualResize()
            guard let parent = observedWindow, let pendingAspectRatio else { return }
            applyAspectRatio(pendingAspectRatio, to: parent)
        }

        private func updatePanelFrame() {
            guard let parent = observedWindow, let panel else { return }
            let placement = MirrorWindowGeometry.headerPlacement(
                parentFrame: parent.frame,
                panelHeight: 52,
                transparentBridgeHeight: 8,
                minimumPanelWidth: 430
            )
            panel.setFrame(placement.panelFrame, display: true)
        }

    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window,
                  (window as? SeamlessMirrorWindow)?.isPresentationRetired != true
            else { return }
            let ratio = max(0.25, min(2.5, contentAspectRatio))
            let isNewWindow = context.coordinator.window !== window
            let ratioChanged = context.coordinator.appliedAspectRatio.map { abs($0 - ratio) > 0.004 } ?? true

            if isNewWindow {
                window.title = title
                window.styleMask = MirrorWindowActivationPolicy.seamlessFocusableStyleMask(
                    from: window.styleMask
                )
                for button in [
                    NSWindow.ButtonType.closeButton,
                    .miniaturizeButton,
                    .zoomButton,
                    .toolbarButton,
                    .documentIconButton,
                    .documentVersionsButton,
                ] {
                    window.standardWindowButton(button)?.isHidden = true
                }
                window.toolbar = nil
                window.isMovableByWindowBackground = false
                window.hasShadow = false
                window.isOpaque = false
                window.backgroundColor = .clear
                window.acceptsMouseMovedEvents = true
                window.isRestorable = true
                window.contentView?.wantsLayer = true
                window.contentView?.layer?.cornerRadius = 0
                window.contentView?.layer?.masksToBounds = false
                context.coordinator.window = window
                context.coordinator.captureBaseCollectionBehavior(from: window)
            }
            windowTarget.window = window
            context.coordinator.resizeAcquisitionThickness = max(1, resizeAcquisitionThickness)
            context.coordinator.cornerArmLength = max(
                context.coordinator.resizeAcquisitionThickness,
                cornerArmLength
            )

            context.coordinator.updatePinPolicy(for: window, isPinned: isPinned)
            context.coordinator.updateResizePanels(
                parent: window,
                aspectRatio: ratio,
                thickness: resizeAcquisitionThickness,
                armLength: cornerArmLength
            )
            context.coordinator.updateHeader(
                parent: window,
                content: headerContent,
                isVisible: showsHeader,
                isPinned: isPinned
            )

            guard isNewWindow || ratioChanged else { return }
            context.coordinator.updateAspectRatio(for: window, requestedAspectRatio: ratio)
        }
    }
}

@MainActor
private final class ExternalCornerResizePanel: NSPanel {
    let resizeView: ExternalCornerResizeView

    init(edges: MirrorResizeEdges) {
        resizeView = ExternalCornerResizeView(edges: edges)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = resizeView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        resizeView.autoresizingMask = [.width, .height]
        resizeView.wantsLayer = true
        // WindowServer can discard an entirely empty transparent surface from
        // pointer targeting. One alpha quantum is visually imperceptible but
        // survives 8-bit compositor quantization and keeps the external grab
        // zone in the hit-test map.
#if DEBUG
        // The acquisition panels are an implementation detail of the
        // seamless window. Never expose a runtime switch that can make them
        // visible in a packaged build: launchd environment survives relaunches
        // and could otherwise turn the invisible corner targets into large
        // coloured rectangles on the user's desktop.
        resizeView.layer?.backgroundColor = NSColor.black.withAlphaComponent(
            MirrorResizeAcquisitionPolicy.windowServerBackingAlpha
        ).cgColor
#else
        resizeView.layer?.backgroundColor = NSColor.black.withAlphaComponent(
            MirrorResizeAcquisitionPolicy.windowServerBackingAlpha
        ).cgColor
#endif
    }
}

@MainActor
private final class ExternalCornerResizeView: NSView {
    weak var targetWindow: NSWindow?
    var edges: MirrorResizeEdges
    var aspectRatio: CGFloat = 9 / 19.5
    var acquisitionThickness = MirrorResizeAcquisitionPolicy.externalHaloWidth
    private var dragStartMouse = NSPoint.zero
    private var dragStartFrame = NSRect.zero
    private var dragAspectLock = MirrorResizeAspectLock()
    private var cursorTrackingArea: NSTrackingArea?

    init(edges: MirrorResizeEdges) {
        self.edges = edges
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        resizeCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        resizeCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        resizeCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let targetWindow else { return }
        targetWindow.makeKey()
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = targetWindow.frame
        dragAspectLock.begin(aspectRatio: aspectRatio)
        NotificationCenter.default.post(name: .galaxyBridgeMirrorManualResizeBegan, object: targetWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let targetWindow else { return }
        let delta = NSPoint(
            x: NSEvent.mouseLocation.x - dragStartMouse.x,
            y: NSEvent.mouseLocation.y - dragStartMouse.y
        )
        let ratio = dragAspectLock.effectiveAspectRatio(current: aspectRatio)
        let visible = targetWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? dragStartFrame
        targetWindow.setFrame(
            MirrorWindowGeometry.resizedFrame(
                from: dragStartFrame,
                edges: edges,
                mouseDelta: delta,
                aspectRatio: ratio,
                visibleFrame: visible.insetBy(
                    dx: acquisitionThickness,
                    dy: acquisitionThickness
                ),
                minimumShortEdge: 280
            ),
            display: true
        )
    }

    override func mouseUp(with event: NSEvent) {
        if let targetWindow {
            NotificationCenter.default.post(name: .galaxyBridgeMirrorManualResizeEnded, object: targetWindow)
        }
        dragAspectLock.end()
    }

    private var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            if edges.contains(.left) {
                position = edges.contains(.top) ? .topLeft : .bottomLeft
            } else {
                position = edges.contains(.top) ? .topRight : .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        let kind = MirrorWindowGeometry.resizeCursor(for: edges)
        return kind == .topLeftBottomRight ? .resizeLeftRight : .resizeUpDown
    }
}

private struct WindowResizeOverlay: NSViewRepresentable {
    let deviceID: String
    let aspectRatio: CGFloat
    let haloWidth: CGFloat
    let onTopEdgeHover: (Bool) -> Void

    func makeNSView(context: Context) -> AspectResizeView {
        let view = AspectResizeView(frame: .zero)
        view.deviceID = deviceID
        view.aspectRatio = aspectRatio
        view.haloWidth = haloWidth
        view.onTopEdgeHover = onTopEdgeHover
        return view
    }

    func updateNSView(_ nsView: AspectResizeView, context: Context) {
        nsView.deviceID = deviceID
        nsView.aspectRatio = max(0.25, min(2.5, aspectRatio))
        nsView.haloWidth = max(1, haloWidth)
        nsView.onTopEdgeHover = onTopEdgeHover
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

@MainActor
private final class AspectResizeView: NSView {
    var aspectRatio: CGFloat = 9 / 19.5
    var deviceID = ""
    var haloWidth = MirrorResizeAcquisitionPolicy.externalHaloWidth
    var onTopEdgeHover: ((Bool) -> Void)?
    private let cornerHitSize = MirrorResizeAcquisitionPolicy.cornerArmLength
    private var trackingArea: NSTrackingArea?
    private var announcedTopEdge = false
    private var dragEdges: MirrorResizeEdges = []
    private var dragStartMouse = NSPoint.zero
    private var dragStartFrame = NSRect.zero
    private var dragAspectLock = MirrorResizeAspectLock()

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        updateTopEdgeAnnouncement(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateTopEdgeAnnouncement(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let targetEdges = edges(at: point)
        guard let cursorKind = MirrorWindowGeometry.resizeCursor(for: targetEdges) else {
            NSCursor.arrow.set()
            return
        }
        resizeCursor(for: cursorKind, edges: targetEdges).set()
    }

    private func updateTopEdgeAnnouncement(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let phoneBounds = bounds.insetBy(dx: haloWidth, dy: haloWidth)
        let atTopEdge = MirrorWindowGeometry.isTopEdgeHoverTarget(
            point,
            in: phoneBounds,
            activationWidth: 10
        )
        guard atTopEdge != announcedTopEdge else { return }
        announcedTopEdge = atTopEdge
        onTopEdgeHover?(atTopEdge)
    }

    override func mouseExited(with event: NSEvent) {
        guard announcedTopEdge else { return }
        announcedTopEdge = false
        onTopEdgeHover?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        edges(at: point).isEmpty ? nil : self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let phoneBounds = bounds.insetBy(dx: haloWidth, dy: haloWidth)
        let cornerExtent = min(
            cornerHitSize,
            max(0, min(phoneBounds.width, phoneBounds.height) / 2)
        )

        addCornerCursorRects(
            horizontal: .left,
            vertical: .bottom,
            phoneBounds: phoneBounds,
            cornerExtent: cornerExtent
        )
        addCornerCursorRects(
            horizontal: .right,
            vertical: .bottom,
            phoneBounds: phoneBounds,
            cornerExtent: cornerExtent
        )
        addCornerCursorRects(
            horizontal: .left,
            vertical: .top,
            phoneBounds: phoneBounds,
            cornerExtent: cornerExtent
        )
        addCornerCursorRects(
            horizontal: .right,
            vertical: .top,
            phoneBounds: phoneBounds,
            cornerExtent: cornerExtent
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        updateTopEdgeAnnouncement(with: event)
        dragEdges = edges(at: convert(event.locationInWindow, from: nil))
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = window.frame
        if !dragEdges.isEmpty {
            dragAspectLock.begin(aspectRatio: aspectRatio)
            NotificationCenter.default.post(name: .galaxyBridgeMirrorManualResizeBegan, object: window)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !dragEdges.isEmpty else { return }
        let delta = NSPoint(
            x: NSEvent.mouseLocation.x - dragStartMouse.x,
            y: NSEvent.mouseLocation.y - dragStartMouse.y
        )
        let ratio = dragAspectLock.effectiveAspectRatio(current: aspectRatio)
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? dragStartFrame
        let targetFrame = MirrorWindowGeometry.resizedOuterFrame(
            from: dragStartFrame,
            haloWidth: haloWidth,
            edges: dragEdges,
            mouseDelta: delta,
            aspectRatio: ratio,
            visibleFrame: visible,
            minimumShortEdge: 280
        )
        window.setFrame(targetFrame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragEdges.isEmpty, let window {
            NotificationCenter.default.post(name: .galaxyBridgeMirrorManualResizeEnded, object: window)
        }
        dragAspectLock.end()
        dragEdges = []
    }

    private func edges(at point: NSPoint) -> MirrorResizeEdges {
        MirrorWindowGeometry.resizeEdges(
            at: point,
            in: bounds,
            edgeHitWidth: haloWidth,
            cornerHitSize: cornerHitSize
        )
    }

    private func addCornerCursorRects(
        horizontal: MirrorResizeEdges,
        vertical: MirrorResizeEdges,
        phoneBounds: CGRect,
        cornerExtent: CGFloat
    ) {
        let edges = horizontal.union(vertical)
        let cursor = resizeCursor(for: edges)
        let isLeft = horizontal.contains(.left)
        let isBottom = vertical.contains(.bottom)
        let outsideX = isLeft ? bounds.minX : phoneBounds.maxX
        let outsideY = isBottom ? bounds.minY : phoneBounds.maxY
        let verticalArmY = isBottom ? phoneBounds.minY : phoneBounds.maxY - cornerExtent
        let horizontalArmX = isLeft ? phoneBounds.minX : phoneBounds.maxX - cornerExtent

        addCursorRect(
            NSRect(x: outsideX, y: outsideY, width: haloWidth, height: haloWidth),
            cursor: cursor
        )
        addCursorRect(
            NSRect(x: outsideX, y: verticalArmY, width: haloWidth, height: cornerExtent),
            cursor: cursor
        )
        addCursorRect(
            NSRect(x: horizontalArmX, y: outsideY, width: cornerExtent, height: haloWidth),
            cursor: cursor
        )
    }

    private func resizeCursor(for edges: MirrorResizeEdges) -> NSCursor {
        guard let kind = MirrorWindowGeometry.resizeCursor(for: edges) else { return .arrow }
        return resizeCursor(for: kind, edges: edges)
    }

    private func resizeCursor(for kind: MirrorResizeCursorKind, edges: MirrorResizeEdges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch kind {
            case .horizontal:
                position = edges.contains(.left) ? .left : .right
            case .vertical:
                position = edges.contains(.top) ? .top : .bottom
            case .topLeftBottomRight:
                position = edges.contains(.top) ? .topLeft : .bottomRight
            case .bottomLeftTopRight:
                position = edges.contains(.top) ? .topRight : .bottomLeft
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }

        switch kind {
        case .horizontal, .topLeftBottomRight:
            return .resizeLeftRight
        case .vertical, .bottomLeftTopRight:
            return .resizeUpDown
        }
    }
}

private extension Notification.Name {
    static let galaxyBridgeMirrorManualResizeBegan = Notification.Name("GalaxyBridgeMirrorManualResizeBegan")
    static let galaxyBridgeMirrorManualResizeEnded = Notification.Name("GalaxyBridgeMirrorManualResizeEnded")
}
