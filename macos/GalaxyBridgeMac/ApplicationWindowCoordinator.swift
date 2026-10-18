#if !GALAXYBRIDGE_APP_STORE
import AppKit
import Combine
import SwiftUI

@MainActor
final class ApplicationWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    struct RouteResume {
        let application: ApplicationCatalogItem
        let frame: NSRect
    }
    struct RouteSuspension {
        let windows: [RouteResume]
        let settled: Bool
    }
    private final class DeviceIdentity {
        var id: String
        init(_ id: String) { self.id = id }
    }
    private struct Record {
        let identity: DeviceIdentity
        let leaseID: String
        let window: NSWindow
        let session: ApplicationWindowSession
        let release: () -> Void
        let privacySubscriptions: Set<AnyCancellable>
    }
    /// Closed UI must not retain a Metal view while its native owner settles.
    private struct RetiringRecord {
        let session: ApplicationWindowSession
        let release: () -> Void
        var releasedHostCapacity = false
    }

    private var records: [String: Record] = [:]
    private var retiringRecords: [String: RetiringRecord] = [:]
    private var retirementTasks: [UUID: Task<Void, Never>] = [:]
    private var retirementTaskByKey: [String: UUID] = [:]
    private var localSettlementTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func adoptDeviceIdentity(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        let oldPrefix = oldID + "\u{0}"
        for (key, record) in records.filter({ $0.key.hasPrefix(oldPrefix) }) {
            let next = newID + "\u{0}" + key.dropFirst(oldPrefix.count)
            record.identity.id = newID
            if records[next] != nil {
                // Keep the existing canonical window; retire the exact colliding
                // pre-pair owner without overwriting either release handle.
                beginRetirement(key: key, record: record, closeWindow: true)
            } else {
                records.removeValue(forKey: key)
                records[next] = record
            }
        }
        for (key, record) in retiringRecords.filter({ $0.key.hasPrefix(oldPrefix) }) {
            let base = newID + "\u{0}" + key.dropFirst(oldPrefix.count)
            let next = retiringRecords[base] == nil ? base : base + "\u{0}" + UUID().uuidString
            retiringRecords.removeValue(forKey: key)
            retiringRecords[next] = record
            if let task = retirementTaskByKey.removeValue(forKey: key) { retirementTaskByKey[next] = task }
        }
    }

    private func ownedSessions(deviceID: String) -> [ApplicationWindowSession] {
        records.filter { $0.key.hasPrefix(deviceID + "\u{0}") }.values.map(\.session)
            + retiringRecords.filter { $0.key.hasPrefix(deviceID + "\u{0}") }.values.map(\.session)
    }

    func captureSerials(deviceID: String) -> Set<String> {
        Set(ownedSessions(deviceID: deviceID).map { $0.nativeSession.serial })
    }

    func hasStaleADBGeneration(deviceID: String, currentGeneration: UUID) -> Bool {
        ownedSessions(deviceID: deviceID).contains {
            $0.nativeSession.capturedADBGeneration.map { $0 != currentGeneration } == true
        }
    }

    func installRetirementRoute(_ route: VerifiedEnhancedRetirementRoute, deviceID: String) {
        for session in ownedSessions(deviceID: deviceID) where session.nativeSession.serial == route.captureSerial {
            session.nativeSession.installVerifiedCleanupRoute(route)
        }
    }

    func hasRetiringOwners(deviceID: String) -> Bool {
        retiringRecords.keys.contains { $0.hasPrefix(deviceID + "\u{0}") }
    }

    func hasOwnedADBCaptureWindows(deviceID: String) -> Bool {
        ownedSessions(deviceID: deviceID).contains { !$0.nativeSession.serial.hasPrefix("shell:") }
    }

    func hasOwnedShellCaptureWindows(deviceID: String) -> Bool {
        ownedSessions(deviceID: deviceID).contains { $0.nativeSession.serial.hasPrefix("shell:") }
    }

    func present(application: ApplicationCatalogItem, device: DeviceRow, model: AppModel,
                 activate: Bool = true, restoringFrame: NSRect? = nil) {
        guard model.featureEnabled(.applications, deviceID: device.id) else { return }
        model.registerApplicationWindowCoordinator(self)
        let key = "\(device.id)\u{0}\(application.packageName)"
        if let record = records[key] {
            if activate { record.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            else { record.window.orderFront(nil) }
            return
        }
        guard !retiringRecords.keys.contains(where: { $0 == key || $0.hasPrefix(key + "\u{0}") }) else {
            model.reportApplicationWindowError(String(localized: "ERROR_MEDIA_CLEANUP"))
            return
        }
        guard let route = model.enhancedCaptureRoute(for: device) else { return }
        let serial = route.serial
        let clipboardIdentity = model.enhancedClipboardIdentity(deviceID: device.id, serial: serial)
        let leaseID = "app:\(device.id):\(application.packageName)"
        let identity = DeviceIdentity(device.id)
        guard model.reserveApplicationWindowSession(leaseID) else { return }
        do {
            let session = try ApplicationWindowSession(
                application: application,
                serial: serial,
                adb: ADBClient(),
                quicSelection: model.quicWirelessSelection(for: device),
                companionTextHandler: { [weak model] text in
                    model?.sendEnhancedTextViaCompanion(deviceID: identity.id, text: text) ?? false
                },
                companionKeyHandler: { [weak model] isDown, keycode, repeatCount, modifiers in
                    model?.sendEnhancedKeyViaCompanion(
                        deviceID: identity.id,
                        isDown: isDown,
                        keycode: keycode,
                        repeatCount: repeatCount,
                        modifiers: modifiers
                    ) ?? false
                },
                companionClipboardHandler: { [weak model] operation in
                    model?.sendEnhancedClipboardCommandViaCompanion(
                        deviceID: identity.id,
                        operation: operation
                    ) ?? false
                },
                clipboardEventHandler: { [weak model] update in
                    model?.acceptEnhancedClipboard(
                        deviceID: identity.id,
                        changeID: update.changeID,
                        content: update.content,
                        sourceIdentity: clipboardIdentity
                    )
                },
                clipboardEnabled: { [weak model] in
                    model?.featureEnabled(.clipboard, deviceID: identity.id) == true
                },
                freshFramePresentationReceipt: { [weak model] in
                    model?.clientSetupEvidenceReceipt(deviceID: identity.id, feature: .applications)
                },
                shellProvider: route.shellProvider,
                remoteAbsenceProof: model.captureRetirementAbsenceProof(deviceID: identity.id, captureSerial: serial)
            )
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: ApplicationWindowResizeGeometry.initialContentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.delegate = self
            window.title = "\(application.label) — \(device.name)"
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
            if let restoringFrame { window.setFrame(restoringFrame, display: false) }
            else { window.center() }
            let privacyLease = UUID()
            var privacySubscriptions = Set<AnyCancellable>()
            session.nativeSession.$phoneDisplayPrivacyReady.sink { [weak model, weak nativeSession = session.nativeSession] ready in
                if ready, let nativeSession, !nativeSession.usesCompositeDisplayInteraction {
                    model?.phoneDisplaySessionReady(deviceID: identity.id, serial: serial, leaseID: privacyLease)
                }
            }.store(in: &privacySubscriptions)
            session.$state.sink { [weak model] state in
                switch state {
                case .preparing, .failed, .stopped:
                    model?.releasePhoneDisplaySession(privacyLease)
                default: break
                }
            }.store(in: &privacySubscriptions)
            let record = Record(
                identity: identity,
                leaseID: leaseID,
                window: window,
                session: session,
                release: { [weak model] in
                    model?.releasePhoneDisplaySession(privacyLease)
                    model?.releaseApplicationWindowSession(leaseID)
                },
                privacySubscriptions: privacySubscriptions
            )
            records[key] = record
            let initialGeometry = ApplicationWindowGeometrySampler.sampleAfterPresentationAndLayout(from: window) {
                if activate { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
                else { window.orderFront(nil) }
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
        _ = beginRetirement(key: entry.key, record: entry.value, closeWindow: false)
    }

    @discardableResult
    private func beginRetirement(key activeKey: String, record: Record, closeWindow: Bool) -> UUID {
        records.removeValue(forKey: activeKey)
        let key = retiringRecords[activeKey] == nil ? activeKey : activeKey + "\u{0}" + UUID().uuidString
        let retired = RetiringRecord(session: record.session, release: record.release)
        retiringRecords[key] = retired
        record.window.delegate = nil
        record.session.close()
        if closeWindow { record.window.close() }
        let ticket = UUID()
        retirementTaskByKey[key] = ticket
        retirementTasks[ticket] = Task { [weak self, retired] in
            await retired.session.closeAndWaitForCleanup()
            guard let self else { return }
            if let currentKey = self.retiringRecords.first(where: { $0.value.session === retired.session })?.key {
                self.releaseRetiredRecord(key: currentKey, session: retired.session)
            }
            self.retirementTasks.removeValue(forKey: ticket)
            self.retirementTaskByKey = self.retirementTaskByKey.filter { $0.value != ticket }
            self.observeLateLocalSettlement(retired.session)
        }
        return ticket
    }

    private func observeLateLocalSettlement(_ session: ApplicationWindowSession) {
        let id = ObjectIdentifier(session)
        guard !session.nativeSession.hostResourcesPhysicallySettled, localSettlementTasks[id] == nil else { return }
        localSettlementTasks[id] = Task { [weak self, weak session] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    guard let session, let key = self.retiringRecords.first(where: { $0.value.session === session })?.key else {
                        self.localSettlementTasks.removeValue(forKey: id)
                        return
                    }
                    self.releaseRetiredRecord(key: key, session: session)
                    if session.nativeSession.hostResourcesPhysicallySettled {
                        self.localSettlementTasks.removeValue(forKey: id)
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    private func releaseRetiredRecord(key: String, session: ApplicationWindowSession) {
        guard var retired = retiringRecords[key], retired.session === session else { return }
        if !retired.releasedHostCapacity, session.nativeSession.hostResourcesPhysicallySettled {
            retired.releasedHostCapacity = true
            retiringRecords[key] = retired
            retired.release()
        }
        // Remote ownership is a per-target fence. A disconnected phone must not
        // consume another phone's decoder capacity after all local work ended.
        if session.nativeSession.cleanupPhysicallySettled, retiringRecords[key]?.session === session {
            retiringRecords.removeValue(forKey: key)
        }
    }

    func retryRetiringOwners(deviceID: String) async -> Bool {
        for (key, record) in retiringRecords.filter({ $0.key.hasPrefix(deviceID + "\u{0}") }) {
            if let ticket = retirementTaskByKey[key], let work = retirementTasks[ticket] { await work.value }
            guard retiringRecords[key]?.session === record.session else { continue }
            record.session.nativeSession.retryOwnedCleanup()
            await record.session.nativeSession.waitForScheduledCleanup()
            releaseRetiredRecord(key: key, session: record.session)
        }
        return !hasRetiringOwners(deviceID: deviceID)
    }

    func closeForFeaturePolicy(deviceID: String) {
        let selected = records.filter { $0.key.hasPrefix(deviceID + "\u{0}") }
        // Delegate close removes each exact owned session and starts its existing cleanup.
        for record in selected.values { record.window.close() }
    }

    func suspendForRouteChange(deviceID: String) async -> RouteSuspension {
        var windows: [RouteResume] = []
        do {
            let selected = records.filter { $0.key.hasPrefix(deviceID + "\u{0}") }
            windows = selected.values.map { RouteResume(application: $0.session.application, frame: $0.window.frame) }
            for (key, record) in selected { beginRetirement(key: key, record: record, closeWindow: true) }
        }
        // No strong closed window/view graph crosses this await.
        let settled = await retryRetiringOwners(deviceID: deviceID)
        return RouteSuspension(windows: windows, settled: settled)
    }

    func resumeAfterRouteChange(_ windows: [RouteResume], device: DeviceRow, model: AppModel, activate: Bool = true) {
        for item in windows {
            let key = device.id + "\u{0}" + item.application.packageName
            if !activate, records[key] != nil { continue }
            present(application: item.application, device: device, model: model, activate: activate, restoringFrame: item.frame)
        }
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
        do {
            let active = records
            for (key, record) in active { beginRetirement(key: key, record: record, closeWindow: true) }
        }
        for work in Array(retirementTasks.values) { await work.value }
        for (key, record) in Array(retiringRecords) { releaseRetiredRecord(key: key, session: record.session) }
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
