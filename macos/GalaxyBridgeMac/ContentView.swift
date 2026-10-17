import AppKit
import CoreImage
import GalaxyBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct ClientSetupWorkspaceRequest: Equatable {
    let id = UUID()
    let deviceID: String
    let feature: ClientSetupFeature
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var mirrorWindows: DeviceMirrorWindowPresenter
    @EnvironmentObject private var applicationWindows: ApplicationWindowCoordinator
    @State private var pendingRevocation: DeviceRow?
    @State private var isWirelessSetupPresented = false
    @State private var continueWithWirelessSetup = false
    @State private var setupDevice: DeviceRow?
    @State private var setupAction: (deviceID: String, feature: ClientSetupFeature)?
    @State private var setupShouldPair = false
    @State private var setupFileDeviceID: String?
    @State private var setupFileAttempt: UUID?
    @State private var isSetupFileImporterPresented = false
    @State private var workspaceSetupRequest: ClientSetupWorkspaceRequest?

    var body: some View {
        NavigationSplitView {
            deviceSidebar
                .frame(minWidth: 260)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            if let device = model.row(id: model.selectedDeviceID) {
                // Isolate the split column from content ideal heights when controls expand.
                GeometryReader { viewport in
                    DeviceWorkspace(device: device, setupRequest: workspaceSetupRequest)
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
                }
                    .toolbar {
                        ToolbarItemGroup {
                            Button { setupDevice = device } label: {
                                Label("DEVICE_FEATURES_TITLE", systemImage: "slider.horizontal.3")
                            }
                            Button(action: model.beginPairing) {
                                Label("PAIR_DEVICE", systemImage: "qrcode")
                            }
                            Button {
                                mirrorWindows.present(device: device, model: model)
                            } label: {
                                Label("DETACH", systemImage: "macwindow.on.rectangle")
                            }
                            .disabled(!device.isReady || !model.featureEnabled(.screen, deviceID: device.id))
                            Button(action: model.refresh) {
                                Label("REFRESH", systemImage: "arrow.clockwise")
                            }
                            .disabled(model.isRefreshing)
                            if model.canRevokePairing(deviceID: device.id) {
                                Button(role: .destructive) {
                                    pendingRevocation = device
                                } label: {
                                    Label("FORGET_DEVICE", systemImage: "trash")
                                }
                            }
                            if model.cameraExtension.supportsActivation {
                                Button(action: model.cameraExtension.activate) {
                                    Label("CAMERA_EXTENSION_INSTALL", systemImage: "video.badge.plus")
                                }
                            }
                        }
                    }
            } else {
                ContentUnavailableView(
                    "NO_DEVICE",
                    systemImage: "iphone.slash",
                    description: Text("NO_DEVICE_HINT")
                )
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .sheet(item: $setupDevice, onDismiss: performSetupAction) { device in
            ClientSetupView(setup: model.clientSetup, deviceID: device.id, deviceName: device.name,
                connectionReady: model.row(id: device.id)?.isReady == true,
                pair: { setupShouldPair = true; setupDevice = nil },
                test: { feature in
                    if feature != .notifications {
                        setupAction = (device.id, feature)
                        setupDevice = nil
                    }
                }, dismiss: { setupDevice = nil },
                optionalFeatures: (model.availableCapabilitiesByDevice[device.id]?.contains("CAPABILITY_CALLS") == true ||
                    model.capabilityReasonsByDevice[device.id]?["CAPABILITY_CALLS"] == "feature_disabled") ? [.calls] : [],
                onSelectionChanged: { model.setFeatureSelection(deviceID: device.id, features: $0) })
                .applicationLanguageLayout()
        }
        .fileImporter(isPresented: $isSetupFileImporterPresented, allowedContentTypes: [.data]) { result in
            guard let deviceID = setupFileDeviceID else { return }
            switch result {
            case let .success(url): model.sendFile(deviceID: deviceID, url: url)
            case .failure:
                if let attempt = setupFileAttempt {
                    model.clientSetup.cancelVerification(deviceID: deviceID, feature: .files, attemptID: attempt)
                }
            }
            setupFileDeviceID = nil
            setupFileAttempt = nil
        }
        .sheet(isPresented: $model.isPairingPresented, onDismiss: {
            if continueWithWirelessSetup {
                continueWithWirelessSetup = false
                isWirelessSetupPresented = true
            }
        }) {
            PairingSheet(coordinator: model.pairing, dismiss: model.endPairing, configureWireless: {
                continueWithWirelessSetup = true
                model.endPairing()
            })
            .applicationLanguageLayout()
        }
#if !GALAXYBRIDGE_APP_STORE
        .sheet(isPresented: $model.isNearbyPairingPresented, onDismiss: { model.nearbyConnection.endOfflinePairing() }) {
            NearbyPairingSheet(coordinator: model.nearbyConnection) { model.isNearbyPairingPresented = false }
                .applicationLanguageLayout()
        }
        .sheet(isPresented: $isWirelessSetupPresented) {
            WirelessSetupSheet(connected: { _ in model.refresh() }, dismiss: { isWirelessSetupPresented = false })
                .applicationLanguageLayout()
        }
#endif
        .confirmationDialog(
            "FORGET_DEVICE_TITLE",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { if !$0 { pendingRevocation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("FORGET_DEVICE", role: .destructive) {
                if let device = pendingRevocation { model.revokePairing(deviceID: device.id) }
                pendingRevocation = nil
            }
            Button("CANCEL", role: .cancel) { pendingRevocation = nil }
        } message: {
            Text("FORGET_DEVICE_MESSAGE")
        }
        .onChange(of: model.nativeNotificationOpenRequest) { _, request in
            guard let request,
                  let device = model.row(id: request.deviceID)
            else { return }
            applicationWindows.present(
                application: .init(
                    packageName: request.packageName,
                    componentName: nil,
                    label: request.appLabel,
                    iconPNG: nil,
                    isSystem: false
                ),
                device: device,
                model: model
            )
        }
    }

    private func performSetupAction() {
        if setupShouldPair {
            setupShouldPair = false
            model.beginPairing()
            return
        }
        guard let action = setupAction else { return }
        setupAction = nil
        guard let device = model.row(id: action.deviceID), device.isReady else {
            model.clientSetup.invalidate(deviceID: action.deviceID)
            return
        }
        switch action.feature {
        case .screen:
            mirrorWindows.present(device: device, model: model)
        case .audio:
            mirrorWindows.present(device: device, model: model)
            model.beginAudioVerification(deviceID: device.id)
        case .files:
            setupFileDeviceID = device.id
            setupFileAttempt = model.clientSetup.currentAttemptID(deviceID: device.id, feature: .files)
            isSetupFileImporterPresented = true
        case .recording, .clipboard:
            mirrorWindows.present(device: device, model: model)
        default:
            // The selected workspace exposes the existing user actions. Their
            // permission/connection state cannot manufacture live proof.
            model.selectedDeviceID = device.id
            workspaceSetupRequest = ClientSetupWorkspaceRequest(deviceID: device.id, feature: action.feature)
        }
    }

    private var deviceSidebar: some View {
        List(selection: $model.selectedDeviceID) {
            Section("DEVICES") {
                ForEach(model.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.transport == .usbADB ? "cable.connector" : "wifi")
                            .foregroundStyle(device.isReady ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).lineLimit(1)
                            Text(device.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(device.id)
                    .contextMenu {
                        if model.canRevokePairing(deviceID: device.id) {
                            Button("FORGET_DEVICE", role: .destructive) {
                                pendingRevocation = device
                            }
                        }
                    }
                }
            }
        }
        // Only device rows participate in selection. Informational text and
        // setup actions must not clear the currently selected phone.
#if !GALAXYBRIDGE_APP_STORE
        .safeAreaInset(edge: .top, spacing: 0) {
            NearbyDiscoveryView(suggestions: model.nearbyConnection.discoverySuggestions) {
                model.beginNearbyPairing(candidateID: $0.id)
            }
        }
#endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let error = model.displayedError {
                    HStack(alignment: .top, spacing: 8) {
                        Text(error)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: model.dismissDisplayedError) {
                            Image(systemName: "xmark").padding(4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text("CLOSE"))
                        .accessibilityLabel(Text("CLOSE"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let deviceID = model.selectedDeviceID,
                   case let reasons = model.effectiveCapabilities(deviceID: deviceID).unavailableReasons.filter({
                       !["CAPABILITY_NEARBY_LINK", "CAPABILITY_PRIVILEGED_BRIDGE", "CAPABILITY_INTERNET_GATEWAY",
                         "CAPABILITY_FEATURE_CONFIGURATION"].contains($0.key)
                   }),
                   !reasons.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(
                                reasons.keys.sorted {
                                    UserFacingText.capabilityName(for: $0)
                                        .localizedCaseInsensitiveCompare(UserFacingText.capabilityName(for: $1)) == .orderedAscending
                                },
                                id: \.self
                            ) { capability in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(UserFacingText.capabilityName(for: capability)).font(.caption)
                                    Text(UserFacingText.unavailableReason(for: reasons[capability] ?? ""))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let device = model.row(id: model.selectedDeviceID) {
                        Button { setupDevice = device } label: {
                            Label("DEVICE_FEATURES_TITLE", systemImage: "slider.horizontal.3")
                        }
                    }
#if !GALAXYBRIDGE_APP_STORE
                    Button { isWirelessSetupPresented = true } label: {
                        Label("WIFI_SETUP_TITLE", systemImage: "wifi")
                    }
                    Button(action: model.beginNearbyPairing) {
                        Label("NEARBY_PAIR", systemImage: "plus.circle")
                    }
#endif
                    Button {
                        openWindow(id: "about")
                    } label: {
                        Label("ABOUT_ENTRY", systemImage: "info.circle")
                    }
                }
            }
            .padding(12)
            .background(.bar)
        }
        .navigationTitle("Galaxy Bridge")
        .toolbar {
            Button(action: model.beginPairing) {
                Image(systemName: "qrcode")
            }
            Button(action: model.refresh) {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }
}

private struct PairingSheet: View {
    @ObservedObject var coordinator: PairingCoordinator
    let dismiss: () -> Void
    let configureWireless: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("PAIR_DEVICE").font(.title2).fontWeight(.semibold)
            if let image = coordinator.qrCodeImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .accessibilityLabel("PAIRING_QR")
            } else {
                ProgressView().frame(width: 280, height: 280)
            }
            Text("PAIRING_HINT").multilineTextAlignment(.center).foregroundStyle(.secondary)
            switch coordinator.status {
            case .idle, .listening:
                EmptyView()
            case let .paired(name):
                Label(UserFacingText.formatted("PAIRED_WITH", name), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(message):
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if let url = coordinator.pairingURL {
                    Button("COPY_PAIRING_LINK") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                }
#if !GALAXYBRIDGE_APP_STORE
                if case .paired = coordinator.status {
                    Button("WIFI_SETUP_TITLE", action: configureWireless)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
#endif
                Button("CLOSE", action: dismiss)
            }
        }
        .padding(28)
        .frame(minWidth: 420, minHeight: 470)
    }
}

struct DeviceWorkspace: View {
    let device: DeviceRow
    var setupRequest: ClientSetupWorkspaceRequest? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var mirrorWindows: DeviceMirrorWindowPresenter
    @EnvironmentObject private var applicationWindows: ApplicationWindowCoordinator
    @State private var selectedPanel = Panel.applications

#if !GALAXYBRIDGE_APP_STORE
    private var phonePrivacyStatusKey: LocalizedStringKey {
        switch model.phoneDisplayPrivacyStatuses[device.id] ?? (model.phoneDisplayPrivacyEnabled(deviceID: device.id) ? .waitingForSession : .disabled) {
        case .disabled: "PHONE_DISPLAY_PRIVACY_DISABLED"
        case .waitingForSession: "PHONE_DISPLAY_PRIVACY_WAITING"
        case .preparing: "PHONE_DISPLAY_PRIVACY_PREPARING"
        case .hidden: "PHONE_DISPLAY_PRIVACY_HIDDEN"
        case .visible: "PHONE_DISPLAY_PRIVACY_VISIBLE"
        case .restoring: "PHONE_DISPLAY_PRIVACY_RESTORING"
        case .failed: "PHONE_DISPLAY_PRIVACY_FAILED"
        }
    }
#endif

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 72, height: 88)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.name).font(.title2.weight(.semibold))
                    Label(device.subtitle, systemImage: device.transport == .usbADB ? "cable.connector" : "wifi")
                        .foregroundStyle(.secondary)
                    Text(connectionStatus)
                        .font(.caption)
                        .foregroundStyle(device.isReady ? .green : .orange)
#if !GALAXYBRIDGE_APP_STORE
                    if model.hasEnhancedTransport(deviceID: device.id) {
                        Toggle("PHONE_DISPLAY_PRIVACY_TITLE", isOn: Binding(
                            get: { model.phoneDisplayPrivacyEnabled(deviceID: device.id) },
                            set: { model.setPhoneDisplayPrivacy($0, deviceID: device.id) }
                        ))
                        .toggleStyle(.switch)
                        .font(.caption)
                        .help("PHONE_DISPLAY_PRIVACY_PIN_HINT")
                        .accessibilityHint(Text("PHONE_DISPLAY_PRIVACY_PIN_HINT"))
                        HStack(spacing: 8) {
                            Text(phonePrivacyStatusKey).font(.caption).foregroundStyle(.secondary)
                            if case .failed = model.phoneDisplayPrivacyStatuses[device.id] {
                                Button("RETRY") {
                                    model.setPhoneDisplayPrivacy(
                                        model.phoneDisplayPrivacyEnabled(deviceID: device.id), deviceID: device.id)
                                }
                                .font(.caption)
                            }
                        }
                    }
#endif
                }
                Spacer()
                Button {
                    mirrorWindows.present(device: device, model: model)
                } label: {
                    Label("DETACH", systemImage: "macwindow.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!device.isReady || !model.featureEnabled(.screen, deviceID: device.id))
            }
            .padding(24)
            .background(.regularMaterial)
#if !GALAXYBRIDGE_APP_STORE
            NearbyInternetControls(device: device)
#endif
            Divider()
            Picker("PANELS", selection: $selectedPanel) {
                ForEach(Panel.allCases) { panel in
                    Label(panel.title, systemImage: panel.symbol).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            panelContent.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Galaxy Bridge")
        .onChange(of: setupRequest, initial: true) { _, request in
            guard let request, request.deviceID == device.id else { return }
            switch request.feature {
            case .applications: selectedPanel = .applications
            case .files: selectedPanel = .files
            case .notifications: selectedPanel = .notifications
            case .sms, .calls: selectedPanel = .sms
            case .camera: selectedPanel = .camera
            default: break
            }
        }
    }

    private var connectionStatus: String {
        UserFacingText.connectionStatus(
            isReady: device.isReady,
            usesPhoneApp: device.transport == .companionLAN
        )
    }

    @ViewBuilder
    private var panelContent: some View {
        if let feature = selectedPanelFeature, !model.featureEnabled(feature, deviceID: device.id) {
            ContentUnavailableView("FEATURE_DISABLED", systemImage: "slider.horizontal.3")
        } else {
        switch selectedPanel {
        case .applications: ApplicationCatalogPanel(device: device)
        case .files: FilesPanel(deviceID: device.id)
        case .notifications: NotificationsPanel(deviceID: device.id)
        case .sms: SMSPanel(deviceID: device.id)
        case .camera: CameraPanel(deviceID: device.id)
        }
        }
    }
    private var selectedPanelFeature: ClientSetupFeature? {
        switch selectedPanel {
        case .applications: .applications
        case .files: .files
        case .notifications: .notifications
        case .camera: .camera
        case .sms: nil
        }
    }
}

struct ScreenSurface: View {
    @EnvironmentObject private var model: AppModel
    let device: DeviceRow
    var showsControls = true
    var contentInset: CGFloat = 24
    var videoContentMode: ContentMode = .fit
    var onTopEdgeHover: (Bool) -> Void = { _ in }

    var body: some View {
        let surface = model.videoSurface(for: device.id)
        let physicalDeviceActive = model.enhancedScreenInterlocks[device.id] == .physicalDeviceActive
        let mediaUnavailable = screenMediaUnavailable
        GeometryReader { _ in
          ZStack {
            Color.black
            ScreenVideoLayer(
                surface: surface,
                deviceReady: device.isReady,
                screenCapabilityUnavailableReason: screenCapabilityUnavailableReason,
                physicalDeviceActive: physicalDeviceActive,
                mediaUnavailable: mediaUnavailable,
                usesPhoneAppCapture: !model.hasEnhancedTransport(deviceID: device.id),
                aspectRatio: model.videoAspectRatios[device.id] ?? (9 / 19.5),
                contentInset: contentInset,
                videoContentMode: videoContentMode
            )
            DeviceInputSurface(
                aspectRatio: model.videoAspectRatios[device.id] ?? (9 / 19.5),
                contentInset: contentInset,
                videoContentMode: videoContentMode,
                preciseScrollUsesTouch: model.hasEnhancedTransport(deviceID: device.id),
                onTouch: { action, x, y in
                    model.sendTouch(deviceID: device.id, action: action, normalizedX: x, normalizedY: y)
                },
                onTrackpadTouch: { action, x, y in
                    model.sendTouch(
                        deviceID: device.id,
                        action: action,
                        normalizedX: x,
                        normalizedY: y,
                        pointerID: UInt64.max - 1
                    )
                },
                onScroll: { x, y, horizontal, vertical in
                    model.sendScroll(
                        deviceID: device.id,
                        normalizedX: x,
                        normalizedY: y,
                        horizontal: horizontal,
                        vertical: vertical
                    )
                },
                onPinch: { action, x, y, scale in
                    model.sendPinch(
                        deviceID: device.id,
                        action: action,
                        centerX: x,
                        centerY: y,
                        scale: scale
                    )
                },
                onKey: { action, keycode, repeatCount, modifiers in
                    model.sendKey(
                        deviceID: device.id,
                        action: action,
                        keycode: keycode,
                        repeatCount: repeatCount,
                        modifiers: modifiers
                    )
                },
                onText: { model.sendText(deviceID: device.id, text: $0) },
                onNavigation: { model.sendNavigation(deviceID: device.id, keycode: $0) },
                onClipboardCommand: { model.requestRemoteClipboard(deviceID: device.id, command: $0) },
                onTopEdgeHover: onTopEdgeHover,
                primaryInputReceipt: { model.primaryInputTrace(deviceID: device.id, receivedAt: $0) },
                primaryTouch: { action, x, y, trace in
                    model.sendTouch(deviceID: device.id, action: action, normalizedX: x, normalizedY: y,
                                    diagnosticTrace: trace)
                },
                primaryTrackpadTouch: { action, x, y, trace in
                    model.sendTouch(deviceID: device.id, action: action, normalizedX: x, normalizedY: y,
                                    pointerID: UInt64.max - 1, diagnosticTrace: trace)
                }
            )
            // Phone coordinates stay physical left-to-right in every UI language.
            .environment(\.layoutDirection, .leftToRight)
            .allowsHitTesting(!physicalDeviceActive)
            if showsControls && !physicalDeviceActive { VStack {
                Spacer()
                HStack(spacing: 18) {
                    Button { model.sendNavigation(deviceID: device.id, keycode: 4) } label: { Image(systemName: "chevron.backward") }
                    Button { model.sendNavigation(deviceID: device.id, keycode: 3) } label: { Image(systemName: "circle") }
                    Button { model.sendNavigation(deviceID: device.id, keycode: 187) } label: { Image(systemName: "square.on.square") }
                    Button { model.toggleRecording(deviceID: device.id) } label: {
                        Image(systemName: model.recordingDeviceIDs.contains(device.id) ? "stop.circle.fill" : "record.circle")
                    }
                    if model.hasEnhancedTransport(deviceID: device.id) {
                        Menu {
                            ForEach(model.enhancedDisplaysByDevice[device.id] ?? [ScrcpyDisplay(id: 0, width: nil, height: nil)], id: \.id) { display in
                                Button {
                                    model.selectCaptureTarget(deviceID: device.id, target: .display(id: display.id))
                                } label: {
                                    Text(UserFacingText.displayName(
                                        id: display.id, width: display.width, height: display.height
                                    ))
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
                        }
                        Button { model.rotateDevice(deviceID: device.id) } label: { Image(systemName: "rotate.right") }
                        Button { model.setDisplayPower(deviceID: device.id, on: false) } label: { Image(systemName: "moon.fill") }
                        Button { model.setDisplayPower(deviceID: device.id, on: true) } label: { Image(systemName: "sun.max.fill") }
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding()
            } }
          }
        }
        // The logical device ID stays stable while transport readiness changes.
        // Keying this task by the complete row lets a live LAN -> ADB upgrade
        // start the enhanced session without requiring an app relaunch. The
        // demand check is essential: NSHostingController may keep this view
        // alive briefly after AppKit closes its borderless window, and that
        // stale view must never resurrect the retired media owner.
        .task(id: device) { model.ensureEnhancedSessionForPrimaryDemand(for: device) }
    }

    private var screenCapabilityUnavailableReason: String? {
        guard !model.hasEnhancedTransport(deviceID: device.id) else { return nil }
        return model.capabilityReasonsByDevice[device.id]?["CAPABILITY_SCREEN_CAPTURE"]
    }

    private var screenMediaUnavailable: Bool {
        if model.enhancedScreenInterlocks[device.id] == .mediaUnavailable { return true }
#if !GALAXYBRIDGE_APP_STORE
        if model.hasEnhancedTransport(deviceID: device.id), case .failed = model.enhancedStates[device.id] { return true }
#endif
        return false
    }
}

private struct ScreenVideoLayer: View {
    @ObservedObject var surface: VideoSurfaceModel
    let deviceReady: Bool
    let screenCapabilityUnavailableReason: String?
    let physicalDeviceActive: Bool
    let mediaUnavailable: Bool
    let usesPhoneAppCapture: Bool
    let aspectRatio: CGFloat
    let contentInset: CGFloat
    let videoContentMode: ContentMode

    var body: some View {
        ZStack {
            MetalVideoSurface(model: surface)
                .environment(\.layoutDirection, .leftToRight)
                .aspectRatio(aspectRatio, contentMode: videoContentMode)
                .padding(contentInset)
                .clipped()

            if let placeholder {
                ScreenStreamPlaceholderView(
                    placeholder: placeholder,
                    usesPhoneAppCapture: usesPhoneAppCapture
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: placeholder)
    }

    private var placeholder: ScreenStreamPlaceholder? {
        ScreenStreamPlaceholderResolver.resolve(
            deviceReady: deviceReady,
            hasFrame: surface.hasFrame,
            screenCapabilityUnavailableReason: screenCapabilityUnavailableReason,
            protectedContentSuspected: surface.protectedContentSuspected,
            physicalDeviceActive: physicalDeviceActive,
            mediaUnavailable: mediaUnavailable
        )
    }
}

private struct ScreenStreamPlaceholderView: View {
    let placeholder: ScreenStreamPlaceholder
    let usesPhoneAppCapture: Bool

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                if placeholder == .waitingForFirstFrame {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .light))
                }
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)
            .frame(maxWidth: 420)
        }
        .foregroundStyle(.white.opacity(0.86))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch placeholder {
        case .deviceUnavailable: "iphone.slash"
        case .mediaProjectionConsentRequired, .capabilityUnavailable: "rectangle.slash"
        case .protectedContent: "eye.slash"
        case .waitingForFirstFrame: "rectangle.inset.filled"
        case .physicalDeviceActive: "lock.fill"
        case .mediaUnavailable: "rectangle.slash"
        }
    }

    private var title: String {
        switch placeholder {
        case .deviceUnavailable:
            UserFacingText.connectionStatus(
                isReady: false,
                usesPhoneApp: usesPhoneAppCapture
            )
        case .mediaProjectionConsentRequired: UserFacingText.localized("SCREEN_PERMISSION_REQUIRED")
        case .capabilityUnavailable: UserFacingText.localized("SCREEN_CAPTURE_UNAVAILABLE")
        case .protectedContent: UserFacingText.localized("PROTECTED_CONTENT_TITLE")
        case .waitingForFirstFrame: UserFacingText.localized("READY_TO_STREAM")
        case .physicalDeviceActive: UserFacingText.localized("PHYSICAL_DEVICE_ACTIVE_TITLE")
        case .mediaUnavailable: UserFacingText.localized("MEDIA_UNAVAILABLE_TITLE")
        }
    }

    private var detail: String? {
        switch placeholder {
        case .deviceUnavailable: UserFacingText.localized("PHONE_CONNECTION_HINT")
        case .mediaProjectionConsentRequired: UserFacingText.localized("SCREEN_PERMISSION_HINT")
        case .capabilityUnavailable: UserFacingText.localized("SCREEN_CAPTURE_UNAVAILABLE_HINT")
        case .protectedContent: UserFacingText.localized("PROTECTED_CONTENT_HINT")
        case .waitingForFirstFrame: UserFacingText.localized("SCREEN_WAITING_FIRST_FRAME")
        case .physicalDeviceActive: UserFacingText.localized("PHYSICAL_DEVICE_ACTIVE_HINT")
        case .mediaUnavailable: UserFacingText.localized("MEDIA_UNAVAILABLE_HINT")
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private struct NotificationsPanel: View {
    @EnvironmentObject private var model: AppModel
    let deviceID: String

    var body: some View {
        VStack(spacing: 0) {
            notificationAuthorizationBanner
            let notifications = model.notifications(for: deviceID)
            if notifications.isEmpty {
                VStack {
                    NotificationFiltersMenu(deviceID: deviceID)
                    PlaceholderPanel(symbol: "bell", title: "NOTIFICATIONS_PANEL",
                        message: model.companionIsConnected(deviceID: deviceID) ? "NOTIFICATIONS_EMPTY_HINT" : "PANEL_CONNECT_HINT")
                }
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    NotificationFiltersMenu(deviceID: deviceID)
                        .padding(.horizontal, 12)
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 280, maximum: 380),
                                    spacing: 12,
                                    alignment: .top
                                )
                            ],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(notifications) { notification in
                                NotificationCard(deviceID: deviceID, notification: notification)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var notificationAuthorizationBanner: some View {
        switch MacNotificationAuthorizationPresentation.resolve(model.notificationAuthorizationState) {
        case .hidden:
            EmptyView()
        case .requesting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("NATIVE_NOTIFICATIONS_REQUESTING")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        case .settingsRequired:
            HStack(spacing: 12) {
                Image(systemName: "bell.badge")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NATIVE_NOTIFICATIONS_REQUIRED").font(.headline)
                    Text("NATIVE_NOTIFICATIONS_REQUIRED_HINT")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("OPEN_NOTIFICATION_SETTINGS") {
                    if !NSWorkspace.shared.open(MacNotificationSettingsDestination.url) {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: "/System/Applications/System Settings.app")
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

private struct NotificationFiltersMenu: View {
    @EnvironmentObject private var model: AppModel
    let deviceID: String

    var body: some View {
        let muted = model.mutedPackages(for: deviceID).sorted()
        Menu("FILTERS") {
            if muted.isEmpty {
                Text("NO_MUTED_APPS")
            } else {
                ForEach(muted, id: \.self) { packageName in
                    Button {
                        model.toggleNotificationPackage(deviceID: deviceID, packageName: packageName)
                    } label: {
                        Label(packageName, systemImage: "bell")
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
    }
}

private struct FilesPanel: View {
    @EnvironmentObject private var model: AppModel
    let deviceID: String
    @State private var isImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 16) {
            Image(systemName: "folder.badge.plus").font(.system(size: 34)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text("FILES_PANEL").font(.headline)
                if let status = model.fileTransferStatus[deviceID] {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("FILES_SEND_HINT").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.hasPendingFiles(deviceID: deviceID) {
                Button("WIFI_SETUP_TRY_AGAIN") { model.retryFileTransfers(deviceID: deviceID) }
                Button("CANCEL") { model.cancelFileTransfers(deviceID: deviceID) }
            }
            Button("FILES_CHOOSE_FILE") { isImporterPresented = true }
                .buttonStyle(.borderedProminent)
        }
#if !GALAXYBRIDGE_APP_STORE
            Divider()
            Label("FILES_FROM_PHONE", systemImage: "arrow.down.doc").font(.headline)
            if model.hasIncomingDownloadsSelection {
                HStack {
                    Label("FILES_RECEIVE_FOLDER_SELECTED", systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("FILES_RECEIVE_RESELECT") { model.authorizeIncomingDownloads() }.font(.caption)
                }
            } else {
                Button("FILES_RECEIVE_AUTHORIZE") { model.authorizeIncomingDownloads() }
            }
            let rows = model.incomingFilesByDevice[deviceID, default: []]
            if rows.isEmpty {
                Text("FILES_RECEIVE_HINT").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).lineLimit(2)
                            Text(row.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if row.active && row.size > 0 {
                                ProgressView(value: Double(row.received), total: Double(row.size))
                            }
                        }
                        Spacer()
                        if row.active {
                            Button("CANCEL") { model.cancelIncomingFile(deviceID: deviceID, transferID: row.id) }
                        }
                    }
                }
            }
#endif
        }
        .padding(18)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { model.sendFile(deviceID: deviceID, url: url) }
        }
    }
}

private struct CameraPanel: View {
    @EnvironmentObject private var model: AppModel
    let deviceID: String
    @State private var cameraID = "back"
    @State private var resolution = CameraResolution.fullHD
    @State private var framesPerSecond: UInt32 = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CAMERA_PANEL").font(.headline)
                    Text(LocalizedStringKey(cameraHintKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                preview
                if !model.canStartCamera(deviceID: deviceID) {
                    Text("PANEL_CONNECT_HINT").font(.caption).foregroundStyle(.secondary)
                }
                statusNotice
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 12) {
                        lensPicker.fixedSize(horizontal: true, vertical: false)
                        resolutionPicker.fixedSize(horizontal: true, vertical: false)
                        frameRatePicker.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        cameraActions.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        lensPicker
                        resolutionPicker
                        frameRatePicker
                        cameraActions
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var preview: some View {
        MetalVideoSurface(model: model.cameraSurface(for: deviceID))
            .environment(\.layoutDirection, .leftToRight)
            .frame(width: 320, height: 180)
            .clipped()
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusNotice: some View {
        if let status = model.cameraStatusesByDevice[deviceID] {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.symbolName)
                    .foregroundStyle(status.isFailure ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(status.titleKey))
                        .font(.callout.weight(.semibold))
                    if let detailKey = cameraDetailKey(status.detailKey) {
                        Text(LocalizedStringKey(detailKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var lensPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CAMERA_LENS").font(.caption).foregroundStyle(.secondary)
            Picker("CAMERA_LENS", selection: $cameraID) {
                Text("CAMERA_BACK").tag("back")
                Text("CAMERA_FRONT").tag("front")
            }
            .labelsHidden()
            .accessibilityLabel(Text("CAMERA_LENS"))
            .frame(minWidth: 140)
        }
    }

    private var resolutionPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CAMERA_RESOLUTION").font(.caption).foregroundStyle(.secondary)
            Picker("CAMERA_RESOLUTION", selection: $resolution) {
                ForEach(CameraResolution.allCases) { value in Text(value.label).tag(value) }
            }
            .labelsHidden()
            .accessibilityLabel(Text("CAMERA_RESOLUTION"))
            .frame(minWidth: 140)
        }
    }

    private var frameRatePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CAMERA_FPS").font(.caption).foregroundStyle(.secondary)
            Picker("CAMERA_FPS", selection: $framesPerSecond) {
                Text(UserFacingText.formatted("CAMERA_FPS_VALUE", UInt32(24))).tag(UInt32(24))
                Text(UserFacingText.formatted("CAMERA_FPS_VALUE", UInt32(30))).tag(UInt32(30))
                Text(UserFacingText.formatted("CAMERA_FPS_VALUE", UInt32(60))).tag(UInt32(60))
            }
            .labelsHidden()
            .accessibilityLabel(Text("CAMERA_FPS"))
            .frame(minWidth: 120)
        }
    }

    private var cameraActions: some View {
        HStack(spacing: 8) {
            Button("CAMERA_START") {
                model.configureCamera(
                    deviceID: deviceID,
                    enabled: true,
                    cameraID: cameraID,
                    width: resolution.width,
                    height: resolution.height,
                    framesPerSecond: framesPerSecond
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStartCamera(deviceID: deviceID))
            Button("CAMERA_STOP") { model.configureCamera(deviceID: deviceID, enabled: false) }
                .buttonStyle(.bordered)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var cameraHintKey: String {
#if GALAXYBRIDGE_APP_STORE
        "CAMERA_SYSTEM_HINT"
#else
        "CAMERA_DIRECT_PREVIEW_HINT"
#endif
    }

    private func cameraDetailKey(_ key: String?) -> String? {
#if GALAXYBRIDGE_APP_STORE
        key
#else
        key == "CAMERA_STATUS_STREAMING_DETAIL" ? "CAMERA_DIRECT_STREAMING_DETAIL" : key
#endif
    }

    private enum CameraResolution: String, CaseIterable, Identifiable {
        case hd
        case fullHD
        case qhd

        var id: String { rawValue }
        var width: UInt32 { self == .hd ? 1_280 : self == .fullHD ? 1_920 : 2_560 }
        var height: UInt32 { self == .hd ? 720 : self == .fullHD ? 1_080 : 1_440 }
        var label: String { "\(width)×\(height)" }
    }
}

private struct SMSPanel: View {
    @EnvironmentObject private var model: AppModel
    let deviceID: String
    @State private var address = ""
    @State private var bodyText = ""

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                switch SMSPanelPresentationPolicy.mode(for: model.smsAccess(deviceID: deviceID)) {
                case .directComposer:
                    HStack {
                        TextField("SMS_ADDRESS", text: $address).frame(width: 150)
                        TextField("SMS_MESSAGE", text: $bodyText)
                        Button("SEND") {
                            if model.sendSMS(deviceID: deviceID, address: address, body: bodyText) {
                                bodyText = ""
                            }
                        }
                        .disabled(address.isEmpty || bodyText.isEmpty)
                        Button("CALL_DIAL") { model.controlCall(deviceID: deviceID, state: .dialing, address: address) }
                            .disabled(address.isEmpty)
                    }
                case .notificationReplies:
                    notificationReplyNotice
                case .unavailable:
                    unavailableNotice
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.smsByDevice[deviceID, default: []].prefix(20)) { sms in
                            HStack(alignment: .top) {
                                Image(systemName: sms.outgoing ? "arrow.up.right.message" : "arrow.down.left.message")
                                VStack(alignment: .leading) {
                                    Text(sms.address).font(.caption).foregroundStyle(.secondary)
                                    Text(sms.body).font(.caption).lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            if let call = model.callByDevice[deviceID], call.state != .idle, call.state != .ended {
                Divider()
                VStack(spacing: 6) {
                    Text(call.displayName.isEmpty ? call.address : call.displayName).font(.headline)
                    Text(UserFacingText.callStateName(rawValue: call.state.rawValue)).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if call.state == .ringing {
                            Button("CALL_ANSWER") {
                                model.controlCall(deviceID: deviceID, state: .active, callID: call.id)
                            }
                        }
                        Button("CALL_END") {
                            model.controlCall(deviceID: deviceID, state: .ended, callID: call.id)
                        }
                    }
                }
                .frame(width: 160)
            } else if let history = model.callHistoryByDevice[deviceID], !history.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        Text("CALL_HISTORY").font(.headline)
                        ForEach(history.prefix(10)) { call in
                            HStack {
                                Image(systemName: call.incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                                VStack(alignment: .leading) {
                                    Text(call.displayName.isEmpty ? call.address : call.displayName).font(.caption)
                                    Text(call.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(width: 210)
            }
        }
        .padding(12)
    }

    private var notificationReplyNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "message.badge")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("SMS_NOTIFICATION_REPLY_TITLE").font(.headline)
                Text("SMS_NOTIFICATION_REPLY_HINT").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var unavailableNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "message.badge.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("SMS_UNAVAILABLE_TITLE").font(.headline)
                Text("SMS_UNAVAILABLE_HINT").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct NotificationCard: View {
    @EnvironmentObject private var model: AppModel
    let deviceID: String
    let notification: BridgeNotificationRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                notificationIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(notification.appLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(notification.postedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    model.toggleNotificationPackage(deviceID: deviceID, packageName: notification.packageName)
                } label: { Image(systemName: "bell.slash") }
                .help("MUTE_APP")
                .accessibilityLabel(Text("MUTE_APP"))
                .buttonStyle(.plain)
                Button {
                    model.performNotificationAction(
                        deviceID: deviceID,
                        notificationID: notification.id,
                        actionID: "",
                        dismiss: true
                    )
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("CLOSE"))
                .disabled(!model.canSendNotificationAction(deviceID: deviceID) || isPending)
            }
            if !notification.title.isEmpty {
                Text(notification.title)
                    .font(.headline)
                    .lineLimit(2)
            }
            if notification.body.isEmpty && (notification.title.isEmpty || notification.title == notification.appLabel) {
                Text("NOTIFICATION_CUSTOM_CONTENT")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !notification.body.isEmpty {
                Text(notification.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(notification.actions.prefix(2)) { action in
                notificationAction(action)
            }
            if notification.actions.count > 2 {
                DisclosureGroup("NOTIFICATION_MORE_ACTIONS") {
                    ForEach(notification.actions.dropFirst(2)) { action in
                        notificationAction(action).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            // A saved native response can outlive a phone action/notification revision.
            ForEach(savedActionIDsOutsidePrimaryRows, id: \.self) { actionID in
                replyEditors(actionID: actionID)
            }
            actionStatus(actionID: "")
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 138, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var isPending: Bool { model.notificationActionIsPending(deviceID: deviceID, notificationID: notification.id) }

    private var savedActionIDsOutsidePrimaryRows: [String] {
        let rendered = Set(notification.actions.filter(\.acceptsText).map(\.id))
        return model.notificationSavedReplyActionIDs(deviceID: deviceID, notificationID: notification.id)
            .filter { !rendered.contains($0) }
    }

    @ViewBuilder
    private func notificationAction(_ action: BridgeNotificationActionRow) -> some View {
        if action.acceptsText {
            replyEditors(actionID: action.id)
        } else {
            Button(action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "NOTIFICATION_ACTION_FALLBACK") : action.title) {
                model.performNotificationAction(deviceID: deviceID, notificationID: notification.id, actionID: action.id)
            }
            .disabled(!model.canSendNotificationAction(deviceID: deviceID) || isPending)
            actionStatus(actionID: action.id)
        }
    }

    @ViewBuilder
    private func replyEditors(actionID: String) -> some View {
        ForEach(model.notificationComposeIDs(deviceID: deviceID, notificationID: notification.id, actionID: actionID), id: \.self) { composeID in
            HStack {
                TextField("REPLY", text: replyBinding(actionID: actionID, composeID: composeID))
                Button(sendTitle(actionID: actionID, composeID: composeID)) {
                    model.performNotificationAction(deviceID: deviceID, notificationID: notification.id,
                        actionID: actionID, reply: entry(actionID: actionID, composeID: composeID).draft,
                        composeID: composeID)
                }
                .disabled(entry(actionID: actionID, composeID: composeID).draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !model.canSendNotificationAction(deviceID: deviceID) || isPending)
            }
            actionStatus(actionID: actionID, composeID: composeID)
            if model.notificationActionHasRemovedDraft(deviceID: deviceID, notificationID: notification.id,
                actionID: actionID, composeID: composeID) {
                Text("NOTIFICATION_ACTION_REMOVED_DRAFT").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func entry(actionID: String, composeID: String = "") -> NotificationActionEntry {
        model.notificationActionEntry(deviceID: deviceID, notificationID: notification.id, actionID: actionID, composeID: composeID)
    }

    private func replyBinding(actionID: String, composeID: String) -> Binding<String> {
        Binding(get: { entry(actionID: actionID, composeID: composeID).draft }, set: {
            model.setNotificationReply($0, deviceID: deviceID, notificationID: notification.id,
                actionID: actionID, composeID: composeID)
        })
    }

    private func sendTitle(actionID: String, composeID: String) -> LocalizedStringKey {
        switch entry(actionID: actionID, composeID: composeID).phase {
        case .unknown, .legacy: "NOTIFICATION_ACTION_RETRY"
        default: "SEND"
        }
    }

    @ViewBuilder
    private func actionStatus(actionID: String, composeID: String = "") -> some View {
        let phase = entry(actionID: actionID, composeID: composeID).phase
        if phase != .idle {
            HStack(spacing: 6) {
                if phase == .pending { ProgressView().controlSize(.small) }
                Text(statusKey(phase)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func statusKey(_ phase: NotificationActionPhase) -> LocalizedStringKey {
        switch phase {
        case .pending: "NOTIFICATION_ACTION_PENDING"
        case .accepted: "NOTIFICATION_ACTION_ACCEPTED"
        case .failed: "NOTIFICATION_ACTION_FAILED"
        case .unknown: "NOTIFICATION_ACTION_UNKNOWN"
        case .legacy: "NOTIFICATION_ACTION_LEGACY"
        case .idle: ""
        }
    }

    @ViewBuilder
    private var notificationIcon: some View {
        if let data = notification.appIconPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

private struct PlaceholderPanel: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}

private enum Panel: String, CaseIterable, Identifiable {
    case applications, files, notifications, sms, camera
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .applications: "APPLICATIONS"
        case .files: "FILES"
        case .notifications: "NOTIFICATIONS"
        case .sms: "SMS"
        case .camera: "CAMERA"
        }
    }
    var symbol: String {
        switch self {
        case .applications: "square.grid.3x3.fill"
        case .files: "folder"
        case .notifications: "bell"
        case .sms: "message"
        case .camera: "camera"
        }
    }
}
