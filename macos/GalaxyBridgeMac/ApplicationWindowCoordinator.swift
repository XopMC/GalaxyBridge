#if !GALAXYBRIDGE_APP_STORE
import AppKit
import SwiftUI

@MainActor
final class ApplicationWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private struct Record {
        let leaseID: String
        let window: NSWindow
        let session: ApplicationWindowSession
        let release: () -> Void
    }

    private var records: [String: Record] = [:]

    func present(application: ApplicationCatalogItem, device: DeviceRow, model: AppModel) {
        let key = "\(device.id)\u{0}\(application.packageName)"
        if let record = records[key] {
            record.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let serial = device.adbSerial else { return }
        let leaseID = "app:\(device.id):\(application.packageName)"
        guard model.reserveApplicationWindowSession(leaseID) else { return }
        do {
            let session = try ApplicationWindowSession(
                application: application,
                serial: serial,
                adb: ADBClient(),
                quicSelection: model.quicWirelessSelection(for: device),
                companionTextHandler: { [weak model] text in
                    model?.sendEnhancedTextViaCompanion(deviceID: device.id, text: text) ?? false
                },
                companionKeyHandler: { [weak model] isDown, keycode, repeatCount, modifiers in
                    model?.sendEnhancedKeyViaCompanion(
                        deviceID: device.id,
                        isDown: isDown,
                        keycode: keycode,
                        repeatCount: repeatCount,
                        modifiers: modifiers
                    ) ?? false
                },
                companionClipboardHandler: { [weak model] operation in
                    model?.sendEnhancedClipboardCommandViaCompanion(
                        deviceID: device.id,
                        operation: operation
                    ) ?? false
                },
                clipboardEventHandler: { [weak model] update in
                    model?.acceptEnhancedClipboard(
                        deviceID: device.id,
                        changeID: update.changeID,
                        content: update.content
                    )
                },
                freshFramePresentationReceipt: { [weak model] in
                    model?.clientSetupEvidenceReceipt(deviceID: device.id, feature: .applications)
                }
            )
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: ApplicationWindowResizeGeometry.initialContentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.delegate = self
            window.title = application.label
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.contentMinSize = ApplicationWindowResizeGeometry.minimumContentSize
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentViewController = NSHostingController(
                rootView: ApplicationWindowView(session: session, close: { [weak window] in window?.close() })
                    .applicationLanguageLayout()
            )
            ApplicationWindowGeometrySampler.restoreContentSize(
                ApplicationWindowResizeGeometry.initialContentSize,
                on: window
            )
            window.center()
            let record = Record(
                leaseID: leaseID,
                window: window,
                session: session,
                release: { [weak model] in model?.releaseApplicationWindowSession(leaseID) }
            )
            records[key] = record
            let initialGeometry = ApplicationWindowGeometrySampler.sampleAfterPresentationAndLayout(from: window) {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            session.updateContentGeometry(
                contentSize: initialGeometry.contentSize,
                backingScale: initialGeometry.backingScale
            )
            session.start()
        } catch {
            model.releaseApplicationWindowSession(leaseID)
            model.reportApplicationWindowError(error.localizedDescription)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = records.first(where: { $0.value.window === window })
        else { return }
        entry.value.session.close()
        entry.value.release()
        records.removeValue(forKey: entry.key)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let record = records.values.first(where: { $0.window === window })
        else { return }
        updateGeometry(of: window, for: record.session)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let record = records.values.first(where: { $0.window === window })
        else { return }
        updateGeometry(of: window, for: record.session)
    }

    func shutdownForApplicationTermination() async {
        let activeRecords = Array(records.values)
        records.removeAll()
        for record in activeRecords {
            record.window.delegate = nil
            await record.session.closeAndWaitForCleanup()
            record.release()
            record.window.orderOut(nil)
            record.window.close()
        }
    }

    private func updateGeometry(of window: NSWindow, for session: ApplicationWindowSession) {
        let sample = ApplicationWindowGeometrySampler.sampleAfterLayout(from: window)
        session.updateContentGeometry(contentSize: sample.contentSize, backingScale: sample.backingScale)
    }
}

private struct ApplicationWindowView: View {
    @ObservedObject var session: ApplicationWindowSession
    let close: () -> Void
    @State private var headerVisibility = AppWindowHeaderVisibility()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            ApplicationWindowAspectFitVideoSurface(
                model: session.surface,
                aspectRatio: session.aspectRatio
            )
            .environment(\.layoutDirection, .leftToRight)
            DeviceInputSurface(
                aspectRatio: session.aspectRatio,
                contentInset: 0,
                videoContentMode: .fit,
                preciseScrollUsesTouch: true,
                onTouch: { session.sendTouch(action: $0, normalizedX: $1, normalizedY: $2) },
                onTrackpadTouch: {
                    session.sendTouch(
                        action: $0,
                        normalizedX: $1,
                        normalizedY: $2,
                        pointerID: UInt64.max - 1
                    )
                },
                onScroll: { session.sendScroll(x: $0, y: $1, horizontal: $2, vertical: $3) },
                onPinch: { session.sendPinch(action: $0, x: $1, y: $2, scale: $3) },
                onKey: { session.sendKey(action: $0, keycode: $1, repeatCount: $2, modifiers: $3) },
                onText: session.sendText,
                onNavigation: session.sendNavigation,
                onClipboardCommand: session.requestRemoteClipboard,
                onTopEdgeHover: { headerVisibility.setTopEdgeHovered($0) }
            )
            .environment(\.layoutDirection, .leftToRight)
            if session.presentationState.showsOpeningOverlay {
                ProgressView("APPLICATION_WINDOW_OPENING")
                    .controlSize(.large)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if headerVisibility.isVisible {
                HStack(spacing: 14) {
                    Button(action: close) { Image(systemName: "xmark") }
                    Text(session.application.label).lineLimit(1)
                    Spacer()
                    Button { session.sendNavigation(4) } label: { Image(systemName: "chevron.backward") }
                    Button { session.sendNavigation(3) } label: { Image(systemName: "circle") }
                    Button { session.sendNavigation(187) } label: { Image(systemName: "square.on.square") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(.ultraThinMaterial)
                .contentShape(Rectangle())
                .onHover { headerVisibility.setControlsHovered($0) }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.14), value: headerVisibility.isVisible)
        .task(id: headerVisibility.pendingHideID) {
            guard let requestID = headerVisibility.pendingHideID else { return }
            do {
                try await Task.sleep(for: .milliseconds(AppWindowHeaderVisibility.hideDelayMilliseconds))
            } catch { return }
            guard !Task.isCancelled else { return }
            headerVisibility.completeHide(requestID: requestID)
        }
        .onDisappear { headerVisibility.reset() }
    }
}

private struct ApplicationWindowAspectFitVideoSurface: View {
    let model: VideoSurfaceModel
    let aspectRatio: CGFloat

    var body: some View {
        GeometryReader { geometry in
            if let frame = ApplicationWindowVideoGeometry.aspectFit(
                aspectRatio: aspectRatio,
                destinationSize: geometry.size
            ) {
                MetalVideoSurface(model: model)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}
#endif
