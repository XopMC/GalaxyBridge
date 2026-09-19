import Combine
import CryptoKit
import CoreMedia
import CoreVideo
import Foundation
import AppKit
import GalaxyBridgeCore
import GalaxyBridgeProtocol
import Network
import OSLog
import UniformTypeIdentifiers

private extension DeviceRow {
    var selectionIdentity: DeviceSelectionIdentity {
        DeviceSelectionIdentity(id: id, adbSerial: adbSerial, companionID: companionID)
    }
}

struct BridgeNotificationActionRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let acceptsText: Bool
}

struct BridgeNotificationRow: Identifiable, Hashable, Sendable {
    let id: String
    let packageName: String
    let appLabel: String
    let title: String
    let body: String
    let postedAt: Date
    let actions: [BridgeNotificationActionRow]
    let appIconPNG: Data?
}

struct BridgeSMSRow: Identifiable, Hashable, Sendable {
    let id: String
    let address: String
    let body: String
    let timestamp: Date
    let outgoing: Bool
}

struct BridgeCallRow: Identifiable, Hashable, Sendable {
    let id: String
    let address: String
    let displayName: String
    let state: GBCallState
    let incoming: Bool
    let timestamp: Date
    let durationSeconds: UInt32
    let history: Bool
}

struct NativeNotificationOpenRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let deviceID: String
    let packageName: String
    let appLabel: String
}

struct IncomingFileRow: Identifiable {
    let id: String
    let name: String
    let size: UInt64
    var received: UInt64 = 0
    var status = ""
    var active = true
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [DeviceRow] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published var isPairingPresented = false
    @Published private(set) var enhancedStates: [String: ScrcpySessionState] = [:]
    private var enhancedSessionDiagnostics = EnhancedSessionDiagnostics()
    private let primaryMediaDiagnosticsEnabled: Bool
    // Screen-interlock wiring is intentionally isolated from transport state.
    @Published private(set) var enhancedScreenInterlocks: [String: ScreenInterlockPresentation] = [:]
    @Published private(set) var recordingDeviceIDs: Set<String> = []
    @Published private(set) var activeRecordings: [ActiveRecordingSummary] = []
    @Published private(set) var notificationsByDevice: [String: [BridgeNotificationRow]] = [:]
    @Published private(set) var fileTransferStatus: [String: String] = [:]
    @Published private(set) var incomingFilesByDevice: [String: [IncomingFileRow]] = [:]
    @Published private(set) var smsByDevice: [String: [BridgeSMSRow]] = [:]
    @Published private(set) var callByDevice: [String: BridgeCallRow] = [:]
    @Published private(set) var callHistoryByDevice: [String: [BridgeCallRow]] = [:]
    @Published private(set) var availableCapabilitiesByDevice: [String: Set<String>] = [:]
    @Published private(set) var capabilityReasonsByDevice: [String: [String: String]] = [:]
    @Published private(set) var mutedNotificationPackagesByDevice: [String: Set<String>] = [:]
    @Published private(set) var notificationAuthorizationState: MacNotificationAuthorizationState = .unknown
    @Published private(set) var nativeNotificationOpenRequest: NativeNotificationOpenRequest?
    @Published private(set) var videoAspectRatios: [String: CGFloat] = [:]
    @Published private(set) var enhancedDisplaysByDevice: [String: [ScrcpyDisplay]] = [:]
    @Published private(set) var enhancedCaptureTargets: [String: ScrcpyCaptureTarget] = [:]
    @Published private(set) var applicationCatalogsByDevice: [String: ApplicationCatalogState] = [:]
    @Published private(set) var cameraStatusesByDevice: [String: CameraStatusViewState] = [:]

    let discovery = BonjourDiscovery()
    let pairing = PairingCoordinator()
    let cameraExtension = CameraExtensionManager()
    private var adbRows: [DeviceRow] = []
#if !GALAXYBRIDGE_APP_STORE
    private var adbTopologyRefreshState = ADBTopologyRefreshState()
    private var validatedWirelessSerials = Set<String>()
    private var routedCompanionIPv4ByPeer =
        UserDefaults.standard.dictionary(forKey: "com.xopmc.GalaxyBridge.routed-companion-ipv4") as? [String: String] ?? [:]
    private var companionEndpointFailover = CompanionEndpointFailoverState()
    private var lastRoutedCompanionProbeAt: Date?
#endif
    private var companionClients: [String: CompanionConnections] = [:]
#if !GALAXYBRIDGE_APP_STORE
    private var enhancedADBTouchAccumulators: [String: EnhancedADBTouchAccumulator] = [:]
    private var enhancedADBInputDispatchers: [String: EnhancedADBPositionalInputDispatcher] = [:]
#endif
    private var companionStates: [String: CompanionConnectionState] = [:]
    /// A terminal authentication rejection applies to the trusted phone, not to
    /// one Bonjour/routed endpoint. Otherwise endpoint failover can immediately
    /// start the same rejected session again under a different companion ID.
    private var companionAuthenticationBlockedPeerIDs = Set<String>()
    private var companionEndpoints: [String: NWEndpoint] = [:]
    private var companionDeviceIDs: [String: String] = [:]
    private var companionConnectionBootstrap: CompanionConnectionBootstrap?
#if !GALAXYBRIDGE_APP_STORE
    private var scrcpySessions: [String: ScrcpySession] = [:]
    private let companionTunnels = ADBCompanionTunnelCoordinator()
    private var companionTunnelLeases: [String: ADBCompanionTunnelLease] = [:]
    private var companionTunnelDesired: [String: (scope: String, serial: String)] = [:]
    private var companionTunnelTasks: [String: Task<Void, Never>] = [:]
    private var companionTunnelTokens: [String: UUID] = [:]
    private var enhancedSubscriptions: [ObjectIdentifier: Set<AnyCancellable>] = [:]
    private var enhancedRetirements: [UUID: Task<Void, Never>] = [:]
    private var unsettledEnhancedRetirements: [UUID: ScrcpySession] = [:]
    private var enhancedReconnectTokens: [String: UUID] = [:]
    private var clipboardSessions: [String: ScrcpyClipboardSession] = [:]
    private var clipboardReconnectAttempts: [String: Int] = [:]
    private var clipboardReconnectTasks: [String: Task<Void, Never>] = [:]
#endif
    private var videoSurfaces: [String: VideoSurfaceModel] = [:]
    private var cameraSurfaces: [String: VideoSurfaceModel] = [:]
    let clientSetup = ClientSetupModel()
    private var primaryScreenDemand = PrimaryScreenDemandRegistry()
    private enum AudioVerificationBinding: Equatable, Sendable {
        case enhanced(UUID)
        case companion(String, UInt64, ObjectIdentifier)
    }
    private struct AudioVerificationRequest {
        let attemptID: UUID
        var binding: AudioVerificationBinding?
        var receiptID: UUID?
    }
    private var audioVerificationRequests: [String: AudioVerificationRequest] = [:]
    private var companionAudioVerificationOwners: [String: AudioVerificationBinding] = [:]
    private var recordings = RecordingRegistry<ScreenRecorder>()
    private var recordingFinishes: [UUID: Task<Void, Never>] = [:]
    private struct RecordingAudioSource {
        var id: UUID
        var configuration: RecordingAACConfiguration?
    }
    private var recordingAudioSources: [String: [String: RecordingAudioSource]] = [:]
    private var recordingVideoSources: [String: UUID] = [:]
    private var recordingVerificationAttempts: [UUID: UUID] = [:]
    private var companionVideoSessions: [String: CompanionVideoSession] = [:]
    private var companionCameraSessions: [String: CameraMediaIngress] = [:]
    private var mediaTransportDispatchGates: [String: MediaTransportDispatchGate] = [:]
    private var companionAudioPlayers: [String: AACAudioPlayer] = [:]
    private var companionVideoSizes: [String: CGSize] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private let companionRecoverySupervisor = CompanionLogicalSessionRecoverySupervisor()
    private var terminationAdmission = ApplicationTerminationAdmission()
    private lazy var companionConnectingWatchdog = CompanionConnectingWatchdog { [weak self] companionID in
        self?.handleCompanionConnectingTimeout(companionID: companionID)
    }
#if !GALAXYBRIDGE_APP_STORE
    private var enhancedReconnectAttempts: [String: Int] = [:]
    private var enhancedReconnectTasks: [String: Task<Void, Never>] = [:]
#endif
    private var clipboardHub = ClipboardHubState()
    private var seenClipboardChangeIDs = Set<String>()
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
#if !GALAXYBRIDGE_APP_STORE
    private var clipboardSequence: UInt64 = 1
#endif
    private var pendingTransfers: [String: OutgoingFileTransfer] = [:]
    private let outgoingFileStore = OutgoingFileTransferStore()
#if !GALAXYBRIDGE_APP_STORE
    private let incomingFileStore = IncomingFileTransferStore()
    private var incomingFileTasks: [UUID: Task<Void, Never>] = [:]
    private var incomingFileProofs: [String: UUID] = [:]
    private var incomingFileCancellations = Set<String>()
#endif
    private var filePreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var filePreparationDevices: [UUID: String] = [:]
    private var newFilePreparationIDs = Set<UUID>()
    private var cancelledFilePreparationIDs = Set<UUID>()
    private var finishedFileTransferIDs = Set<String>()
    private var filePeerFingerprints: [String: Data] = [:]
    private var outgoingRestorePeers = Set<String>()
    private var activeFileTransferIDs = Set<String>()
    private var fileChunkTasks: [String: Task<Void, Never>] = [:]
    private var fileChunkTokens: [String: UUID] = [:]
    private var fileCancellationPendingIDs = Set<String>()
    private var fileCancellationTasks: [String: Task<Void, Never>] = [:]
    private var fileRemovalTasks: [UUID: Task<Void, Never>] = [:]
    private var fileVerificationAttempts: [String: UUID] = [:]
    private var fileTransferResumeCoordinator = CompanionFileTransferResumeCoordinator()
#if !GALAXYBRIDGE_APP_STORE
    private lazy var adbIdentityBinder = ADBIdentityBinder(exhaustionHandler: { [weak self] exhaustion in
        Task { @MainActor in
            self?.reportADBBindingExhaustion(attempts: exhaustion.attempts)
        }
    })
#endif
    private var contentCache: EncryptedContentCache?
    private var contentCacheLastInitializationAttempt: Date?
    private var restoredCacheDeviceIDs = Set<String>()
    private lazy var cacheMaintenance = ContentCacheMaintenanceCoordinator(report: { [weak self] notice in
        guard notice.outcome != .durable else { return }
        Task { @MainActor in
            self?.lastError = String(localized: "CONTENT_CACHE_DURABILITY_UNKNOWN")
        }
    })
    private lazy var cameraFailures: CameraFailureDelivery = CameraFailureDelivery { [weak self] message, permit in
        // Retirement completion has its own scoped observer below. A delayed
        // publisher/decoder error must not clear or overwrite a newer owner.
        guard let self, let permit, self.cameraPublication.currentPermit === permit else { return }
        if !permit.isAdmitted {
            self.retireCamera(permit: permit, reason: .publicationFailure)
        }
        self.lastError = message
    }
    private lazy var cameraTransitions: CameraPublicationTransitionDelivery = CameraPublicationTransitionDelivery { [weak self] permit in
        guard let self else { return }
        if self.cameraLifecyclesByDevice[permit.deviceID] === permit,
           !permit.isAdmitted, self.cameraPublication.currentPermit === permit {
            self.retireCamera(permit: permit, reason: permit.lifecycle.retirementReason ?? .publicationFailure)
        }
        let statuses = CameraStatusViewState.resolveRetained(
            remoteStatuses: self.cameraRemoteStatusesByDevice,
            localStates: self.cameraLifecyclesByDevice.mapValues(\.lifecycle))
        for (deviceID, status) in statuses { self.cameraStatusesByDevice[deviceID] = status }
    }
    private lazy var cameraPublication: CameraPublication = CameraPublication(
        transition: { [cameraTransitions] permit in cameraTransitions.submit(permit) },
        failure: { [cameraFailures] error, permit in cameraFailures.report(error, permit: permit) }
    )
    private var cameraRetirementsByDevice: [String: (permit: CameraPublicationPermit, barrier: CameraRetirement)] = [:]
    // Only the latest explicit attempt per live device; pending cleanup retains
    // its own original permit. No request/attempt history is accumulated.
    private var cameraLifecyclesByDevice: [String: CameraPublicationPermit] = [:]
    private var cameraRemoteStatusesByDevice: [String: CameraRemoteStatus] = [:]
    private let macNotifications = MacNotificationBridge()
    private let gamepadBridge = GamepadBridge()
    private var gamepadTargets: [UInt16: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var applicationSessionLeases = ApplicationSessionLeaseRegistry()
    private var cameraRequestIDsByDevice: [String: String] = [:]
    private let companionLifecycleLogger = Logger(
        subsystem: "com.xopmc.GalaxyBridge",
        category: "CompanionLifecycle"
    )

    init() {
        primaryMediaDiagnosticsEnabled = PrimaryMediaDiagnostics.isEnabled(
            arguments: ProcessInfo.processInfo.arguments, bundleID: Bundle.main.bundleIdentifier
        )
        CompanionLifecycleEvents.pairingStoredPublisher()
            .sink { [cacheMaintenance] event in
                guard let peer = event.object as? PairedPeer,
                      let occurrence = event.userInfo?["cachePromotionOccurrence"] as? UUID else { return }
                cacheMaintenance.invalidateDevice("device:\(peer.deviceID)", occurrence: occurrence)
            }
            .store(in: &cancellables)
        companionConnectionBootstrap = CompanionConnectionBootstrap { [weak self] peer in
            guard let self else { return }
            companionAuthenticationBlockedPeerIDs.remove(peer.deviceID)
            restoredCacheDeviceIDs.remove("device:\(peer.deviceID)")
            mergeDevices()
        }
        gamepadBridge.eventHandler = { [weak self] event in
            Task { @MainActor in self?.handleGamepadEvent(event) }
        }
        macNotifications.responseHandler = { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                if response.opensApplication,
                   let packageName = response.packageName,
                   let appLabel = response.appLabel {
                    self.selectedDeviceID = response.deviceID
                    self.nativeNotificationOpenRequest = .init(
                        deviceID: response.deviceID,
                        packageName: packageName,
                        appLabel: appLabel
                    )
                } else {
                    self.performNotificationAction(
                        deviceID: response.deviceID,
                        notificationID: response.notificationID,
                        actionID: response.actionID,
                        reply: response.reply,
                        dismiss: response.dismiss
                    )
                }
            }
        }
        macNotifications.authorizationStateHandler = { [weak self] state in
            Task { @MainActor in
                self?.notificationAuthorizationState = state
            }
        }
        macNotifications.submissionResultHandler = { [weak self] result in
            guard case let .failed(failure) = result else { return }
            let detail = failure.diagnosticDetail
            Task { @MainActor in
                guard let self else { return }
                self.lastError = UserFacingText.formatted(
                    "NATIVE_NOTIFICATION_SCHEDULING_FAILED", detail
                )
            }
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.macNotifications.refreshAuthorizationStatus()
            }
            .store(in: &cancellables)
        macNotifications.requestAuthorization()
        discovery.$companions
            .sink { [weak self] _ in self?.mergeDevices() }
            .store(in: &cancellables)
        discovery.start()
        Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.publishClipboardIfChanged() }
            .store(in: &cancellables)
#if !GALAXYBRIDGE_APP_STORE
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshADBTopology(userInitiated: false)
            }
            .store(in: &cancellables)
#endif
        refresh()
    }

    func refresh() {
        guard terminationAdmission.admitsWork else { return }
#if GALAXYBRIDGE_APP_STORE
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        adbRows = []
        mergeDevices()
        isRefreshing = false
#else
        refreshADBTopology(userInitiated: true)
#endif
    }

#if !GALAXYBRIDGE_APP_STORE
    private func refreshADBTopology(userInitiated: Bool) {
        guard terminationAdmission.admitsWork else { return }
        if !userInitiated,
           Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
           ProcessInfo.processInfo.arguments.contains("--qa-freeze-adb-topology") {
            return
        }
        // Internal hardware QA can isolate Companion LAN without disabling
        // Wireless Debugging on the phone or modifying the user's ADB setup.
        if Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
           ProcessInfo.processInfo.arguments.contains("--companion-only") {
            if userInitiated { mergeDevices() }
            return
        }
        if userInitiated { adbIdentityBinder.retryAllExhausted() }
        guard adbTopologyRefreshState.begin() else { return }
        if userInitiated {
            isRefreshing = true
            lastError = nil
        }
        let shouldProbeRoutedCompanions = lastRoutedCompanionProbeAt.map {
            Date().timeIntervalSince($0) >= 10
        } ?? true
        let qaADBSerialOverride = Self.qaADBSerialOverride
        let qaExcludedADBSerials = Self.qaExcludedADBSerials
        let qaExcludedDeviceIDs = Self.qaExcludedDeviceIDs
        let alreadyValidatedWirelessSerials = validatedWirelessSerials
        if shouldProbeRoutedCompanions { lastRoutedCompanionProbeAt = Date() }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let client = try ADBClient()
                    var devices = try client.devices()
                    let bindingStore = ADBBindingStore()
                    let bindingRecords = (try? bindingStore.records()) ?? []
                    let peers = ((try? PairedPeerStore().peers()) ?? []).filter {
                        !qaExcludedDeviceIDs.contains($0.deviceID.lowercased())
                    }
                    func routeIsExcluded(_ serial: String) -> Bool {
                        let record = bindingRecords.first(where: { $0.adbSerial == serial })
                        return ADBHardwareQAIsolationPolicy.routeIsExcluded(
                            serial: serial,
                            requiredSerial: qaADBSerialOverride,
                            boundHardwareSerial: record?.hardwareSerial,
                            boundDeviceID: record?.deviceID,
                            excludedSerials: qaExcludedADBSerials,
                            excludedDeviceIDs: qaExcludedDeviceIDs
                        )
                    }
                    devices.removeAll { routeIsExcluded($0.serial) }
                    if shouldProbeRoutedCompanions {
                        let known = bindingRecords.compactMap { record -> WirelessADBReconnectPeer? in
                            guard !qaExcludedADBSerials.contains(record.adbSerial),
                                  !qaExcludedADBSerials.contains(record.hardwareSerial ?? ""),
                                  !qaExcludedDeviceIDs.contains(record.deviceID.lowercased())
                            else { return nil }
                            guard let peer = peers.first(where: { $0.deviceID == record.deviceID }),
                                  bindingStore.isVerified(serial: record.adbSerial, peer: peer),
                                  WirelessADBReconnectPolicy.isLocalEndpoint(record.adbSerial)
                            else { return nil }
                            return WirelessADBReconnectPeer(deviceID: record.deviceID, endpoint: record.adbSerial,
                                hardwareSerial: record.hardwareSerial, verifiedAt: record.verifiedAt)
                        }
                        if !known.isEmpty {
                            let targets = WirelessADBReconnectPolicy.candidates(
                                peers: known,
                                connectedSerials: Set(devices.filter { $0.state == .device }.map(\.serial)),
                                mdnsServices: (try? client.mdnsServices()) ?? ""
                            )
                            for endpoint in targets { _ = try? client.connect(endpoint: endpoint) }
                            if !targets.isEmpty {
                                devices = try client.devices()
                                devices.removeAll { routeIsExcluded($0.serial) }
                            }
                        }
                    }
                    // Reconnect probing may refresh the complete adb topology.
                    // Apply the Internal hardware-QA selector only after that
                    // final refresh so a second connected phone cannot replace
                    // the requested route during an isolated measurement.
                    if let qaADBSerialOverride {
                        devices = devices.filter { $0.serial == qaADBSerialOverride }
                    }
                    let rows = devices.map(Self.row(from:))
                    var restoredWirelessSerials = Set<String>()
                    for device in devices where device.state == .device && device.transport == .wirelessADB {
                        guard !alreadyValidatedWirelessSerials.contains(device.serial),
                              let record = try? bindingStore.record(for: device.serial),
                              let peer = peers.first(where: { $0.deviceID == record.deviceID })
                        else { continue }
                        let currentHardwareSerial = try? client.hardwareSerial(serial: device.serial)
                        if PersistedWirelessADBBindingPolicy.canRestoreTrustedRoute(
                            identityBindingIsVerified: bindingStore.isVerified(serial: device.serial, peer: peer),
                            storedHardwareSerial: record.hardwareSerial,
                            currentHardwareSerial: currentHardwareSerial
                        ) {
                            restoredWirelessSerials.insert(device.serial)
                        }
                    }
                    var routedAddresses: [String: String] = [:]
                    if shouldProbeRoutedCompanions {
                        for device in devices where device.state == .device {
                            guard let record = try? bindingStore.record(for: device.serial),
                                  let address = try? client.wifiIPv4Address(serial: device.serial)
                            else { continue }
                            routedAddresses[record.deviceID] = address
                        }
                    }
                    return (rows, routedAddresses, restoredWirelessSerials)
                }.value
                guard terminationAdmission.admitsWork else {
                    adbTopologyRefreshState.finish()
                    if userInitiated { isRefreshing = false }
                    return
                }
                var shouldMerge = ADBTopologyRefreshState.shouldPublish(
                    previous: adbRows,
                    current: result.0
                )
                adbRows = result.0
                validatedWirelessSerials.formIntersection(Set(adbRows.filter(\.isReady).compactMap(\.adbSerial)))
                if !result.2.isSubset(of: validatedWirelessSerials) {
                    shouldMerge = true
                }
                validatedWirelessSerials.formUnion(result.2)
                if shouldProbeRoutedCompanions, !result.1.isEmpty {
                    let mergedAddresses = routedCompanionIPv4ByPeer.merging(result.1) { _, current in current }
                    if mergedAddresses != routedCompanionIPv4ByPeer {
                        routedCompanionIPv4ByPeer = mergedAddresses
                        UserDefaults.standard.set(
                            mergedAddresses,
                            forKey: "com.xopmc.GalaxyBridge.routed-companion-ipv4"
                        )
                        shouldMerge = true
                    }
                }
                if shouldMerge { mergeDevices() }
                // A signed response can be lost after the topology stabilizes.
                // Reconcile every completed poll; the binder applies bounded per-alias backoff.
                for companionID in companionClients.keys { reconcileADBBindings(for: companionID) }
            } catch {
                guard terminationAdmission.admitsWork else {
                    adbTopologyRefreshState.finish()
                    if userInitiated { isRefreshing = false }
                    return
                }
                if !adbRows.isEmpty {
                    adbRows = []
                    mergeDevices()
                }
                for companionID in companionClients.keys { reconcileADBBindings(for: companionID) }
                if userInitiated { lastError = error.localizedDescription }
            }
            adbTopologyRefreshState.finish()
            if userInitiated { isRefreshing = false }
        }
    }
#endif

    func shutdownForApplicationTermination() async {
        guard terminationAdmission.begin() else { return }
#if !GALAXYBRIDGE_APP_STORE
        ADBOwnedRuntime.shared.beginShutdown()
#endif
        let cacheShutdown = cacheMaintenance.beginShutdown()
        for id in Array(audioVerificationRequests.keys) { cancelAudioVerification(deviceID: id) }
        clientSetup.invalidateAll()
        for task in fileChunkTasks.values { task.cancel() }
        primaryScreenDemand.removeAllDemand()
        let preparingFiles = Array(filePreparationTasks.values)
        for task in preparingFiles { task.cancel() }
        companionRecoverySupervisor.beginApplicationTermination()
        // Close every callback and timer admission point before the first
        // awaited cleanup. An in-flight topology result must not recreate a
        // clipboard or screen session while termination is draining its owner.
        cancellables.removeAll()
        pairing.stop()
        discovery.stop()
#if !GALAXYBRIDGE_APP_STORE
        adbIdentityBinder.shutdown()
        for task in clipboardReconnectTasks.values { task.cancel() }
        clipboardReconnectTasks.removeAll()
        clipboardReconnectAttempts.removeAll()
        let retiringClipboardSessions = Array(clipboardSessions.values)
        clipboardSessions.removeAll()
        for task in enhancedReconnectTasks.values { task.cancel() }
        enhancedReconnectTasks.removeAll()
        let enhancedSessions = Array(scrcpySessions.values)
        scrcpySessions.removeAll()
        enhancedSubscriptions.removeAll()
        let retiringEnhancedSessions = Array(enhancedRetirements.values)
#endif
        for connections in companionClients.values { connections.cancelAll() }
        companionClients.removeAll()
        let cameraRetirement = cameraPublication.shutdown()
        for deviceID in cameraLifecyclesByDevice.keys { refreshCameraStatus(deviceID: deviceID) }
        for ingress in companionCameraSessions.values { ingress.invalidate() }
        companionCameraSessions.removeAll()
        for surface in cameraSurfaces.values { surface.clearCameraFrame() }
        for recording in activeRecordings { stopRecording(id: recording.id) }
        let pendingRecordingFinishes = Array(recordingFinishes.values)
#if !GALAXYBRIDGE_APP_STORE
        for session in retiringClipboardSessions {
            await session.stopAndWait()
        }
        for session in enhancedSessions {
            await session.stopAndWaitForCleanup()
        }
        for retirement in retiringEnhancedSessions { await retirement.value }
#endif
        if case let .failure(error) = await cameraRetirement.wait() {
            // The publication service also logs this before termination replies.
            lastError = error.localizedDescription
        }
        for finish in pendingRecordingFinishes { await finish.value }
        for preparation in preparingFiles { await preparation.value }
        for cancellation in Array(fileCancellationTasks.values) { await cancellation.value }
        for removal in Array(fileRemovalTasks.values) { await removal.value }
#if !GALAXYBRIDGE_APP_STORE
        for incoming in Array(incomingFileTasks.values) { await incoming.value }
        await incomingFileStore.shutdown()
#endif
        await cacheShutdown.wait()
#if !GALAXYBRIDGE_APP_STORE
        do { try await companionTunnels.shutdown() }
        catch { lastError = String(localized: "FILE_CONNECTION_LOST") }
        for task in Array(companionTunnelTasks.values) { await task.value }
        companionTunnelLeases.removeAll()
        companionTunnelTasks.removeAll()
        await Task.detached(priority: .utility) { ADBOwnedRuntime.shared.shutdown() }.value
#endif
    }

    func row(id: String?) -> DeviceRow? {
        devices.first { $0.id == id }
    }

    func beginPairing() {
        isPairingPresented = true
        pairing.start()
    }

    func endPairing() {
        pairing.stop()
        isPairingPresented = false
        refresh()
    }

    func canRevokePairing(deviceID: String) -> Bool {
        deviceID.removingPrefix("device:") != nil
    }

    func revokePairing(deviceID: String) {
        guard let peerID = deviceID.removingPrefix("device:") else { return }
        cacheMaintenance.invalidateDevice(deviceID, revoke: true)
        cancelAudioVerification(deviceID: deviceID)
        clientSetup.invalidate(deviceID: deviceID)
        do { try clientSetup.forget(deviceID: deviceID) }
        catch { lastError = String(localized: "CLIENT_SETUP_SAVE_FAILED") }
        primaryScreenDemand.revoke(deviceID)
        recordingVideoSources.removeValue(forKey: deviceID)
        recordingAudioSources.removeValue(forKey: deviceID)
#if !GALAXYBRIDGE_APP_STORE
        if let fingerprint = filePeerFingerprints[deviceID] {
            retireIncomingFileOwner(deviceID: deviceID, fingerprint: fingerprint)
        }
#endif
        incomingFilesByDevice.removeValue(forKey: deviceID)
        filePeerFingerprints.removeValue(forKey: deviceID)
        retireCamera(deviceID: deviceID, reason: .pairingRevoked)
        do {
            detachGamepads(from: deviceID)
#if !GALAXYBRIDGE_APP_STORE
            adbIdentityBinder.retire(peerID: peerID)
            companionTunnelDesired.removeValue(forKey: deviceID)
            if let lease = companionTunnelLeases.removeValue(forKey: deviceID) {
                Task { [companionTunnels] in try? await companionTunnels.revoke(peerID: lease.peerID) }
            }
            retireCompanionTunnelRoute(deviceID: deviceID)
            enhancedReconnectTasks.removeValue(forKey: deviceID)?.cancel()
            enhancedReconnectAttempts.removeValue(forKey: deviceID)
            retireEnhancedScreenSession(deviceID: deviceID)
            enhancedStates[deviceID] = .stopped
            enhancedSessionDiagnostics.remove(deviceID: deviceID)
            enhancedScreenInterlocks.removeValue(forKey: deviceID)
#endif

            let companionIDs = companionClients.compactMap { key, connections in
                connections.control.peer.deviceID == peerID ? key : nil
            }
            for companionID in companionIDs {
                companionConnectingWatchdog.forget(companionID: companionID)
                companionRecoverySupervisor.forget(companionID: companionID)
                companionRecoverySupervisor.cancelDelayedRetry(companionID: companionID)
                reconnectAttempts.removeValue(forKey: companionID)
                companionStates[companionID] = .disconnected
                companionClients.removeValue(forKey: companionID)?.cancelAll()
            }

            companionVideoSessions.removeValue(forKey: deviceID)?.invalidate()
            companionCameraSessions.removeValue(forKey: deviceID)?.invalidate()
            companionAudioVerificationOwners.removeValue(forKey: deviceID)
            companionAudioPlayers.removeValue(forKey: deviceID)?.stop()
            for entry in recordings.remove(deviceID: deviceID) { finishRecording(entry) }
            updateRecordingSummaries()
            for transfer in pendingTransfers.values.filter({ $0.deviceID == deviceID }) {
                finishTransfer(transfer, status: String(localized: "PAIRING_REVOKED"))
            }

            restoredCacheDeviceIDs.remove(deviceID)
#if !GALAXYBRIDGE_APP_STORE
            try ADBBindingStore().revoke(deviceID: peerID)
            companionEndpointFailover.forget(peerID: peerID)
#endif
            try PairedPeerStore().revoke(deviceID: peerID)
            companionConnectionBootstrap?.forget(deviceID: peerID)
            companionAuthenticationBlockedPeerIDs.remove(peerID)

            notificationsByDevice.removeValue(forKey: deviceID)
            smsByDevice.removeValue(forKey: deviceID)
            callByDevice.removeValue(forKey: deviceID)
            callHistoryByDevice.removeValue(forKey: deviceID)
            availableCapabilitiesByDevice.removeValue(forKey: deviceID)
            capabilityReasonsByDevice.removeValue(forKey: deviceID)
            fileTransferStatus.removeValue(forKey: deviceID)
            mutedNotificationPackagesByDevice.removeValue(forKey: deviceID)
            UserDefaults.standard.removeObject(
                forKey: "com.xopmc.GalaxyBridge.notification-filters.\(deviceID)"
            )
            videoSurfaces.removeValue(forKey: deviceID)
            cameraSurfaces.removeValue(forKey: deviceID)
            companionVideoSizes.removeValue(forKey: deviceID)
            videoAspectRatios.removeValue(forKey: deviceID)
            enhancedDisplaysByDevice.removeValue(forKey: deviceID)
            enhancedCaptureTargets.removeValue(forKey: deviceID)
            applicationCatalogsByDevice.removeValue(forKey: deviceID)
            cameraStatusesByDevice.removeValue(forKey: deviceID)
            cameraRequestIDsByDevice.removeValue(forKey: deviceID)
            cameraLifecyclesByDevice.removeValue(forKey: deviceID)
            cameraRemoteStatusesByDevice.removeValue(forKey: deviceID)
            if selectedDeviceID == deviceID { selectedDeviceID = nil }
            mergeDevices()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func videoSurface(for deviceID: String) -> VideoSurfaceModel {
        if let surface = videoSurfaces[deviceID] { return surface }
        let surface = VideoSurfaceModel()
        videoSurfaces[deviceID] = surface
        surface.freshFramePresentationReceipt = { [weak self, weak surface] in
            guard let self, let surface, self.terminationAdmission.admitsWork,
                  let id = self.videoSurfaces.first(where: { $0.value === surface })?.key,
                  self.primaryScreenDemand.hasViewer(id),
                  let attempt = self.clientSetup.currentAttemptID(deviceID: id, feature: .screen) else { return nil }
            return { [weak self, weak surface] in
                guard let self, let surface, self.terminationAdmission.admitsWork,
                      self.videoSurfaces[id] === surface, self.primaryScreenDemand.hasViewer(id) else { return }
                self.clientSetup.recordEvidence(deviceID: id, feature: .screen, attemptID: attempt)
            }
        }
        return surface
    }

    func clientSetupEvidenceReceipt(deviceID: String, feature: ClientSetupFeature) -> (@MainActor @Sendable () -> Void)? {
        guard terminationAdmission.admitsWork,
              let attempt = clientSetup.currentAttemptID(deviceID: deviceID, feature: feature) else { return nil }
        return { [weak self] in
            guard let self, self.terminationAdmission.admitsWork else { return }
            self.clientSetup.recordEvidence(deviceID: deviceID, feature: feature, attemptID: attempt)
        }
    }

    /// ClientSetupView already created the attempt. Opening a mirror alone is
    /// never evidence; bind only the explicit request to the selected audio owner.
    func beginAudioVerification(deviceID: String) {
        for id in Array(audioVerificationRequests.keys) {
            if !audioVerificationIsCurrent(deviceID: id) { cancelAudioVerification(deviceID: id) }
        }
        guard terminationAdmission.admitsWork, primaryScreenDemand.hasViewer(deviceID),
              let attemptID = clientSetup.currentAttemptID(deviceID: deviceID, feature: .audio) else { return }
        if audioVerificationRequests[deviceID]?.attemptID == attemptID {
            armAudioVerificationIfPossible(deviceID: deviceID)
            return
        }
        cancelAudioVerification(deviceID: deviceID)
        guard audioVerificationRequests.count < 8 else {
            clientSetup.cancelVerification(deviceID: deviceID, feature: .audio, attemptID: attemptID)
            return
        }
        audioVerificationRequests[deviceID] = AudioVerificationRequest(attemptID: attemptID)
        armAudioVerificationIfPossible(deviceID: deviceID)
    }

    private func audioVerificationIsCurrent(deviceID: String) -> Bool {
        guard terminationAdmission.admitsWork, primaryScreenDemand.hasViewer(deviceID),
              let request = audioVerificationRequests[deviceID] else { return false }
        return clientSetup.currentAttemptID(deviceID: deviceID, feature: .audio) == request.attemptID
    }

    private func clearAudioVerificationBinding(deviceID: String) {
        companionAudioPlayers[deviceID]?.cancelPlaybackEvidence()
#if !GALAXYBRIDGE_APP_STORE
        scrcpySessions[deviceID]?.cancelPlaybackEvidence()
#endif
        audioVerificationRequests[deviceID]?.binding = nil
        audioVerificationRequests[deviceID]?.receiptID = nil
    }

    private func cancelAudioVerification(deviceID: String) {
        guard let request = audioVerificationRequests[deviceID] else { return }
        clearAudioVerificationBinding(deviceID: deviceID)
        audioVerificationRequests.removeValue(forKey: deviceID)
        clientSetup.cancelVerification(deviceID: deviceID, feature: .audio, attemptID: request.attemptID)
    }

    private func prepareAudioVerificationBinding(deviceID: String, binding: AudioVerificationBinding) -> UUID? {
        guard audioVerificationRequests[deviceID]?.binding != binding else { return nil }
        clearAudioVerificationBinding(deviceID: deviceID)
        let receiptID = UUID()
        audioVerificationRequests[deviceID]?.binding = binding
        audioVerificationRequests[deviceID]?.receiptID = receiptID
        return receiptID
    }

    private func armAudioVerificationIfPossible(deviceID: String) {
        guard audioVerificationRequests[deviceID] != nil else { return }
        guard audioVerificationIsCurrent(deviceID: deviceID) else {
            cancelAudioVerification(deviceID: deviceID)
            return
        }
#if !GALAXYBRIDGE_APP_STORE
        if acceptsScreenMedia(.enhanced, deviceID: deviceID) {
            guard let session = scrcpySessions[deviceID], let owner = session.nativeOwner,
                  owner.attempt.isAdmitted else {
                clearAudioVerificationBinding(deviceID: deviceID)
                return
            }
            let binding = AudioVerificationBinding.enhanced(owner.attempt.id.attemptID)
            guard let receiptID = prepareAudioVerificationBinding(deviceID: deviceID, binding: binding) else { return }
            session.requestPlaybackEvidence(id: receiptID) { [weak self] id in
                self?.completeAudioVerification(deviceID: deviceID, receiptID: id, binding: binding)
            }
            return
        }
#endif
        guard acceptsScreenMedia(.companion, deviceID: deviceID),
              let player = companionAudioPlayers[deviceID],
              case let .companion(companionID, generation, playerID)? = companionAudioVerificationOwners[deviceID],
              ObjectIdentifier(player) == playerID, companionClients[companionID] != nil,
              companionRecoverySupervisor.currentGeneration(companionID: companionID) == generation else {
            clearAudioVerificationBinding(deviceID: deviceID)
            return
        }
        let binding = AudioVerificationBinding.companion(companionID, generation, ObjectIdentifier(player))
        guard let receiptID = prepareAudioVerificationBinding(deviceID: deviceID, binding: binding) else { return }
        player.requestPlaybackEvidence(id: receiptID) { [weak self] id in
            Task { @MainActor in
                self?.completeAudioVerification(deviceID: deviceID, receiptID: id, binding: binding)
            }
        }
    }

    private func completeAudioVerification(deviceID: String, receiptID: UUID, binding: AudioVerificationBinding) {
        guard audioVerificationIsCurrent(deviceID: deviceID),
              let request = audioVerificationRequests[deviceID], request.receiptID == receiptID,
              request.binding == binding else { return }
        switch binding {
        case let .enhanced(sourceID):
#if !GALAXYBRIDGE_APP_STORE
            guard acceptsScreenMedia(.enhanced, deviceID: deviceID),
                  let owner = scrcpySessions[deviceID]?.nativeOwner,
                  owner.attempt.isAdmitted, owner.attempt.id.attemptID == sourceID else { return }
#else
            return
#endif
        case let .companion(id, generation, playerID):
            guard acceptsScreenMedia(.companion, deviceID: deviceID),
                  companionAudioVerificationOwners[deviceID] == binding, companionClients[id] != nil,
                  companionRecoverySupervisor.currentGeneration(companionID: id) == generation,
                  let player = companionAudioPlayers[deviceID], ObjectIdentifier(player) == playerID else { return }
        }
        if clientSetup.recordEvidence(deviceID: deviceID, feature: .audio, attemptID: request.attemptID) {
            clearAudioVerificationBinding(deviceID: deviceID)
            audioVerificationRequests.removeValue(forKey: deviceID)
        }
    }

    func cameraSurface(for deviceID: String) -> VideoSurfaceModel {
        if let surface = cameraSurfaces[deviceID] { return surface }
        let surface = VideoSurfaceModel()
        cameraSurfaces[deviceID] = surface
        return surface
    }

    func loadApplicationCatalog(deviceID: String, force: Bool = false) {
        if !force, case .loading = applicationCatalogsByDevice[deviceID] { return }
        guard let device = row(id: deviceID) else { return }
#if GALAXYBRIDGE_APP_STORE
        applicationCatalogsByDevice[deviceID] = .unavailable(.storeBuildUnsupported)
#else
        guard case .available = ApplicationCatalogPolicy.resolve(
            isStoreBuild: false,
            hasEnhancedTransport: ApplicationCatalogPolicy.hasDirectTransport(adbSerial: device.adbSerial)
        ) else {
            applicationCatalogsByDevice[deviceID] = .unavailable(.directConnectionRequired)
            return
        }
        guard let serial = device.adbSerial else { return }
        applicationCatalogsByDevice[deviceID] = .loading
        Task {
            do {
                let client = ApplicationCatalogEnhancedClient(adb: try ADBClient())
                let items = try await Task.detached(priority: .userInitiated) {
                    try client.load(deviceID: deviceID, serial: serial)
                }.value
                guard row(id: deviceID) != nil else { return }
                applicationCatalogsByDevice[deviceID] = .available(items)
            } catch {
                applicationCatalogsByDevice[deviceID] = .failed(error.localizedDescription)
            }
        }
#endif
    }

    func reserveApplicationWindowSession(_ leaseID: String) -> Bool {
        let reserved = applicationSessionLeases.reserve(leaseID)
        let limitDiagnostic = String(localized: "APPLICATION_WINDOW_LIMIT")
        lastError = ApplicationWindowDiagnosticPolicy.afterReservation(
            reserved: reserved,
            currentDiagnostic: lastError,
            limitDiagnostic: limitDiagnostic
        )
        return reserved
    }

    func releaseApplicationWindowSession(_ leaseID: String) {
        applicationSessionLeases.release(leaseID)
        lastError = ApplicationWindowDiagnosticPolicy.afterRelease(
            currentDiagnostic: lastError,
            limitDiagnostic: String(localized: "APPLICATION_WINDOW_LIMIT")
        )
    }

    func reportApplicationWindowError(_ message: String) {
        lastError = message
    }

    func acceptEnhancedClipboard(deviceID: String, changeID: String, content: Data) {
        acceptRemoteClipboard(
            deviceID: deviceID,
            changeID: changeID,
            kind: .text,
            content: content,
            sensitive: false
        )
    }

    #if !GALAXYBRIDGE_APP_STORE
    func quicWirelessSelection(for device: DeviceRow) -> QuicWirelessSelection? {
        guard QuicRuntimeArtifacts.explicitlyEnabled, device.transport == .wirelessADB, device.isReady,
              let serial = device.adbSerial, validatedWirelessSerials.contains(serial),
              let binding = try? ADBBindingStore().record(for: serial),
              device.id == "device:\(binding.deviceID)" else { return nil }
        return .init(targetToken: UInt64.random(in: 1...UInt64.max))
    }
    #endif

    func ensureEnhancedSession(for device: DeviceRow) {
#if GALAXYBRIDGE_APP_STORE
        return
#else
        releasePhysicallySettledEnhancedRetirements()
        guard terminationAdmission.admitsWork, primaryScreenDemand.canStart(device.id) else { return }
        guard device.transport != .companionLAN, device.isReady else { return }
        if let existing = scrcpySessions[device.id] {
            if case .failed = existing.state { scheduleEnhancedReconnect(deviceID: device.id, session: existing) }
            return
        }
        guard canStartLogicalSession(device.id) else { return }
        guard let serial = device.adbSerial else { return }
        do {
            // Hardware QA can explicitly preserve an unlocked phone's display.
            // This does not alter customer preferences or production behavior.
            let preservePhoneDisplay = Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
                && ProcessInfo.processInfo.arguments.contains("--keep-phone-display-on")
            let session = ScrcpySession(serial: serial, adb: try ADBClient(),
                automaticDisplayManagement: !preservePhoneDisplay,
                primaryDiagnosticsEnabled: primaryMediaDiagnosticsEnabled,
                clipboardPollingEnabled: false,
                quicSelection: quicWirelessSelection(for: device))
            scrcpySessions[device.id] = session
            var subscriptions = Set<AnyCancellable>()
            bindEnhancedNativeFrames(session, deviceID: device.id)
            session.clipboardEventHandler = { [weak self, weak session] update in
                Task { @MainActor in
                    guard let self, let session, let targetID = self.activeEnhancedDeviceID(session) else { return }
                    self.acceptRemoteClipboard(
                        deviceID: targetID,
                        changeID: update.changeID,
                        kind: update.kind == .png ? .png : .text,
                        content: update.content,
                        sensitive: false
                    )
                }
            }
            session.$state.sink { [weak self, weak session] state in
                guard let self, let session, let targetID = self.activeEnhancedDeviceID(session) else { return }
                self.enhancedStates[targetID] = state
                let needsCompanionBootstrap = self.mediaTransportDispatchGate(for: targetID).update(enhancedState: state)
                if targetID != device.id {
                    self.mediaTransportDispatchGate(for: device.id).update(enhancedState: state)
                }
                self.armAudioVerificationIfPossible(deviceID: targetID)
                if needsCompanionBootstrap,
                   let companionID = self.companionID(for: targetID),
                   let generation = self.companionRecoverySupervisor.currentGeneration(companionID: companionID) {
                    // The receive gate discarded LAN's P-frame references
                    // while enhanced was primary. Rejoin the existing capture
                    // with a complete bootstrap, not a new MediaProjection.
                    self.handleCompanionState(companionID: companionID, generation: generation,
                                              channel: .video, state: .disconnected)
                }
                self.lastError = self.enhancedSessionDiagnostics.transition(
                    deviceID: targetID,
                    state: state,
                    currentDiagnostic: self.lastError
                )
                switch state {
                case .streaming:
                    self.enhancedReconnectAttempts[targetID] = 0
                    self.enhancedReconnectTasks.removeValue(forKey: targetID)?.cancel()
                    self.detachGamepads(from: targetID)
                    self.syncGamepadsToSelectedSession()
                    self.loadEnhancedDisplays(deviceID: targetID, serial: serial)
                case .failed:
                    self.cancelAudioVerification(deviceID: targetID)
                    self.clientSetup.invalidate(deviceID: targetID)
                    self.scheduleEnhancedReconnect(deviceID: targetID, session: session)
                case .stopped:
                    self.cancelAudioVerification(deviceID: targetID)
                default:
                    break
                }
                self.mergeDevices()
            }.store(in: &subscriptions)
            // Screen-interlock wiring: publish only presentation state; the
            // ScrcpySession remains the sole owner of power control and probes.
            session.$screenInterlockPresentation.sink { [weak self, weak session] presentation in
                guard let self, let session, let targetID = self.activeEnhancedDeviceID(session) else { return }
                self.enhancedScreenInterlocks[targetID] = presentation
            }.store(in: &subscriptions)
            enhancedSubscriptions[ObjectIdentifier(session)] = subscriptions
            session.start(captureTarget: enhancedCaptureTargets[device.id] ?? .display(id: 0))
        } catch {
            lastError = error.localizedDescription
        }
#endif
    }

    func primaryMirrorDeviceID(for lease: UUID) -> String? {
        primaryScreenDemand.deviceID(for: lease)
    }

    func primaryMirrorDidOpen(_ device: DeviceRow) -> UUID {
        let lease = primaryScreenDemand.acquire(deviceID: device.id, consumer: .viewer)
        ensureEnhancedSession(for: device)
        updateAudioPlaybackDemand(deviceID: device.id)
        return lease
    }

    func ensureEnhancedSessionForPrimaryDemand(for device: DeviceRow) {
        guard primaryScreenDemand.hasViewer(device.id) else { return }
        ensureEnhancedSession(for: device)
    }

    func primaryMirrorDidClose(lease: UUID) {
        guard let deviceID = primaryScreenDemand.release(lease) else { return }
        updateAudioPlaybackDemand(deviceID: deviceID)
#if !GALAXYBRIDGE_APP_STORE
        retireEnhancedScreenSessionIfUndemanded(deviceID: deviceID)
#endif
    }

    private func updateAudioPlaybackDemand(deviceID: String) {
        let enabled = primaryScreenDemand.hasViewer(deviceID)
        if !enabled { cancelAudioVerification(deviceID: deviceID) }
        companionAudioPlayers[deviceID]?.setPlaybackEnabled(enabled)
#if !GALAXYBRIDGE_APP_STORE
        scrcpySessions[deviceID]?.setPlaybackEnabled(enabled)
#endif
    }

#if !GALAXYBRIDGE_APP_STORE
    private func activeEnhancedDeviceID(_ session: ScrcpySession) -> String? {
        guard terminationAdmission.admitsWork,
              let deviceID = scrcpySessions.first(where: { $0.value === session })?.key,
              primaryScreenDemand.hasDemand(deviceID) else { return nil }
        return deviceID
    }

    private func retireEnhancedScreenSessionIfUndemanded(deviceID: String) {
        guard !primaryScreenDemand.hasDemand(deviceID) else { return }
        retireEnhancedScreenSession(deviceID: deviceID)
    }

    private func retireEnhancedScreenSession(deviceID: String) {
        if case .enhanced? = audioVerificationRequests[deviceID]?.binding {
            cancelAudioVerification(deviceID: deviceID)
        }
        enhancedReconnectTasks.removeValue(forKey: deviceID)?.cancel()
        enhancedReconnectAttempts.removeValue(forKey: deviceID)
        detachGamepads(from: deviceID)
        guard let session = scrcpySessions.removeValue(forKey: deviceID) else { return }
        enhancedSubscriptions.removeValue(forKey: ObjectIdentifier(session))
        enhancedStates[deviceID] = .stopped
        _ = mediaTransportDispatchGate(for: deviceID).update(enhancedState: .stopped)
        retireEnhancedScreenSession(session, deviceID: deviceID)
    }

    private func retireEnhancedScreenSession(_ session: ScrcpySession, deviceID: String) {
        let permit = primaryScreenDemand.beginRetirement(deviceID)
        // Stop closes transport/frame admission before returning; the async
        // barrier settles resource acquisition and native work before restart.
        session.stop()
        enhancedRetirements[permit] = Task { [weak self] in
            await session.stopAndWaitForCleanup()
            guard let self else { return }
            self.enhancedRetirements.removeValue(forKey: permit)
            guard session.cleanupPhysicallySettled else {
                self.unsettledEnhancedRetirements[permit] = session
                self.lastError = String(localized: "ERROR_MEDIA_CLEANUP")
                return
            }
            guard let canonicalID = self.primaryScreenDemand.finishRetirement(permit),
                  self.terminationAdmission.admitsWork,
                  let device = self.row(id: canonicalID) else { return }
            self.ensureEnhancedSession(for: device)
        }
    }

    private func releasePhysicallySettledEnhancedRetirements() {
        for (permit, session) in unsettledEnhancedRetirements where session.cleanupPhysicallySettled {
            unsettledEnhancedRetirements.removeValue(forKey: permit)
            _ = primaryScreenDemand.finishRetirement(permit)
        }
    }
#endif

#if !GALAXYBRIDGE_APP_STORE
    private func bindEnhancedNativeFrames(_ session: ScrcpySession, deviceID: String) {
        let surface = videoSurface(for: deviceID)
        session.setPlaybackEnabled(primaryScreenDemand.hasViewer(deviceID))
        session.recordingAudioEventHandler = { [weak self, weak session] event, epoch, sourceID in
            guard let self, let session, self.activeEnhancedDeviceID(session) == deviceID,
                  session.nativeOwner?.attempt.id.attemptID == sourceID else { return }
            self.armAudioVerificationIfPossible(deviceID: deviceID)
            self.receiveRecordingAudio(event, epoch: epoch, sourceID: sourceID,
                                       route: .enhanced, deviceID: deviceID)
        }
        session.ownedDecodedFrameHandler = { [weak self, weak session] frame in
            guard let self, let session, self.activeEnhancedDeviceID(session) == deviceID else {
                if let trace = frame.trace { trace.collector.finish(trace, reason: .dropped) }
                return
            }
            Self.receiveEnhancedNativeFrame(frame, surface: surface,
                admitted: self.acceptsScreenMedia(.enhanced, deviceID: deviceID),
                updateAspect: { ratio in
                    if self.videoAspectRatios[deviceID].map({ abs($0 - ratio) > 0.0005 }) ?? true {
                        self.videoAspectRatios[deviceID] = ratio
                    }
                }, record: {
                    let sourceID = frame.context.attempt.id.attemptID
                    if self.recordingVideoSources[deviceID] != sourceID {
                        // Publish the first frame of a fresh source, not every frame.
                        // A same-size reopen must refresh standard-menu readiness.
                        self.objectWillChange.send()
                        self.recordingVideoSources[deviceID] = sourceID
                    }
                    for recorder in self.recordings.sinks(for: deviceID) {
                        recorder.append(frame.pixelBuffer, presentationTime: frame.presentationTime,
                                        epoch: frame.epoch, sourceID: sourceID)
                    }
                })
        }
    }

    /// The actual final receive body, shared by initial binding and adoption.
    static func receiveEnhancedNativeFrame(_ frame: NativeDecodedFrame, surface: VideoSurfaceModel,
                                           admitted: Bool, updateAspect: (CGFloat) -> Void, record: () -> Void) {
        if let trace = frame.trace { trace.collector.mark(.appModel, trace: trace) }
        guard frame.isAdmitted, admitted else {
            if let trace = frame.trace { trace.collector.finish(trace, reason: .dropped) }
            return
        }
        surface.present(frame.pixelBuffer, presentationTime: frame.presentationTime,
                        epoch: frame.epoch, diagnosticTrace: frame.trace)
        let width = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer))
        if height > 0 { updateAspect(width / height) }
        record()
    }
#endif

    func primaryInputTrace(deviceID: String, receivedAt: Double) -> PrimaryMediaTrace? {
#if GALAXYBRIDGE_APP_STORE
        return nil
#else
        return scrcpySessions[deviceID]?.primaryDiagnostics?.received(
            stream: .control, bytes: 0, pts: nil, epoch: nil, now: receivedAt
        )
#endif
    }

    func sendTouch(
        deviceID: String,
        action: ScrcpyMotionAction,
        normalizedX: Double,
        normalizedY: Double,
        pointerID: UInt64 = ScrcpyControlMessage.virtualFingerPointerID,
        diagnosticTrace: PrimaryMediaTrace? = nil
    ) {
#if !GALAXYBRIDGE_APP_STORE
        if let route = enhancedADBPositionalInputRoute(for: deviceID) {
            var accumulator = enhancedADBTouchAccumulators[deviceID] ?? EnhancedADBTouchAccumulator()
            let command = accumulator.handle(
                action,
                pointerID: pointerID,
                x: normalizedX,
                y: normalizedY
            )
            enhancedADBTouchAccumulators[deviceID] = accumulator
            if let command {
                Task { [weak self] in
                    do {
                        try await route.dispatcher.send(serial: route.serial, command: command)
                    } catch {
                        self?.lastError = error.localizedDescription
                    }
                }
            }
            return
        }
#endif
        if let control = companionPositionalInputControl(for: deviceID) {
            var input = GBInputEvent()
            input.action = switch action {
            case .down: .down
            case .move: .move
            case .up: .up
            case .cancel: .cancel
            }
            input.displayEpoch = row(id: deviceID)?.transport == .companionLAN
                ? (companionVideoSessions[deviceID]?.displayEpoch ?? 0)
                : 0
            input.pointerID = pointerID
            input.normalizedX = Float(normalizedX.clamped(to: 0 ... 1))
            input.normalizedY = Float(normalizedY.clamped(to: 0 ... 1))
            let isReleased = action == .up || action == .cancel
            input.pressure = isReleased ? 0 : 1
            input.buttons = isReleased ? 0 : 1
            do { try control.sendInput(input) } catch { lastError = error.localizedDescription }
            return
        }
#if !GALAXYBRIDGE_APP_STORE
        guard let session = scrcpySessions[deviceID], session.videoSize != .zero else { return }
        let width = UInt16(clamping: Int(session.videoSize.width))
        let height = UInt16(clamping: Int(session.videoSize.height))
        let x = Int32(clamping: Int(normalizedX.clamped(to: 0 ... 1) * Double(max(0, Int(width) - 1))))
        let y = Int32(clamping: Int(normalizedY.clamped(to: 0 ... 1) * Double(max(0, Int(height) - 1))))
        let isReleased = action == .up || action == .cancel
        session.sendControl(
            ScrcpyControlMessage.virtualFingerTouch(
                action: action,
                pointerID: pointerID,
                x: x,
                y: y,
                screenWidth: width,
                screenHeight: height,
                pressure: isReleased ? 0 : 1
            ),
            diagnosticTrace: diagnosticTrace
        )
#endif
    }

    func sendPinch(
        deviceID: String,
        action: ScrcpyMotionAction,
        centerX: Double,
        centerY: Double,
        scale: Double
    ) {
        guard row(id: deviceID)?.transport != .companionLAN else { return }
        let radius = (0.08 * scale.clamped(to: 0.1 ... 4)).clamped(to: 0.01 ... 0.32)
        let leftX = (centerX - radius).clamped(to: 0 ... 1)
        let rightX = (centerX + radius).clamped(to: 0 ... 1)
        // scrcpy reserves -2 for a generic finger and -3 for its virtual second finger.
        sendTouch(
            deviceID: deviceID,
            action: action,
            normalizedX: leftX,
            normalizedY: centerY,
            pointerID: ScrcpyControlMessage.virtualFingerPointerID
        )
        sendTouch(
            deviceID: deviceID,
            action: action,
            normalizedX: rightX,
            normalizedY: centerY,
            pointerID: ScrcpyControlMessage.virtualSecondFingerPointerID
        )
    }

    func sendScroll(
        deviceID: String,
        normalizedX: Double,
        normalizedY: Double,
        horizontal: Double,
        vertical: Double
    ) {
        if let control = companionPositionalInputControl(for: deviceID) {
            var input = GBInputEvent()
            input.action = .scroll
            input.displayEpoch = row(id: deviceID)?.transport == .companionLAN
                ? (companionVideoSessions[deviceID]?.displayEpoch ?? 0)
                : 0
            input.normalizedX = Float(normalizedX.clamped(to: 0 ... 1))
            input.normalizedY = Float(normalizedY.clamped(to: 0 ... 1))
            input.scrollX = Float(horizontal.clamped(to: -16 ... 16))
            input.scrollY = Float(vertical.clamped(to: -16 ... 16))
            do { try control.sendInput(input) } catch { lastError = error.localizedDescription }
            return
        }
#if !GALAXYBRIDGE_APP_STORE
        guard let session = scrcpySessions[deviceID], session.videoSize != .zero else { return }
        let width = UInt16(clamping: Int(session.videoSize.width))
        let height = UInt16(clamping: Int(session.videoSize.height))
        let x = Int32(clamping: Int(normalizedX.clamped(to: 0 ... 1) * Double(max(0, Int(width) - 1))))
        let y = Int32(clamping: Int(normalizedY.clamped(to: 0 ... 1) * Double(max(0, Int(height) - 1))))
        session.sendControl(
            ScrcpyControlMessage.scroll(
                x: x,
                y: y,
                screenWidth: width,
                screenHeight: height,
                horizontal: horizontal,
                vertical: vertical
            )
        )
#endif
    }

    func sendKey(
        deviceID: String,
        action: ScrcpyKeyAction,
        keycode: UInt32,
        repeatCount: UInt32 = 0,
        modifiers: UInt32 = 0
    ) {
        if row(id: deviceID)?.transport == .companionLAN {
            guard action == .down, let control = companionControl(for: deviceID) else { return }
            var input = GBInputEvent()
            input.action = .key
            input.displayEpoch = companionVideoSessions[deviceID]?.displayEpoch ?? 0
            input.androidKeycode = keycode
            input.modifiers = modifiers
            do { try control.sendInput(input) } catch { lastError = error.localizedDescription }
            return
        }
#if !GALAXYBRIDGE_APP_STORE
        if sendEnhancedKeyViaCompanion(
            deviceID: deviceID,
            isDown: action == .down,
            keycode: keycode,
            repeatCount: repeatCount,
            modifiers: modifiers
        ) { return }
        scrcpySessions[deviceID]?.sendKeyboardControl(
            ScrcpyControlMessage.keycode(
                action: action,
                androidKeycode: keycode,
                repeatCount: repeatCount,
                metaState: modifiers
            )
        )
#endif
    }

    @discardableResult
    func sendEnhancedKeyViaCompanion(
        deviceID: String,
        isDown: Bool,
        keycode: UInt32,
        repeatCount: UInt32,
        modifiers: UInt32
    ) -> Bool {
        guard let companionID = companionID(for: deviceID),
              let control = companionControl(for: deviceID)
        else {
            return false
        }

        let available = availableCapabilitiesByDevice[deviceID]
        let inputCode = "CAPABILITY_INPUT_INJECTION"
        guard EnhancedTextInputRoutingPolicy.route(
            companionConnected: companionStates[companionID] == .connected,
            companionCapabilitiesKnown: available != nil,
            companionAdvertisesInput: available?.contains(inputCode) == true,
            companionInputUnavailableReason: capabilityReasonsByDevice[deviceID]?[inputCode]
        ) == .companionAccessibility else { return false }

        // Companion input models one logical key operation on the down edge.
        // Consume the matching up edge too, so it never leaks into scrcpy as a
        // stray release after Accessibility handled the shortcut/navigation.
        guard isDown else { return true }
        var input = GBInputEvent()
        input.action = .key
        input.displayEpoch = 0
        input.androidKeycode = keycode
        input.modifiers = modifiers
        _ = repeatCount
        do {
            try control.sendInput(input)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func sendNavigation(deviceID: String, keycode: UInt32) {
        sendKey(deviceID: deviceID, action: .down, keycode: keycode)
        sendKey(deviceID: deviceID, action: .up, keycode: keycode)
    }

    @discardableResult
    func requestRemoteClipboard(deviceID: String, command: RemoteClipboardCommand) -> Bool {
        guard row(id: deviceID)?.transport != .companionLAN else { return false }
#if !GALAXYBRIDGE_APP_STORE
        guard let session = scrcpySessions[deviceID] else { return false }
        let operation: EnhancedClipboardOperation = command == .cut ? .cut : .copy
        EnhancedClipboardRequestDispatcher.request(
            operation,
            companion: { [weak self] in
                self?.sendEnhancedClipboardCommandViaCompanion(
                    deviceID: deviceID,
                    operation: $0
                ) ?? false
            },
            scrcpy: { request in
                switch request {
                case .readCurrent:
                    session.requestClipboard(copyKey: .none, afterExternalCopy: true)
                case .atomicCopy:
                    session.requestClipboard(copyKey: .copy)
                case .atomicCut:
                    session.requestClipboard(copyKey: .cut)
                }
            }
        )
        return true
#else
        return false
#endif
    }

    @discardableResult
    func sendEnhancedClipboardCommandViaCompanion(
        deviceID: String,
        operation: EnhancedClipboardOperation
    ) -> Bool {
        sendEnhancedKeyViaCompanion(
            deviceID: deviceID,
            isDown: true,
            keycode: operation == .cut ? 52 : 31,
            repeatCount: 0,
            modifiers: 0x1000 | 0x2000
        )
    }

    func sendText(deviceID: String, text: String) {
        guard !text.isEmpty else { return }
        if row(id: deviceID)?.transport == .companionLAN {
            guard let control = companionControl(for: deviceID) else { return }
            var input = GBInputEvent()
            input.action = .text
            input.displayEpoch = companionVideoSessions[deviceID]?.displayEpoch ?? 0
            input.text = String(text.prefix(4_096))
            do { try control.sendInput(input) } catch { lastError = error.localizedDescription }
            return
        }
#if !GALAXYBRIDGE_APP_STORE
        if sendEnhancedTextViaCompanion(deviceID: deviceID, text: text) { return }
        scrcpySessions[deviceID]?.sendText(text)
#endif
    }

    @discardableResult
    func sendEnhancedTextViaCompanion(deviceID: String, text: String) -> Bool {
        let boundedText = String(text.prefix(4_096))
        guard !boundedText.isEmpty,
              let companionID = companionID(for: deviceID),
              let control = companionControl(for: deviceID)
        else { return false }

        let available = availableCapabilitiesByDevice[deviceID]
        let inputCode = "CAPABILITY_INPUT_INJECTION"
        guard EnhancedTextInputRoutingPolicy.route(
            companionConnected: companionStates[companionID] == .connected,
            companionCapabilitiesKnown: available != nil,
            companionAdvertisesInput: available?.contains(inputCode) == true,
            companionInputUnavailableReason: capabilityReasonsByDevice[deviceID]?[inputCode]
        ) == .companionAccessibility else { return false }

        var input = GBInputEvent()
        input.action = .text
        input.displayEpoch = 0
        input.text = boundedText
        do {
            try control.sendInput(input)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setDisplayPower(deviceID: String, on: Bool) {
#if !GALAXYBRIDGE_APP_STORE
        scrcpySessions[deviceID]?.sendControl(ScrcpyControlMessage.setDisplayPower(on: on))
#endif
    }

    func rotateDevice(deviceID: String) {
#if !GALAXYBRIDGE_APP_STORE
        scrcpySessions[deviceID]?.sendControl(ScrcpyControlMessage.rotateDevice)
#endif
    }

    func selectCaptureTarget(deviceID: String, target: ScrcpyCaptureTarget) {
#if !GALAXYBRIDGE_APP_STORE
        guard let session = scrcpySessions[deviceID] else { return }
        enhancedCaptureTargets[deviceID] = target
        detachGamepads(from: deviceID)
        session.restart(captureTarget: target)
#endif
    }

    private func loadEnhancedDisplays(deviceID: String, serial: String) {
#if !GALAXYBRIDGE_APP_STORE
        guard enhancedDisplaysByDevice[deviceID] == nil else { return }
        Task {
            do {
                let adb = try ADBClient()
                let serverURL = try ScrcpyServerLocator.locate()
                let displays = try await Task.detached(priority: .utility) {
                    try adb.scrcpyDisplays(serial: serial, serverURL: serverURL)
                }.value
                enhancedDisplaysByDevice[deviceID] = displays.isEmpty
                    ? [ScrcpyDisplay(id: 0, width: nil, height: nil)]
                    : displays
            } catch {
                enhancedDisplaysByDevice[deviceID] = [ScrcpyDisplay(id: 0, width: nil, height: nil)]
            }
        }
#endif
    }

    private func handleGamepadEvent(_ event: GamepadBridgeEvent) {
#if !GALAXYBRIDGE_APP_STORE
        switch event {
        case let .connected(id, _):
            routeGamepad(id: id, report: nil)
        case let .report(id, report):
            routeGamepad(id: id, report: report)
        case let .disconnected(id):
            if let target = gamepadTargets.removeValue(forKey: id) {
                scrcpySessions[target]?.sendControl(ScrcpyControlMessage.uhidDestroy(id: id))
            }
        }
#endif
    }

    private func syncGamepadsToSelectedSession() {
#if !GALAXYBRIDGE_APP_STORE
        for snapshot in gamepadBridge.snapshots() {
            routeGamepad(id: snapshot.id, report: snapshot.report)
        }
#endif
    }

    private func routeGamepad(id: UInt16, report: ScrcpyUHIDGamepadReport?) {
#if !GALAXYBRIDGE_APP_STORE
        let target = selectedDeviceID.flatMap { deviceID -> String? in
            guard row(id: deviceID)?.transport != .companionLAN,
                  scrcpySessions[deviceID] != nil
            else { return nil }
            return deviceID
        }
        if gamepadTargets[id] != target {
            if let previous = gamepadTargets.removeValue(forKey: id) {
                scrcpySessions[previous]?.sendControl(ScrcpyControlMessage.uhidDestroy(id: id))
            }
            if let target, let session = scrcpySessions[target] {
                session.sendControl(
                    ScrcpyControlMessage.uhidCreate(
                        id: id,
                        vendorID: ScrcpyUHIDGamepadReport.vendorID,
                        productID: ScrcpyUHIDGamepadReport.productID,
                        name: ScrcpyUHIDGamepadReport.deviceName,
                        reportDescriptor: ScrcpyUHIDGamepadReport.reportDescriptor
                    )
                )
                gamepadTargets[id] = target
            }
        }
        if let target = gamepadTargets[id], let report {
            scrcpySessions[target]?.sendControl(
                ScrcpyControlMessage.uhidInput(id: id, report: report.data)
            )
        }
#endif
    }

    private func detachGamepads(from deviceID: String) {
#if !GALAXYBRIDGE_APP_STORE
        for id in gamepadTargets.compactMap({ $0.value == deviceID ? $0.key : nil }) {
            scrcpySessions[deviceID]?.sendControl(ScrcpyControlMessage.uhidDestroy(id: id))
            gamepadTargets.removeValue(forKey: id)
        }
#endif
    }

    /// Readiness for an explicit standard-menu Start action in FullMac.
    /// This observes the current owner; it never acquires capture demand.
    func canStartRecording(deviceID: String) -> Bool {
#if GALAXYBRIDGE_APP_STORE
        return false
#else
        guard terminationAdmission.admitsWork, primaryScreenDemand.hasViewer(deviceID),
              !recordingDeviceIDs.contains(deviceID),
              let device = row(id: deviceID), device.isReady, device.transport != .companionLAN,
              let session = scrcpySessions[deviceID], case .streaming = session.state,
              session.videoSize.width > 0, session.videoSize.height > 0,
              let owner = session.nativeOwner, owner.attempt.isAdmitted,
              recordingVideoSources[deviceID] == owner.attempt.id.attemptID,
              acceptsScreenMedia(.enhanced, deviceID: deviceID) else { return false }
        return true
#endif
    }

    func toggleRecording(deviceID: String) {
        guard terminationAdmission.admitsWork else { return }
        let current = activeRecordings.filter { $0.deviceID == deviceID }
        if !current.isEmpty {
            for recording in current { stopRecording(id: recording.id) }
            return
        }
        guard let recordingDevice = row(id: deviceID) else { return }
        let size: CGSize
#if !GALAXYBRIDGE_APP_STORE
        if let session = scrcpySessions[deviceID], session.videoSize != .zero {
            size = session.videoSize
        } else if let companionSize = companionVideoSizes[deviceID], companionSize != .zero {
            size = companionSize
        } else {
            return
        }
#else
        guard let companionSize = companionVideoSizes[deviceID], companionSize != .zero else { return }
        size = companionSize
#endif
        let formatter = ISO8601DateFormatter()
        let safeDate = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let suggestedFilename = "GalaxyBridge-\(safeDate)-\(UUID().uuidString).mov"
        let moviesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
        guard let url = RecordingDestinationPolicy.resolve(
            suggestedFilename: suggestedFilename,
            moviesDirectory: moviesDirectory,
            selectUserURL: {
                SystemRecordingDestinationPicker().chooseURL(suggestedFilename: suggestedFilename)
            }
        ) else { return }
        // A modal save panel can process shutdown, revocation or another start
        // while it is open. Recheck the exact target before creating a writer.
        guard terminationAdmission.admitsWork,
              row(id: deviceID) == recordingDevice,
              !recordingDeviceIDs.contains(deviceID) else { return }
        guard let sourceID = recordingVideoSources[deviceID] else { return }
        let audioConfiguration = recordingAudioSources[deviceID]?.values.first(where: { $0.id == sourceID })?.configuration
        let recordingID = UUID()
        do {
            let recorder = try ScreenRecorder(
                outputURL: url,
                width: Int(size.width),
                height: Int(size.height),
                audioConfiguration: audioConfiguration,
                sourceID: sourceID,
                failureHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.lastError = error.localizedDescription
                        self?.stopRecording(id: recordingID)
                    }
                }
            )
            recordings.insert(
                sink: recorder, deviceID: deviceID,
                deviceName: row(id: deviceID)?.name ?? "Galaxy Bridge", id: recordingID
            )
            recordingVerificationAttempts[recordingID] = clientSetup.currentAttemptID(deviceID: deviceID, feature: .recording)
            _ = primaryScreenDemand.acquire(deviceID: deviceID, consumer: .recording, id: recordingID)
            updateRecordingSummaries()
            if audioConfiguration == nil { lastError = String(localized: "RECORDING_WITHOUT_AUDIO") }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func receiveRecordingAudio(_ event: ScrcpyStreamEvent, epoch: UInt32?, sourceID: UUID,
                                       route: ScreenMediaTransportSource, deviceID: String) {
        guard terminationAdmission.admitsWork else { return }
        let routeKey = route == .enhanced ? "enhanced" : "companion"
        if recordingAudioSources[deviceID]?[routeKey]?.id != sourceID {
            recordingAudioSources[deviceID, default: [:]][routeKey] = RecordingAudioSource(id: sourceID)
        }
        switch event {
        case let .codec(codec):
            if codec != .aac {
                recordingAudioSources[deviceID]?[routeKey]?.configuration = nil
                if recordingVideoSources[deviceID] == sourceID {
                    for recorder in recordings.sinks(for: deviceID) { recorder.rejectAudioConfiguration() }
                }
            }
        case let .packet(packet):
            if packet.isConfiguration {
                do {
                    let configuration = try RecordingAACConfiguration(audioSpecificConfig: packet.payload)
                    recordingAudioSources[deviceID]?[routeKey]?.configuration = configuration
                    if recordingVideoSources[deviceID] == sourceID {
                        for recorder in recordings.sinks(for: deviceID) where recorder.recordsAudio {
                            recorder.validateAudioConfiguration(configuration, epoch: epoch, sourceID: sourceID)
                        }
                    }
                } catch {
                    recordingAudioSources[deviceID]?[routeKey]?.configuration = nil
                    if recordingVideoSources[deviceID] == sourceID {
                        for recorder in recordings.sinks(for: deviceID) { recorder.rejectAudioConfiguration() }
                    }
                }
            } else if let pts = packet.presentationTimeUs, acceptsScreenMedia(route, deviceID: deviceID) {
                for recorder in recordings.sinks(for: deviceID) where recorder.recordsAudio {
                    recorder.appendAudio(packet.payload, presentationTimeUs: pts, epoch: epoch, sourceID: sourceID)
                }
            }
        default: break
        }
    }

    func stopRecording(id: UUID) {
        guard let entry = recordings.remove(id: id) else { return }
        primaryScreenDemand.release(id)
        updateRecordingSummaries()
#if !GALAXYBRIDGE_APP_STORE
        retireEnhancedScreenSessionIfUndemanded(deviceID: entry.summary.deviceID)
#endif
        finishRecording(entry)
    }

    private func updateRecordingSummaries() {
        activeRecordings = recordings.summaries
        recordingDeviceIDs = Set(activeRecordings.map(\.deviceID))
    }

    private func finishRecording(_ entry: RecordingRegistry<ScreenRecorder>.Entry) {
        let recorder = entry.sink
        let finishID = UUID()
        let verificationAttempt = recordingVerificationAttempts.removeValue(forKey: entry.summary.id)
        recordingFinishes[finishID] = Task { [weak self] in
            let result: Result<URL, Error> = await withCheckedContinuation { continuation in
                let accepted = recorder.finish { result in continuation.resume(returning: result) }
                if !accepted {
                    continuation.resume(returning: .failure(ScreenRecorderError.cancelled))
                }
            }
            if case let .failure(error) = result { self?.lastError = error.localizedDescription }
            if case .success = result, let self, self.terminationAdmission.admitsWork, let verificationAttempt {
                self.clientSetup.recordEvidence(deviceID: entry.summary.deviceID, feature: .recording, attemptID: verificationAttempt)
            }
            self?.recordingFinishes.removeValue(forKey: finishID)
        }
    }

    func notifications(for deviceID: String) -> [BridgeNotificationRow] {
        let muted = mutedPackages(for: deviceID)
        return notificationsByDevice[deviceID, default: []].filter { !muted.contains($0.packageName) }
    }

    func mutedPackages(for deviceID: String) -> Set<String> {
        if let value = mutedNotificationPackagesByDevice[deviceID] { return value }
        let key = "com.xopmc.GalaxyBridge.notification-filters.\(deviceID)"
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    func toggleNotificationPackage(deviceID: String, packageName: String) {
        var muted = mutedPackages(for: deviceID)
        if muted.contains(packageName) { muted.remove(packageName) } else { muted.insert(packageName) }
        mutedNotificationPackagesByDevice[deviceID] = muted
        UserDefaults.standard.set(
            muted.sorted(),
            forKey: "com.xopmc.GalaxyBridge.notification-filters.\(deviceID)"
        )
        if muted.contains(packageName) {
            macNotifications.remove(deviceID: deviceID, packageName: packageName)
        }
    }

    func performNotificationAction(
        deviceID: String,
        notificationID: String,
        actionID: String,
        reply: String? = nil,
        dismiss: Bool = false
    ) {
        guard let control = companionControl(for: deviceID) else { return }
        var action = GBNotificationAction()
        action.notificationID = notificationID
        action.actionID = actionID
        action.replyText = reply ?? ""
        action.dismiss = dismiss
        do { try control.sendNotificationAction(action) } catch { lastError = error.localizedDescription }
    }

    func sendFile(deviceID: String, url: URL) {
        guard terminationAdmission.admitsWork else { return }
        guard let fingerprint = filePeerFingerprints[deviceID] else {
            fileTransferStatus[deviceID] = String(localized: "FILES_COMPANION_REQUIRED")
            return
        }
        guard pendingTransfers.count + filePreparationTasks.count < 8 else {
            fileTransferStatus[deviceID] = String(localized: "FILE_TRANSFER_FAILED")
            return
        }
        let verificationAttempt = clientSetup.currentAttemptID(deviceID: deviceID, feature: .files)
        let accessed = url.startAccessingSecurityScopedResource()
        fileTransferStatus[deviceID] = String(localized: "FILE_HASHING")
        let jobID = UUID(), store = outgoingFileStore
        filePreparationDevices[jobID] = deviceID
        newFilePreparationIDs.insert(jobID)
        filePreparationTasks[jobID] = Task { [weak self] in
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
                self?.filePreparationTasks.removeValue(forKey: jobID)
                self?.filePreparationDevices.removeValue(forKey: jobID)
                self?.cancelledFilePreparationIDs.remove(jobID)
                self?.newFilePreparationIDs.remove(jobID)
            }
            let preparation = Task.detached(priority: .utility) {
                try store.prepare(deviceID: deviceID, peerFingerprint: fingerprint, sourceURL: url)
            }
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                guard let self else { return }
                guard self.filePeerFingerprints[deviceID] == fingerprint,
                      !self.cancelledFilePreparationIDs.contains(jobID) else {
                    let cancelled = self.cancelledFilePreparationIDs.contains(jobID)
                    try await Task.detached(priority: .utility) {
                        // If deletion fails, the durable cancellation still prevents a
                        // later launch from resuming this locally cancelled snapshot.
                        if cancelled { _ = try store.requestCancellation(prepared) }
                        try store.remove(prepared)
                    }.value
                    if cancelled {
                        self.fileTransferStatus[deviceID] = String(localized: "FILE_CANCELLED")
                    }
                    return
                }
                // A committed snapshot is safe to resume after a normal Quit.
                guard self.terminationAdmission.admitsWork else { return }
                self.pendingTransfers[prepared.id] = prepared
                self.fileVerificationAttempts[prepared.id] = verificationAttempt
                self.activatePendingFileTransfers()
            } catch {
                guard let self, self.terminationAdmission.admitsWork else { return }
                if self.cancelledFilePreparationIDs.contains(jobID), error is CancellationError {
                    self.fileTransferStatus[deviceID] = String(localized: "FILE_CANCELLED")
                } else if !(error is CancellationError) {
                    self.fileTransferStatus[deviceID] = error.localizedDescription
                }
            }
        }
    }

    private func sendPendingFileManifest(_ transfer: OutgoingFileTransfer) {
        guard terminationAdmission.admitsWork else { return }
        guard let files = companionFiles(for: transfer.deviceID) else {
            fileTransferStatus[transfer.deviceID] = String(localized: "FILE_CONNECTION_LOST")
            return
        }
        do {
            if transfer.cancelRequested {
                try files.sendTransferCancel(transfer.id)
                fileTransferStatus[transfer.deviceID] = String(localized: "FILE_CANCEL_PENDING")
            } else if fileCancellationPendingIDs.contains(transfer.id) {
                persistFileCancellation(transfer)
            } else {
                try files.sendTransferManifest(Self.protobufManifest(transfer.companionManifest))
                fileTransferStatus[transfer.deviceID] = String(localized: "FILE_WAITING_RECEIVER")
            }
        } catch {
            fileTransferStatus[transfer.deviceID] = String(localized: "FILE_CONNECTION_LOST")
        }
    }

    private func retireIncomingFileOwner(deviceID: String, fingerprint: Data) {
#if !GALAXYBRIDGE_APP_STORE
        incomingFileProofs = incomingFileProofs.filter { !$0.key.hasPrefix(deviceID + "/") }
        incomingFilesByDevice.removeValue(forKey: deviceID)
        let taskID = UUID(), store = incomingFileStore
        store.requestRevocation(owner: IncomingFileOwner(deviceID: deviceID, fingerprint: fingerprint))
        incomingFileTasks[taskID] = Task { [weak self] in
            defer { self?.incomingFileTasks.removeValue(forKey: taskID) }
            do { try await store.revoke(owner: IncomingFileOwner(deviceID: deviceID, fingerprint: fingerprint)) }
            catch { self?.lastError = String(localized: "FILE_TRANSFER_FAILED") }
        }
#endif
    }

    private func restoreOutgoingTransfers(peers: [PairedPeer]) {
        let previousFingerprints = filePeerFingerprints
        filePeerFingerprints = Dictionary(uniqueKeysWithValues: peers.map {
            ("device:\($0.deviceID)", OutgoingFileTransferStore.peerFingerprint(identityKey: $0.identityPublicKey, tlsFingerprint: $0.tlsCertificateSHA256, pairedAt: $0.pairedAt))
        })
        // A replaced/revoked trust record must not retain the previous peer's
        // private receive staging. Published Downloads remain user-owned.
        for (deviceID, fingerprint) in previousFingerprints where filePeerFingerprints[deviceID] != fingerprint {
            retireIncomingFileOwner(deviceID: deviceID, fingerprint: fingerprint)
        }
        for (deviceID, fingerprint) in filePeerFingerprints {
            let scope = deviceID + ":" + fingerprint.base64EncodedString()
            guard outgoingRestorePeers.insert(scope).inserted else { continue }
            let store = outgoingFileStore, jobID = UUID()
            filePreparationDevices[jobID] = deviceID
            filePreparationTasks[jobID] = Task { [weak self] in
                defer {
                    self?.filePreparationTasks.removeValue(forKey: jobID)
                    self?.filePreparationDevices.removeValue(forKey: jobID)
                    self?.cancelledFilePreparationIDs.remove(jobID)
                }
                let loading = Task.detached(priority: .utility) {
                    try store.pending(deviceID: deviceID, peerFingerprint: fingerprint)
                }
                do {
                    let records = try await withTaskCancellationHandler {
                        try await loading.value
                    } onCancel: { loading.cancel() }
                    guard let self, self.terminationAdmission.admitsWork,
                          self.filePeerFingerprints[deviceID] == fingerprint else { return }
                    if records.rejectedCount > 0 { self.fileTransferStatus[deviceID] = String(localized: "FILE_TRANSFER_FAILED") }
                    for transfer in records.transfers where self.pendingTransfers[transfer.id] == nil
                        && !self.finishedFileTransferIDs.contains(transfer.id) {
                        self.pendingTransfers[transfer.id] = transfer
                        if self.cancelledFilePreparationIDs.contains(jobID) {
                            self.fileCancellationPendingIDs.insert(transfer.id)
                            self.persistFileCancellation(transfer)
                        }
                    }
                    self.activatePendingFileTransfers()
                } catch {
                    guard let self, self.terminationAdmission.admitsWork, !Task.isCancelled else { return }
                    self.outgoingRestorePeers.remove(scope)
                    self.fileTransferStatus[deviceID] = error.localizedDescription
                }
            }
        }
    }



    @discardableResult
    func configureCamera(
        deviceID: String,
        enabled: Bool,
        cameraID: String = "back",
        width: UInt32 = 1_920,
        height: UInt32 = 1_080,
        framesPerSecond: UInt32 = 30
    ) -> Task<Void, Never> {
        let requestID = UUID().uuidString.lowercased()
        cameraRequestIDsByDevice[deviceID] = requestID
        if enabled {
            cameraRemoteStatusesByDevice[deviceID] = CameraRemoteStatus(phase: .starting, reasonCode: "")
            cameraStatusesByDevice[deviceID] = CameraStatusViewState.resolve(phase: .starting, reasonCode: "")
        } else {
            // Sending Stop does not prove the phone stopped. Preserve its last
            // running indication even when local admission/control is absent.
            let running = cameraRemoteStatusesByDevice[deviceID]?.serviceMayBeRunning == true
            cameraRemoteStatusesByDevice[deviceID] = CameraRemoteStatus(phase: running ? .streaming : .stopped, reasonCode: "")
        }
        var configuration = GBCameraConfiguration()
        configuration.requestID = requestID
        configuration.enabled = enabled
        configuration.cameraID = cameraID
        configuration.width = width
        configuration.height = height
        configuration.framesPerSecond = framesPerSecond
        var startedPermit: CameraPublicationPermit?
        let operation = CameraControlCommand.run(
            enabled: enabled,
            retireLocal: { retireCamera(deviceID: deviceID) },
            retireFailedStart: {
                guard let startedPermit else { return nil }
                return retireCamera(permit: startedPermit, reason: .startFailed)
            },
            control: { companionControl(for: deviceID) },
            send: { control in
                if enabled {
                    guard let companionID = companionID(for: deviceID),
                          let generation = companionRecoverySupervisor.currentGeneration(companionID: companionID),
                          let ingress = companionCameraSessions[deviceID] else { throw CameraControlCommand.Failure.unavailable }
                    if let old = cameraPublication.currentPermit { retireCamera(permit: old, reason: .replacement) }
                    guard let permit = cameraPublication.start(deviceID: deviceID, companionID: companionID,
                                                               connectionGeneration: generation, requestID: requestID)
                    else { throw CameraControlCommand.Failure.unavailable }
                    startedPermit = permit
                    cameraLifecyclesByDevice[deviceID] = permit
                    refreshCameraStatus(deviceID: deviceID)
                    let preview = CameraPreviewDelivery { [weak self] frame in
                        guard let self, frame.permit.isAdmitted,
                              self.cameraPublication.currentPermit === frame.permit else { return }
                        self.cameraSurface(for: frame.permit.deviceID).present(
                            frame.pixelBuffer, presentationTime: frame.presentationTime, epoch: frame.epoch)
                    }
                    ingress.install(CameraVideoSession(permit: permit, publication: cameraPublication,
                                                       preview: preview, failure: { [cameraFailures] error in cameraFailures.report(error, permit: permit) }))
                }
                try control.sendCameraConfiguration(configuration)
            }
        )
        switch operation.outcome {
        case .sent: break
        case .unavailable:
            if enabled {
                cameraRemoteStatusesByDevice[deviceID] = CameraRemoteStatus(phase: .failed, reasonCode: "")
                cameraStatusesByDevice[deviceID] = CameraStatusViewState.resolve(phase: .failed, reasonCode: "")
            }
        case let .failed(error):
            lastError = error.localizedDescription
        }
        if !enabled || startedPermit != nil { refreshCameraStatus(deviceID: deviceID) }
        let revision = cameraPublication.revision
        return operation.observe(isCurrent: { [weak self] in
            guard let self else { return false }
            return self.cameraRequestIDsByDevice[deviceID] == requestID && self.cameraPublication.revision == revision &&
                (self.cameraPublication.currentPermit.map { $0.requestID == requestID } ?? true)
        }, apply: { [weak self] completion in
            if case let .failure(error)? = completion.retirement { self?.lastError = error.localizedDescription }
        })
    }

    @discardableResult
    private func retireCamera(deviceID: String, reason: CameraRetirementReason = .stop) -> CameraRetirement? {
        guard let permit = cameraPublication.owner(deviceID: deviceID) else {
            // A repeated Stop awaits the same pending attempt, without touching
            // a different device's current owner or creating another barrier.
            guard let previous = cameraRetirementsByDevice[deviceID] else { return nil }
            return retireCamera(permit: previous.permit, reason: reason)
        }
        return retireCamera(permit: permit, reason: reason)
    }

    @discardableResult
    private func retireCamera(permit: CameraPublicationPermit, reason: CameraRetirementReason = .stop) -> CameraRetirement {
        let wasOwner = cameraPublication.currentPermit === permit
        let barrier = cameraPublication.retire(permit, reason: reason)
        if cameraLifecyclesByDevice[permit.deviceID] === permit { refreshCameraStatus(deviceID: permit.deviceID) }
        if cameraRetirementsByDevice[permit.deviceID]?.barrier === barrier { return barrier }
        cameraRetirementsByDevice[permit.deviceID] = (permit, barrier)
        if wasOwner {
            companionCameraSessions[permit.deviceID]?.invalidate()
            cameraSurfaces[permit.deviceID]?.clearCameraFrame()
        }
        let revision = cameraPublication.revision
        let requestID = cameraRequestIDsByDevice[permit.deviceID]
        Task { @MainActor [weak self] in
            let result = await barrier.wait()
            guard let self else { return }
            if case .success = result, self.cameraRetirementsByDevice[permit.deviceID]?.barrier === barrier {
                self.cameraRetirementsByDevice.removeValue(forKey: permit.deviceID)
            }
            if self.cameraLifecyclesByDevice[permit.deviceID] === permit {
                self.refreshCameraStatus(deviceID: permit.deviceID)
            }
            guard self.cameraPublication.revision == revision,
                  self.cameraRequestIDsByDevice[permit.deviceID] == requestID,
                  self.cameraPublication.currentPermit == nil || self.cameraPublication.currentPermit === permit else { return }
            if case let .failure(error) = result { self.lastError = error.localizedDescription }
        }
        return barrier
    }

    private func retireCamera(companionID: String, generation: UInt64) {
        guard let permit = cameraPublication.currentPermit,
              permit.companionID == companionID, permit.connectionGeneration == generation else { return }
        retireCamera(permit: permit, reason: .generationLoss)
    }

    private func refreshCameraStatus(deviceID: String) {
        guard let remote = cameraRemoteStatusesByDevice[deviceID] else { return }
        cameraStatusesByDevice[deviceID] = CameraStatusViewState.resolve(
            remote: remote, local: cameraLifecyclesByDevice[deviceID]?.lifecycle)
    }

    func effectiveCapabilities(deviceID: String) -> EffectiveDeviceCapabilities {
#if GALAXYBRIDGE_APP_STORE
        let enhancedReady = false
#else
        let device = row(id: deviceID)
        let enhancedReady = device?.isReady == true && device?.adbSerial != nil
            && device?.transport != .companionLAN
#endif
        return EffectiveDeviceCapabilities.resolve(
            companionAvailable: availableCapabilitiesByDevice[deviceID, default: []],
            companionUnavailable: capabilityReasonsByDevice[deviceID, default: [:]],
            hasEnhancedTransport: enhancedReady
        )
    }

    func capabilityAccess(deviceID: String, capabilityCode: String) -> CapabilityAccess {
        let effective = effectiveCapabilities(deviceID: deviceID)
        return CapabilityAccessResolver.resolve(
            capabilityCode: capabilityCode,
            availableCapabilities: effective.available,
            unavailableReasons: effective.unavailableReasons
        )
    }

    func smsAccess(deviceID: String) -> CapabilityAccess {
        capabilityAccess(deviceID: deviceID, capabilityCode: "CAPABILITY_SMS")
    }

    @discardableResult
    func sendSMS(deviceID: String, address: String, body: String) -> Bool {
        let access = smsAccess(deviceID: deviceID)
        guard SMSDeliveryPolicy.allowsDirectSend(for: access),
              let control = companionControl(for: deviceID),
              !address.isEmpty,
              !body.isEmpty
        else { return false }
        var sms = GBSmsEvent()
        sms.messageID = UUID().uuidString.lowercased()
        sms.address = address
        sms.body = body
        sms.timestampUnixMs = Int64(Date().timeIntervalSince1970 * 1_000)
        sms.outgoing = true
        do {
            try control.sendSMS(sms)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func controlCall(
        deviceID: String,
        state: GBCallState,
        callID: String = "",
        address: String = ""
    ) {
        guard let control = companionControl(for: deviceID) else { return }
        var call = GBCallEvent()
        call.callID = callID
        call.address = address
        call.state = state
        do { try control.sendCall(call) } catch { lastError = error.localizedDescription }
    }

    /// Re-attempts creation after a temporarily locked Keychain, while avoiding
    /// a tight retry loop from Bonjour and pasteboard updates.
    private func availableContentCache(now: Date = Date()) -> EncryptedContentCache? {
        if let contentCache { return contentCache }
        if let lastAttempt = contentCacheLastInitializationAttempt,
           now.timeIntervalSince(lastAttempt) < 5 {
            return nil
        }
        contentCacheLastInitializationAttempt = now
        let cache = try? EncryptedContentCache()
        contentCache = cache
        return cache
    }

    /// Restores history only for identities that are still paired. Restored
    /// clipboard records seed loop suppression but never overwrite the user's
    /// current Mac pasteboard or emit a companion message.
    private func restoreCachedContent(for peers: [PairedPeer]) {
        for peer in peers {
            let deviceID = "device:\(peer.deviceID)"
            guard !restoredCacheDeviceIDs.contains(deviceID) else { continue }
            cacheMaintenance.restore(deviceID: deviceID) { [weak self] restoration in
                Task { @MainActor in
                    guard let self, let restoration,
                          self.cacheMaintenance.isCurrent(restoration.token) else { return }
                    self.applyCachedContent(restoration)
                }
            }
        }
    }

    private func applyCachedContent(_ restoration: ContentCacheMaintenanceCoordinator.Restoration) {
        let deviceID = restoration.token.deviceID
        let cachedNotifications = restoration.notifications
        let cachedSMS = restoration.sms
        let cachedClipboard = restoration.clipboard
        var notificationRows = notificationsByDevice[deviceID, default: []]
        let liveNotificationIDs = Set(notificationRows.map(\.id))
        for record in cachedNotifications where !liveNotificationIDs.contains(record.itemID) && cacheMaintenance.shouldRestore(.init(deviceID: deviceID, namespace: .notifications, itemID: record.itemID)) {
            guard let event = try? GBNotificationEvent(serializedBytes: record.payload),
                  event.notificationID == record.itemID,
                  !event.removed
            else {
                cacheMaintenance.remove(.init(
                    deviceID: deviceID,
                    namespace: .notifications,
                    itemID: record.itemID
                ))
                continue
            }
            notificationRows.removeAll { $0.id == record.itemID }
            notificationRows.append(
                BridgeNotificationRow(
                    id: event.notificationID,
                    packageName: event.packageName,
                    appLabel: event.appLabel,
                    title: event.title,
                    body: event.body,
                    postedAt: Date(
                        timeIntervalSince1970: TimeInterval(event.postedAtUnixMs) / 1_000
                    ),
                    actions: event.actions.map {
                        BridgeNotificationActionRow(
                            id: $0.actionID,
                            title: $0.title,
                            acceptsText: $0.acceptsText
                        )
                    },
                    appIconPNG: event.appIconPng.isEmpty ? nil : event.appIconPng
                )
            )
        }
        notificationRows.sort { $0.postedAt > $1.postedAt }
        notificationsByDevice[deviceID] = Array(notificationRows.prefix(200))

        var smsRows = smsByDevice[deviceID, default: []]
        let liveSMSIDs = Set(smsRows.map(\.id))
        for record in cachedSMS where !liveSMSIDs.contains(record.itemID) && cacheMaintenance.shouldRestore(.init(deviceID: deviceID, namespace: .sms, itemID: record.itemID)) {
            guard let sms = try? GBSmsEvent(serializedBytes: record.payload),
                  sms.messageID == record.itemID
            else {
                cacheMaintenance.remove(.init(
                    deviceID: deviceID,
                    namespace: .sms,
                    itemID: record.itemID
                ))
                continue
            }
            smsRows.removeAll { $0.id == record.itemID }
            smsRows.append(
                BridgeSMSRow(
                    id: sms.messageID,
                    address: sms.address,
                    body: sms.body,
                    timestamp: Date(
                        timeIntervalSince1970: TimeInterval(sms.timestampUnixMs) / 1_000
                    ),
                    outgoing: sms.outgoing
                )
            )
        }
        smsRows.sort { $0.timestamp > $1.timestamp }
        smsByDevice[deviceID] = Array(smsRows.prefix(500))

        for record in cachedClipboard.prefix(256) {
            seenClipboardChangeIDs.insert(record.itemID)
        }
        if seenClipboardChangeIDs.count > 256 {
            seenClipboardChangeIDs = Set(seenClipboardChangeIDs.prefix(256))
        }
        restoredCacheDeviceIDs.insert(deviceID)
    }

    private func mergeDevices(startCompanionConnections: Bool = true) {
        guard terminationAdmission.admitsWork else { return }
        let persistedPeers: [PairedPeer]
        do {
            persistedPeers = try PairedPeerStore().peers()
        } catch {
            persistedPeers = []
            lastError = UserFacingText.formatted(
                "PEER_STORE_FAILED", String(describing: error)
            )
        }
        let peers = (companionConnectionBootstrap?.peers(merging: persistedPeers) ?? persistedPeers)
            .filter { !Self.qaExcludedDeviceIDs.contains($0.deviceID.lowercased()) }
#if !GALAXYBRIDGE_APP_STORE
        reconcileCompanionTunnels(peers: peers)
#endif
        let companions = companionCandidates(peers: peers).filter { companion in
            guard let deviceID = companion.identity.deviceID else { return true }
            return !Self.qaExcludedDeviceIDs.contains(deviceID.lowercased())
        }
        companionLifecycleLogger.info(
            "merge snapshot discoveries=\(self.discovery.companions.count, privacy: .public) candidates=\(companions.count, privacy: .public) peers=\(peers.count, privacy: .public) reconnecting=\(self.companionRecoverySupervisor.delayedRetryCount, privacy: .public) clients=\(self.companionClients.count, privacy: .public)"
        )
        restoreCachedContent(for: peers)
        restoreOutgoingTransfers(peers: peers)
        var rowsByID: [String: DeviceRow] = [:]
        companionDeviceIDs.removeAll(keepingCapacity: true)
        for companion in companions {
            companionEndpoints[companion.id] = companion.endpoint
            let peer = matchingPeer(for: companion, peers: peers)
            let logicalID = CompanionPeerMatcher.logicalDeviceID(
                discoveryID: companion.id,
                identity: companion.identity,
                peers: peers
            )
            companionDeviceIDs[logicalID] = companion.id
            rowsByID[logicalID] = DeviceRow(
                id: logicalID,
                name: peer?.displayName ?? companion.name,
                subtitle: String(localized: "COMPANION_LAN"),
                transport: .companionLAN,
                isReady: companionStates[companion.id] == .connected,
                companionID: companion.id
            )
        }
#if !GALAXYBRIDGE_APP_STORE
        let bindingStore = ADBBindingStore()
        var qaSelectedLogicalID: String?
        for adbRow in adbRows {
            let serial = adbRow.adbSerial
            let isQASelectedRoute = serial == Self.qaADBSerialOverride
            let persistedRecord = serial.flatMap { try? bindingStore.record(for: $0) }
            let persistedPeer = persistedRecord.flatMap { record in
                peers.first(where: { $0.deviceID == record.deviceID })
            }
            let hasPersistentlyVerifiedBinding: Bool = {
                guard let serial, let persistedPeer else { return false }
                return bindingStore.isVerified(serial: serial, peer: persistedPeer)
            }()
            let matchingPeers = peers.filter { peer in
                rowsByID["device:\(peer.deviceID)"] != nil &&
                    ADBDeviceNameMatching.matches(model: adbRow.name, companionName: peer.displayName)
            }
            let logicalID: String
            if let serial,
               let record = persistedRecord,
               persistedPeer != nil,
               hasPersistentlyVerifiedBinding,
               (adbRow.transport != .wirelessADB || validatedWirelessSerials.contains(serial)) {
                logicalID = "device:\(record.deviceID)"
            } else {
                let canonicalCompanionID = persistedPeer.map { "device:\($0.deviceID)" }
                    ?? matchingPeers.first.map { "device:\($0.deviceID)" }
                let hasCanonicalCompanionRow = canonicalCompanionID.flatMap { rowsByID[$0] } != nil
                guard isQASelectedRoute || ADBPendingIdentityPresentationPolicy.shouldPublishStandalone(
                    hasCanonicalCompanionRow: hasCanonicalCompanionRow,
                    hasPersistentlyVerifiedBinding: hasPersistentlyVerifiedBinding,
                    matchingCompanionCount: matchingPeers.count
                ) else {
                    // The signed binder continues to operate on `adbRows` and
                    // will publish this route after proof. Until then the
                    // already-present canonical Companion row represents the
                    // phone without exposing an untrusted duplicate.
                    continue
                }
                logicalID = adbRow.id
            }
            if isQASelectedRoute {
                qaSelectedLogicalID = logicalID
            }
            let canonicalADBRow = DeviceRow(
                id: logicalID,
                name: adbRow.name,
                subtitle: adbRow.subtitle,
                transport: adbRow.transport,
                isReady: adbRow.isReady && !enhancedTransportFailed(logicalID),
                adbSerial: adbRow.adbSerial,
                companionID: rowsByID[logicalID]?.companionID
            )
            if let existing = rowsByID[logicalID] {
                rowsByID[logicalID] = DeviceRowMerger.merge(existing, canonicalADBRow)
            } else {
                rowsByID[logicalID] = canonicalADBRow
            }
        }
#endif
        let previousSelection = selectedDeviceID
        let previousRows = devices.map(\.selectionIdentity)
        devices = Array(rowsByID.values).sorted { left, right in
            if left.transport == right.transport { return left.name < right.name }
            return TransportSelector.preferred(from: [left.transport, right.transport]) == left.transport
        }
#if !GALAXYBRIDGE_APP_STORE
        if let qaSelectedLogicalID {
            // Hardware QA must not inherit a previously selected Companion row
            // from another attached phone. Keep the requested ADB alias and its
            // verified Companion identity as one canonical device.
            devices = devices.filter { $0.id == qaSelectedLogicalID }
            selectedDeviceID = qaSelectedLogicalID
        } else {
            selectedDeviceID = DeviceSelectionResolver.resolve(
                previousSelectionID: previousSelection,
                previousRows: previousRows,
                currentRows: devices.map(\.selectionIdentity)
            )
        }
#else
        selectedDeviceID = DeviceSelectionResolver.resolve(
            previousSelectionID: previousSelection,
            previousRows: previousRows,
            currentRows: devices.map(\.selectionIdentity)
        )
#endif
        if startCompanionConnections {
            connectPairedCompanions(peers: peers, companions: companions)
        }
#if !GALAXYBRIDGE_APP_STORE
        reconcileEnhancedClipboardSessions()
#endif
    }

#if !GALAXYBRIDGE_APP_STORE
    /// Keeps one low-bandwidth control-only clipboard channel per reachable ADB
    /// phone. Its lifetime follows device connectivity, never a mirror window.
    private func reconcileEnhancedClipboardSessions() {
        guard terminationAdmission.admitsWork else { return }
        let desired = Dictionary(
            uniqueKeysWithValues: devices.compactMap { device -> (String, String)? in
                guard device.isReady,
                      device.transport != .companionLAN,
                      let serial = device.adbSerial
                else { return nil }
                return (device.id, serial)
            }
        )
        let obsoleteDeviceIDs = clipboardSessions.compactMap { deviceID, session in
            desired[deviceID] == session.serial ? nil : deviceID
        }
        for deviceID in obsoleteDeviceIDs {
            guard let session = clipboardSessions[deviceID] else { continue }
            session.stop()
            clipboardSessions.removeValue(forKey: deviceID)
            clipboardReconnectTasks.removeValue(forKey: deviceID)?.cancel()
            clipboardReconnectAttempts.removeValue(forKey: deviceID)
        }
        for deviceID in Array(clipboardReconnectTasks.keys)
        where desired[deviceID] == nil {
            clipboardReconnectTasks.removeValue(forKey: deviceID)?.cancel()
            clipboardReconnectAttempts.removeValue(forKey: deviceID)
        }
        for (deviceID, serial) in desired
        where clipboardSessions[deviceID] == nil && clipboardReconnectTasks[deviceID] == nil {
            installEnhancedClipboardSession(deviceID: deviceID, serial: serial)
        }
    }

    private func installEnhancedClipboardSession(deviceID: String, serial: String) {
        guard terminationAdmission.admitsWork,
              clipboardSessions[deviceID] == nil,
              let adb = try? ADBClient()
        else { return }
        let session = ScrcpyClipboardSession(
            serial: serial,
            adb: adb,
            readyHandler: { [weak self] readySerial in
                guard let self,
                      self.clipboardSessions[deviceID]?.serial == readySerial
                else { return }
                self.clipboardReconnectTasks.removeValue(forKey: deviceID)?.cancel()
                self.clipboardReconnectAttempts[deviceID] = 0
            },
            failureHandler: { [weak self] failedSerial in
                self?.handleEnhancedClipboardFailure(deviceID: deviceID, serial: failedSerial)
            }
        )
        session.clipboardEventHandler = { [weak self] update in
            Task { @MainActor in
                self?.acceptRemoteClipboard(
                    deviceID: deviceID,
                    changeID: update.changeID,
                    kind: update.kind == .png ? .png : .text,
                    content: update.content,
                    sensitive: false
                )
            }
        }
        clipboardSessions[deviceID] = session
        session.start()
    }

    private func handleEnhancedClipboardFailure(deviceID: String, serial: String) {
        guard terminationAdmission.admitsWork else { return }
        guard clipboardSessions[deviceID]?.serial == serial else { return }
        clipboardSessions.removeValue(forKey: deviceID)
        clipboardReconnectTasks.removeValue(forKey: deviceID)?.cancel()
        let attempt = clipboardReconnectAttempts[deviceID, default: 0]
        clipboardReconnectAttempts[deviceID] = min(attempt + 1, 4)
        let delay = ClipboardSessionReconnectPolicy.delay(afterFailure: attempt)
        clipboardReconnectTasks[deviceID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  self.terminationAdmission.admitsWork
            else { return }
            self.clipboardReconnectTasks.removeValue(forKey: deviceID)
            guard let device = self.row(id: deviceID),
                  device.isReady,
                  device.transport != .companionLAN,
                  device.adbSerial == serial
            else {
                self.clipboardReconnectAttempts.removeValue(forKey: deviceID)
                return
            }
            self.installEnhancedClipboardSession(deviceID: deviceID, serial: serial)
        }
    }
#endif

#if !GALAXYBRIDGE_APP_STORE
    private func reconcileCompanionTunnels(peers: [PairedPeer]) {
        guard terminationAdmission.admitsWork else { return }
        let bindings = ADBBindingStore()
        var desired: [String: (scope: String, serial: String)] = [:]
        for peer in peers {
            guard let serial = adbRows.first(where: { row in
                guard row.transport == .usbADB, row.isReady, let serial = row.adbSerial else { return false }
                return bindings.isVerified(serial: serial, peer: peer)
            })?.adbSerial else { continue }
            let scope = peer.deviceID + ":" + Data(SHA256.hash(data: peer.identityPublicKey)).base64EncodedString()
                + ":" + String(peer.pairedAt.timeIntervalSince1970)
            desired["device:" + peer.deviceID] = (scope, serial)
        }
        companionTunnelDesired = desired
        for (deviceID, lease) in companionTunnelLeases
        where desired[deviceID]?.scope != lease.peerID || desired[deviceID]?.serial != lease.serial {
            companionTunnelLeases.removeValue(forKey: deviceID)
            retireCompanionTunnelRoute(deviceID: deviceID)
            Task { [companionTunnels] in
                do { try await companionTunnels.release(lease) }
                catch { self.fileTransferStatus[deviceID] = String(localized: "FILE_CONNECTION_LOST") }
            }
        }
        for (deviceID, target) in desired
        where companionTunnelLeases[deviceID] == nil && companionTunnelTasks[deviceID] == nil {
            let token = UUID()
            companionTunnelTokens[deviceID] = token
            companionTunnelTasks[deviceID] = Task { [weak self, companionTunnels] in
                defer {
                    if let self, self.companionTunnelTokens[deviceID] == token {
                        self.companionTunnelTasks.removeValue(forKey: deviceID)
                        self.companionTunnelTokens.removeValue(forKey: deviceID)
                    }
                }
                do {
                    let lease = try await companionTunnels.acquire(peerID: target.scope, serial: target.serial)
                    guard let self, self.terminationAdmission.admitsWork,
                          self.companionTunnelDesired[deviceID]?.scope == target.scope,
                          self.companionTunnelDesired[deviceID]?.serial == target.serial else {
                        try await companionTunnels.release(lease)
                        return
                    }
                    self.companionTunnelLeases[deviceID] = lease
                } catch {
                    // An unavailable helper/USB path does not invalidate trust
                    // or disturb a working LAN bundle. Uncertain cleanup remains
                    // quarantined in the coordinator until runtime shutdown.
                    if let self, self.terminationAdmission.admitsWork,
                       self.companionTunnelDesired[deviceID]?.scope == target.scope,
                       self.companionFiles(for: deviceID) == nil {
                        self.fileTransferStatus[deviceID] = String(localized: "FILE_CONNECTION_LOST")
                    }
                }
                guard let self, self.companionTunnelTokens[deviceID] == token else { return }
                if self.companionTunnelLeases[deviceID] != nil { self.mergeDevices() }
            }
        }
    }

    private func retireCompanionTunnelRoute(deviceID: String) {
        guard let peerID = deviceID.removingPrefix("device:") else { return }
        let id = "usb-companion:" + peerID
        if case let .companion(boundID, _, _)? = audioVerificationRequests[deviceID]?.binding, boundID == id {
            cancelAudioVerification(deviceID: deviceID)
        }
        companionConnectingWatchdog.forget(companionID: id)
        companionRecoverySupervisor.forget(companionID: id)
        companionRecoverySupervisor.cancelDelayedRetry(companionID: id)
        companionClients.removeValue(forKey: id)?.cancelAll()
        companionStates[id] = .disconnected
        companionEndpoints.removeValue(forKey: id)
    }
#endif

    private func companionCandidates(peers: [PairedPeer]) -> [DiscoveredCompanion] {
        var candidates = discovery.companions.filter { companion in
            matchingPeer(for: companion, peers: peers) == nil
        }
        for peer in peers {
            let bonjour = discovery.companions.first { companion in
                matchingPeer(for: companion, peers: [peer]) != nil
            }
#if GALAXYBRIDGE_APP_STORE
            if let bonjour { candidates.append(bonjour) }
#else
            let logicalID = "device:\(peer.deviceID)"
            let tunnelID = "usb-companion:\(peer.deviceID)"
            let activeBundle = companionClients.first { $0.value.control.peer.deviceID == peer.deviceID }?.key
            if let tunnel = companionTunnelLeases[logicalID], activeBundle == nil || activeBundle == tunnelID,
               let port = NWEndpoint.Port(rawValue: tunnel.port) {
                candidates.append(DiscoveredCompanion(id: tunnelID, name: peer.displayName,
                    endpointDescription: "usb", endpoint: .hostPort(host: NWEndpoint.Host(tunnel.host), port: port),
                    identity: BonjourCompanionIdentity(deviceID: peer.deviceID,
                        publicKeyFingerprint: Data(SHA256.hash(data: peer.identityPublicKey)), protocolMajor: 1)))
                continue
            }
            let routedID = "routed:\(peer.deviceID)"
            let routedAddress = routedCompanionIPv4ByPeer[peer.deviceID]
            let source = companionEndpointFailover.source(
                peerID: peer.deviceID,
                hasBonjour: bonjour != nil,
                hasRoutedAddress: routedAddress != nil,
                routedSessionActive: companionClients[routedID] != nil || companionRecoverySupervisor.hasDelayedRetry(companionID: routedID)
            )
            switch source {
            case .bonjour:
                if let bonjour { candidates.append(bonjour) }
            case .routed:
                guard let routedAddress,
                      let port = NWEndpoint.Port(rawValue: CompanionRoutedFallback.port)
                else { continue }
                candidates.append(
                    DiscoveredCompanion(
                        id: routedID,
                        name: peer.displayName,
                        endpointDescription: "routed-lan",
                        endpoint: .hostPort(host: NWEndpoint.Host(routedAddress), port: port),
                        identity: BonjourCompanionIdentity(
                            deviceID: peer.deviceID,
                            publicKeyFingerprint: Data(SHA256.hash(data: peer.identityPublicKey)),
                            protocolMajor: 1
                        )
                    )
                )
            case .none:
                break
            }
#endif
        }
        return candidates
    }

    private func enhancedTransportFailed(_ deviceID: String) -> Bool {
        EnhancedADBRouteAvailabilityPolicy.blocksRoute(for: enhancedStates[deviceID])
    }

    private func acceptsScreenMedia(_ source: ScreenMediaTransportSource, deviceID: String) -> Bool {
        mediaTransportDispatchGate(for: deviceID).shouldDispatch(
            source,
            isConfiguration: false
        )
    }

    private func mediaTransportDispatchGate(for deviceID: String) -> MediaTransportDispatchGate {
        if let gate = mediaTransportDispatchGates[deviceID] { return gate }
        let gate = MediaTransportDispatchGate(enhancedState: enhancedStates[deviceID])
        mediaTransportDispatchGates[deviceID] = gate
        return gate
    }

    private func matchingPeer(for companion: DiscoveredCompanion, peers: [PairedPeer]) -> PairedPeer? {
        CompanionPeerMatcher.match(identity: companion.identity, peers: peers)
    }

    private func canStartLogicalSession(_ deviceID: String) -> Bool {
        SessionCapacityPolicy.canStartPhysicalDevice(
            deviceID,
            activeLogicalDeviceIDs: activePhysicalLogicalSessionIDs
        )
    }

    private var activePhysicalLogicalSessionIDs: Set<String> {
        let companionIDs = companionClients.values.map { "device:\($0.control.peer.deviceID)" }
#if GALAXYBRIDGE_APP_STORE
        return Set(companionIDs)
#else
        return Set(scrcpySessions.keys).union(companionIDs)
#endif
    }

    private func connectPairedCompanions(
        peers: [PairedPeer],
        companions: [DiscoveredCompanion]
    ) {
        guard terminationAdmission.admitsWork else { return }
        let hostID = UserDefaults.standard.string(forKey: "com.xopmc.GalaxyBridge.host-id") ?? ""
        companionLifecycleLogger.info(
            "connection scan candidates=\(companions.count, privacy: .public) peers=\(peers.count, privacy: .public) reconnecting=\(self.companionRecoverySupervisor.delayedRetryCount, privacy: .public) clients=\(self.companionClients.count, privacy: .public) hostReady=\(!hostID.isEmpty, privacy: .public)"
        )
        for companion in companions
        where companionClients[companion.id] == nil && !companionRecoverySupervisor.hasDelayedRetry(companionID: companion.id) {
            guard let peer = matchingPeer(for: companion, peers: peers) else {
                companionLifecycleLogger.notice("connection candidate skipped: trust identity mismatch")
                continue
            }
            guard !companionAuthenticationBlockedPeerIDs.contains(peer.deviceID) else {
                companionLifecycleLogger.notice("connection candidate skipped: terminal authentication rejection")
                continue
            }
            let deviceID = "device:\(peer.deviceID)"
            guard canStartLogicalSession(deviceID) else {
                companionLifecycleLogger.notice("connection candidate skipped: session budget exhausted")
                continue
            }
#if !GALAXYBRIDGE_APP_STORE
            let oldGeneration = companionRecoverySupervisor.currentGeneration(companionID: companion.id)
#endif
            guard let generation = companionRecoverySupervisor.beginSession(companionID: companion.id) else { continue }
            companionLifecycleLogger.info("connection bundle starting")
#if !GALAXYBRIDGE_APP_STORE
            if let oldGeneration {
                adbIdentityBinder.retire(
                    session: ADBBindingSession(companionID: companion.id, generation: oldGeneration)
                )
            }
#endif
            let diagnosticSink = companionDiagnosticSink()
            CompanionRecoveryDiagnostics(sink: diagnosticSink).recordBundleStarted(
                bundleGeneration: generation
            )
            let mediaPlayoutClock = MediaPlayoutClock()
            let mediaDispatchGate = mediaTransportDispatchGate(for: deviceID)
            let recordingSourceID = UUID()
            let videoSession = CompanionVideoSession(playoutClock: mediaPlayoutClock)
            let cameraSession = CameraMediaIngress()
            let audioPlayer = AACAudioPlayer(playoutClock: mediaPlayoutClock) { [weak self] error in
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
            audioPlayer.setPlaybackEnabled(primaryScreenDemand.hasViewer(deviceID))
            audioPlayer.consume(.codec(.aac))
            videoSession.decodedFrameHandler = { [weak self, weak videoSession] pixelBuffer, presentationTime, epoch in
                let frame = AppModelPixelBuffer(pixelBuffer)
                Task { @MainActor in
                    guard let self, let videoSession, self.terminationAdmission.admitsWork,
                          self.companionRecoverySupervisor.currentGeneration(companionID: companion.id) == generation,
                          self.companionVideoSessions[deviceID] === videoSession,
                          self.acceptsScreenMedia(.companion, deviceID: deviceID)
                    else { return }
                    self.videoSurface(for: deviceID).present(frame.value, presentationTime: presentationTime, epoch: epoch)
                    self.companionVideoSizes[deviceID] = CGSize(
                        width: CVPixelBufferGetWidth(frame.value),
                        height: CVPixelBufferGetHeight(frame.value)
                    )
                    let height = CGFloat(CVPixelBufferGetHeight(frame.value))
                    if height > 0 {
                        let ratio = CGFloat(CVPixelBufferGetWidth(frame.value)) / height
                        if self.videoAspectRatios[deviceID].map({ abs($0 - ratio) > 0.0005 }) ?? true {
                            self.videoAspectRatios[deviceID] = ratio
                        }
                    }
                    self.recordingVideoSources[deviceID] = recordingSourceID
                    for recorder in self.recordings.sinks(for: deviceID) {
                        recorder.append(frame.value, presentationTime: presentationTime, epoch: epoch, sourceID: recordingSourceID)
                    }
                }
            }
            videoSession.failureHandler = { [weak self, weak videoSession] error in
                Task { @MainActor in
                    guard let self, let videoSession, self.terminationAdmission.admitsWork,
                          self.companionRecoverySupervisor.currentGeneration(companionID: companion.id) == generation,
                          self.companionVideoSessions[deviceID] === videoSession else { return }
                    self.lastError = error.localizedDescription
                }
            }
            companionVideoSessions[deviceID] = videoSession
            companionCameraSessions[deviceID] = cameraSession
            companionAudioPlayers[deviceID] = audioPlayer
            companionAudioVerificationOwners[deviceID] = .companion(companion.id, generation, ObjectIdentifier(audioPlayer))
            let logicalSessionID = UUID().uuidString.lowercased()
            let control = CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleCompanionState(
                            companionID: companion.id,
                            generation: generation,
                            channel: .control,
                            state: state
                        )
                    }
                },
                envelopeHandler: { [weak self] envelope, _ in
                    Task { @MainActor in
                        self?.handleCompanionEnvelope(
                            companionID: companion.id,
                            generation: generation,
                            deviceID: deviceID,
                            envelope: envelope
                        )
                    }
                }
            )
            let events = CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .events,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleCompanionState(
                            companionID: companion.id,
                            generation: generation,
                            channel: .events,
                            state: state
                        )
                    }
                },
                envelopeHandler: { [weak self] envelope, _ in
                    Task { @MainActor in
                        self?.handleCompanionEnvelope(
                            companionID: companion.id,
                            generation: generation,
                            deviceID: deviceID,
                            envelope: envelope
                        )
                    }
                }
            )
            let video = CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .video,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleCompanionState(
                            companionID: companion.id,
                            generation: generation,
                            channel: .video,
                            state: state
                        )
                    }
                },
                envelopeHandler: { _, _ in },
                mediaHandler: { [weak videoSession] packet in
                    guard mediaDispatchGate.shouldDispatch(
                        .companion,
                        isConfiguration: packet.flags.contains(.configuration)
                    ) else { return }
                    Task { @MainActor in
                        videoSession?.consume(packet)
                    }
                }
            )
            let audio = CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .audio,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleCompanionState(
                            companionID: companion.id,
                            generation: generation,
                            channel: .audio,
                            state: state
                        )
                    }
                },
                envelopeHandler: { _, _ in },
                mediaHandler: { [weak self, weak audioPlayer] packet in
                    guard mediaDispatchGate.shouldDispatch(
                        .companion,
                        isConfiguration: packet.flags.contains(.configuration)
                    ) else { return }
                    Task { @MainActor in
                        guard let self, let audioPlayer, self.terminationAdmission.admitsWork,
                              self.companionRecoverySupervisor.currentGeneration(companionID: companion.id) == generation,
                              self.companionAudioPlayers[deviceID] === audioPlayer else { return }
                        self.armAudioVerificationIfPossible(deviceID: deviceID)
                        let event = ScrcpyStreamEvent.packet(.init(
                            isConfiguration: packet.flags.contains(.configuration), isKeyFrame: false,
                            presentationTimeUs: packet.presentationTimeUs, payload: packet.payload))
                        self.receiveRecordingAudio(event, epoch: packet.epoch, sourceID: recordingSourceID,
                                                   route: .companion, deviceID: deviceID)
                        audioPlayer.consume(
                            .packet(
                                .init(
                                    isConfiguration: packet.flags.contains(.configuration),
                                    isKeyFrame: false,
                                    presentationTimeUs: packet.presentationTimeUs,
                                    payload: packet.payload
                                )
                            ),
                            epoch: packet.epoch
                        )
                    }
                }
            )
            let camera = CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .camera,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleCompanionState(
                            companionID: companion.id,
                            generation: generation,
                            channel: .camera,
                            state: state
                        )
                    }
                },
                envelopeHandler: { _, _ in },
                mediaHandler: { [weak cameraSession] packet in
                    cameraSession?.consume(packet)
                }
            )
            let fileIngress = CompanionFileIngressGate()
            let files = CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .files,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleCompanionState(
                            companionID: companion.id,
                            generation: generation,
                            channel: .files,
                            state: state
                        )
                    }
                },
                envelopeHandler: { [weak self] envelope, wireByteCount in
                    // Charge the entire decoded frame, including unknown protobuf
                    // fields and malformed payloads, before retaining it on MainActor.
                    let cost = wireByteCount + 4096
                    guard fileIngress.admit(bytes: cost) else {
                        if fileIngress.shouldReportRejection() {
                            Task { @MainActor in
                                guard let self,
                                      self.companionRecoverySupervisor.currentGeneration(companionID: companion.id) == generation else { return }
                                self.companionClients[companion.id]?.files.cancel()
                            }
                        }
                        return
                    }
                    Task { @MainActor in
                        guard let self else { fileIngress.finish(bytes: cost); return }
                        self.enqueueCompanionFilesEnvelope(
                            companionID: companion.id,
                            generation: generation,
                            deviceID: deviceID,
                            envelope: envelope,
                            finished: { fileIngress.finish(bytes: cost) }
                        )
                    }
                }
            )
            companionClients[companion.id] = CompanionConnections(
                control: control,
                events: events,
                video: video,
                audio: audio,
                camera: camera,
                files: files
            )
            armAudioVerificationIfPossible(deviceID: deviceID)
            control.start()
            events.start()
            video.start()
            audio.start()
            camera.start()
            files.start()
        }
    }

    private func handleCompanionState(
        companionID: String,
        generation: CompanionLogicalSessionRecoverySupervisor.Generation,
        channel: GBChannelKind,
        state: CompanionConnectionState
    ) {
        let peerID = companionClients[companionID]?.control.peer.deviceID
        let callbackState: CompanionDiagnosticCallbackState
        switch state {
        case .connecting: callbackState = .connecting
        case .connected: callbackState = .connected
        case .disconnected: callbackState = .disconnected
        case .failed, .authenticationRejected: callbackState = .failed
        }
        var recoveryAccepted: Bool?
        let wasCurrentGeneration = companionRecoverySupervisor.ifCurrentSession(
            companionID: companionID,
            generation: generation
        ) {
            switch state {
            case .connected:
                if channel == .files {
                    guard let connections = companionClients[companionID] else { return }
                    resumePendingTransfers(deviceID: "device:\(connections.control.peer.deviceID)")
                    return
                }
                guard channel == .control else { return }
                if let peerID { companionAuthenticationBlockedPeerIDs.remove(peerID) }
#if !GALAXYBRIDGE_APP_STORE
                if let peerID = companionClients[companionID]?.control.peer.deviceID {
                    companionEndpointFailover.recordSuccess(
                        peerID: peerID,
                        source: companionID.hasPrefix("routed:") ? .routed : .bonjour
                    )
                }
#endif
                companionStates[companionID] = state
                companionConnectingWatchdog.connectionSettled(companionID: companionID)
                lastError = nil
                reconnectAttempts[companionID] = 0
                companionRecoverySupervisor.cancelDelayedRetry(companionID: companionID)
                reconcileADBBindings(for: companionID)
                mergeDevices()
            case let .failed(message):
                if let peerID {
                    cancelAudioVerification(deviceID: "device:" + peerID)
                    clientSetup.invalidate(deviceID: "device:" + peerID)
                }
                companionStates[companionID] = state
                companionConnectingWatchdog.connectionSettled(companionID: companionID)
                if let peerID, companionAuthenticationBlockedPeerIDs.contains(peerID) {
                    recoveryAccepted = false
                    return
                }
                lastError = UserFacingText.formatted(
                    "COMPANION_CONNECTION_FAILED", message
                )
                recoveryAccepted = recoverCompanionSession(
                    companionID: companionID,
                    generation: generation
                )
            case let .authenticationRejected(message):
                if let peerID {
                    cancelAudioVerification(deviceID: "device:" + peerID)
                    clientSetup.invalidate(deviceID: "device:" + peerID)
                }
                companionStates[companionID] = state
                if let peerID { companionAuthenticationBlockedPeerIDs.insert(peerID) }
                companionConnectingWatchdog.connectionSettled(companionID: companionID)
                companionRecoverySupervisor.cancelDelayedRetry(companionID: companionID)
                reconnectAttempts[companionID] = 0
                lastError = message
                recoveryAccepted = false
            case .disconnected:
                if let peerID {
                    cancelAudioVerification(deviceID: "device:" + peerID)
                    clientSetup.invalidate(deviceID: "device:" + peerID)
                }
                companionStates[companionID] = state
                companionConnectingWatchdog.connectionSettled(companionID: companionID)
                if let peerID, companionAuthenticationBlockedPeerIDs.contains(peerID) {
                    recoveryAccepted = false
                    return
                }
                recoveryAccepted = recoverCompanionSession(
                    companionID: companionID,
                    generation: generation
                )
            case .connecting:
                guard channel == .control else { return }
                companionStates[companionID] = state
                companionConnectingWatchdog.connectionStarted(companionID: companionID)
                mergeDevices()
            }
        }
        if (callbackState == .failed || callbackState == .disconnected), recoveryAccepted == nil {
            recoveryAccepted = false
        }
        CompanionRecoveryDiagnostics(sink: companionDiagnosticSink()).recordCallback(
            bundleGeneration: generation,
            channel: companionDiagnosticChannel(channel),
            state: callbackState,
            isCurrentGeneration: wasCurrentGeneration,
            recoveryAccepted: recoveryAccepted
        )
    }

    private func handleCompanionConnectingTimeout(companionID: String) {
        guard companionStates[companionID] == .connecting,
              let generation = companionRecoverySupervisor.currentGeneration(companionID: companionID)
        else { return }
        companionClients[companionID]?.control.recordConnectingWatchdogTimeout()
        handleCompanionState(
            companionID: companionID,
            generation: generation,
            channel: .control,
            state: .disconnected
        )
    }

    @discardableResult
    private func recoverCompanionSession(
        companionID: String,
        generation: CompanionLogicalSessionRecoverySupervisor.Generation
    ) -> Bool {
        retireCamera(companionID: companionID, generation: generation)
        let peerID = companionClients[companionID]?.control.peer.deviceID
#if !GALAXYBRIDGE_APP_STORE
        adbIdentityBinder.retire(
            session: ADBBindingSession(companionID: companionID, generation: generation)
        )
        let failedEndpointSource: CompanionEndpointSource =
            companionID.hasPrefix("routed:") ? .routed : .bonjour
#endif
        let cancellationActions = companionClients[companionID]?.cancellationActions ?? []
        return companionRecoverySupervisor.recover(
            companionID: companionID,
            generation: generation,
            cancelChannels: cancellationActions,
            scheduleDelayedReconnect: { [weak self] permit in
                self?.scheduleCompanionReconnect(
                    companionID: companionID,
                    generation: generation,
                    permit: permit
                )
            },
            publishModel: { [weak self] allowsReconnect in
                guard let self else { return }
#if !GALAXYBRIDGE_APP_STORE
                if let peerID {
                    companionEndpointFailover.recordFailure(
                        peerID: peerID,
                        source: failedEndpointSource
                    )
                }
#endif
                if let connections = companionClients.removeValue(forKey: companionID) {
                    let deviceID = "device:\(connections.control.peer.deviceID)"
                    companionVideoSessions.removeValue(forKey: deviceID)?.invalidate()
                    companionCameraSessions.removeValue(forKey: deviceID)?.invalidate()
                    companionAudioVerificationOwners.removeValue(forKey: deviceID)
                    companionAudioPlayers.removeValue(forKey: deviceID)?.stop()
                }
                mergeDevices(startCompanionConnections: allowsReconnect)
            }
        )
    }

    private func scheduleCompanionReconnect(
        companionID: String,
        generation: CompanionLogicalSessionRecoverySupervisor.Generation,
        permit: CompanionLogicalSessionRecoverySupervisor.DelayedRetryPermit
    ) {
        guard companionRecoverySupervisor.admitsDelayedRetry(permit),
              !companionRecoverySupervisor.hasDelayedRetry(companionID: companionID)
        else { return }
        let attempt = reconnectAttempts[companionID, default: 0]
        let delay = [1, 2, 5, 10, 30][min(attempt, 4)]
        CompanionRecoveryDiagnostics(sink: companionDiagnosticSink()).recordRetry(
            bundleGeneration: generation,
            attempt: attempt + 1,
            delayMilliseconds: UInt64(delay * 1_000)
        )
        reconnectAttempts[companionID] = attempt + 1
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            companionRecoverySupervisor.performDelayedRetry(permit) {
                mergeDevices()
            }
        }
        companionRecoverySupervisor.installDelayedRetry(permit, cancel: { task.cancel() })
    }

    private func companionDiagnosticSink() -> CompanionConnectionDiagnostics.Sink {
        let logger = companionLifecycleLogger
        return { event in
            logger.info("\(event.serialized, privacy: .public)")
        }
    }

#if !GALAXYBRIDGE_APP_STORE
    private func scheduleEnhancedReconnect(deviceID: String, session: ScrcpySession) {
        guard terminationAdmission.admitsWork,
              activeEnhancedDeviceID(session) == deviceID,
              enhancedReconnectTasks[deviceID] == nil
        else { return }
        let attempt = enhancedReconnectAttempts[deviceID, default: 0]
        let delay = [1, 2, 5, 10, 30][min(attempt, 4)]
        enhancedReconnectAttempts[deviceID] = attempt + 1
        let retryID = UUID()
        enhancedReconnectTokens[deviceID] = retryID
        enhancedReconnectTasks[deviceID] = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let session,
                  self.enhancedReconnectTokens[deviceID] == retryID else { return }
            self.enhancedReconnectTokens.removeValue(forKey: deviceID)
            self.enhancedReconnectTasks.removeValue(forKey: deviceID)
            guard self.terminationAdmission.admitsWork,
                  self.activeEnhancedDeviceID(session) == deviceID else { return }
            guard self.primaryScreenDemand.canStart(deviceID),
                  self.row(id: deviceID)?.isReady == true else {
                self.scheduleEnhancedReconnect(deviceID: deviceID, session: session)
                return
            }
            session.start()
        }
    }
#endif

    private func companionControl(for deviceID: String) -> CompanionTLSClient? {
        guard let companionID = companionID(for: deviceID) else { return nil }
        return companionClients[companionID]?.control
    }

    private func companionPositionalInputControl(for deviceID: String) -> CompanionTLSClient? {
        guard let control = companionControl(for: deviceID) else { return nil }
        guard let device = row(id: deviceID) else { return nil }
        return device.transport == .companionLAN ? control : nil
    }

#if !GALAXYBRIDGE_APP_STORE
    private func enhancedADBPositionalInputRoute(
        for deviceID: String
    ) -> (serial: String, dispatcher: EnhancedADBPositionalInputDispatcher)? {
        guard let device = row(id: deviceID),
              device.transport != .companionLAN,
              EnhancedPositionalInputRoutingPolicy.backend(deviceName: device.name) == .adbShell,
              let serial = device.adbSerial
        else { return nil }
        if let dispatcher = enhancedADBInputDispatchers[deviceID] {
            return (serial, dispatcher)
        }
        do {
            let dispatcher = EnhancedADBPositionalInputDispatcher(adb: try ADBClient())
            enhancedADBInputDispatchers[deviceID] = dispatcher
            return (serial, dispatcher)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
#endif

    private func companionFiles(for deviceID: String) -> CompanionTLSClient? {
        guard let companionID = companionID(for: deviceID) else { return nil }
        return companionClients[companionID]?.files
    }

    private func companionID(for deviceID: String) -> String? {
        if let mapped = companionDeviceIDs[deviceID] { return mapped }
        if let raw = deviceID.removingPrefix("lan:") { return raw }
        return companionClients.first {
            "device:\($0.value.control.peer.deviceID)" == deviceID
        }?.key
    }

    private func reconcileADBBindings(for companionID: String) {
#if !GALAXYBRIDGE_APP_STORE
        guard companionStates[companionID] == .connected,
              let generation = companionRecoverySupervisor.currentGeneration(companionID: companionID),
              let peer = companionClients[companionID]?.control.peer
        else { return }
        let permitsSingleCandidateFallback = adbRows.count == 1 && companionClients.count == 1
        let hostID = UserDefaults.standard.string(forKey: "com.xopmc.GalaxyBridge.host-id") ?? ""
        let readyCandidates = adbRows.compactMap { candidate -> ADBBindingCandidate? in
            guard candidate.isReady, let serial = candidate.adbSerial else { return nil }
            let revalidate = candidate.transport == .wirelessADB && !validatedWirelessSerials.contains(serial)
            return .init(
                serial: serial,
                peer: peer,
                hostID: hostID,
                nameMatches: permitsSingleCandidateFallback || ADBDeviceNameMatching.matches(
                    model: candidate.name,
                    companionName: peer.displayName
                ),
                revalidate: revalidate
            )
        }
        adbIdentityBinder.reconcile(
            readyCandidates,
            in: ADBBindingSession(companionID: companionID, generation: generation)
        )
#endif
    }

#if !GALAXYBRIDGE_APP_STORE
    private func reportADBBindingExhaustion(attempts: Int) {
        lastError = UserFacingText.formatted("ADB_BINDING_EXHAUSTED", attempts)
    }
#endif

    private func handleCompanionEnvelope(
        companionID: String,
        generation: CompanionLogicalSessionRecoverySupervisor.Generation,
        deviceID: String,
        envelope: GBEnvelope
    ) {
        companionRecoverySupervisor.ifCurrentSession(
            companionID: companionID,
            generation: generation
        ) {
            handleCurrentCompanionEnvelope(
                companionID: companionID,
                generation: generation,
                deviceID: deviceID,
                envelope: envelope
            )
        }
    }

    private func handleCurrentCompanionEnvelope(
        companionID: String,
        generation: CompanionLogicalSessionRecoverySupervisor.Generation,
        deviceID: String,
        envelope: GBEnvelope
    ) {
        switch envelope.payload {
        case let .notificationEvent(event):
            if event.removed {
                macNotifications.remove(deviceID: deviceID, notificationID: event.notificationID)
                cacheMaintenance.remove(.init(deviceID: deviceID, namespace: .notifications, itemID: event.notificationID))
            }
            var rows = notificationsByDevice[deviceID, default: []]
            rows.removeAll { $0.id == event.notificationID }
            if !event.removed {
                rows.insert(
                    BridgeNotificationRow(
                        id: event.notificationID,
                        packageName: event.packageName,
                        appLabel: event.appLabel,
                        title: event.title,
                        body: event.body,
                        postedAt: Date(timeIntervalSince1970: TimeInterval(event.postedAtUnixMs) / 1_000),
                        actions: event.actions.map {
                            BridgeNotificationActionRow(id: $0.actionID, title: $0.title, acceptsText: $0.acceptsText)
                        },
                        appIconPNG: event.appIconPng.isEmpty ? nil : event.appIconPng
                    ),
                    at: 0
                )
                rows = Array(rows.prefix(200))
                if let payload = try? event.serializedData() {
                    cacheMaintenance.store(
                        .init(deviceID: deviceID, namespace: .notifications, itemID: event.notificationID),
                        payload: payload
                    )
                }
                if MacNotificationReplayPolicy.shouldPublishNative(
                    isInitialSnapshot: event.initialSnapshot,
                    removed: event.removed
                ), let notificationRow = rows.first(where: { $0.id == event.notificationID }) {
                    let notificationAttempt = clientSetup.currentAttemptID(deviceID: deviceID, feature: .notifications)
                    macNotifications.publish(
                        deviceID: deviceID,
                        deviceName: row(id: deviceID)?.name ?? "",
                        notification: notificationRow,
                        mutedPackages: mutedPackages(for: deviceID),
                        onAccepted: { [weak self] in
                            guard let notificationAttempt else { return }
                            Task { @MainActor in
                                guard let self, self.terminationAdmission.admitsWork,
                                      self.companionRecoverySupervisor.currentGeneration(companionID: companionID) == generation else { return }
                                self.clientSetup.recordEvidence(deviceID: deviceID, feature: .notifications, attemptID: notificationAttempt)
                            }
                        }
                    )
                }
            }
            notificationsByDevice[deviceID] = rows
        case let .clipboardUpdate(update):
            acceptRemoteClipboard(
                deviceID: deviceID,
                changeID: update.changeID,
                kind: update.kind,
                content: update.content,
                sensitive: update.sensitive
            )
        case let .capabilityUpdate(update):
            availableCapabilitiesByDevice[deviceID] = Set(update.available.compactMap(Self.capabilityCode))
            capabilityReasonsByDevice[deviceID] = update.unavailableReasons
        case let .smsEvent(sms):
            var rows = smsByDevice[deviceID, default: []]
            rows.removeAll { $0.id == sms.messageID }
            rows.append(
                BridgeSMSRow(
                    id: sms.messageID,
                    address: sms.address,
                    body: sms.body,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(sms.timestampUnixMs) / 1_000),
                    outgoing: sms.outgoing
                )
            )
            rows.sort { $0.timestamp > $1.timestamp }
            smsByDevice[deviceID] = Array(rows.prefix(500))
            if let payload = try? sms.serializedData() {
                cacheMaintenance.store(
                    .init(deviceID: deviceID, namespace: .sms, itemID: sms.messageID),
                    payload: payload
                )
            }
        case let .callEvent(call):
            let row = BridgeCallRow(
                id: call.callID,
                address: call.address,
                displayName: call.displayName,
                state: call.state,
                incoming: call.incoming,
                timestamp: call.timestampUnixMs > 0
                    ? Date(timeIntervalSince1970: TimeInterval(call.timestampUnixMs) / 1_000)
                    : Date(),
                durationSeconds: call.durationSeconds,
                history: call.history
            )
            if call.history {
                var history = callHistoryByDevice[deviceID, default: []]
                history.removeAll { $0.id == row.id }
                history.append(row)
                history.sort { $0.timestamp > $1.timestamp }
                callHistoryByDevice[deviceID] = Array(history.prefix(200))
            } else {
                callByDevice[deviceID] = row
            }
        case let .cameraStatus(status):
            guard CameraStatusCorrelation.accepts(
                currentRequestID: cameraRequestIDsByDevice[deviceID],
                incomingRequestID: status.requestID
            ) else { return }
            let phase: CameraRemotePhase
            switch status.state {
            case .starting: phase = .starting
            case .awaitingUserConfirmation: phase = .awaitingUserConfirmation
            case .streaming: phase = .streaming
            case .stopped: phase = .stopped
            case .failed: phase = .failed
            case .unspecified, .UNRECOGNIZED: return
            }
            if var remote = cameraRemoteStatusesByDevice[deviceID] {
                guard remote.receive(phase: phase, reasonCode: status.reasonCode) else { return }
                cameraRemoteStatusesByDevice[deviceID] = remote
            } else {
                cameraRemoteStatusesByDevice[deviceID] = CameraRemoteStatus(phase: phase, reasonCode: status.reasonCode)
            }
            if (phase == .stopped || phase == .failed),
               let permit = cameraPublication.owner(deviceID: deviceID, companionID: companionID,
                                                     connectionGeneration: generation, requestID: status.requestID) {
                retireCamera(permit: permit, reason: phase == .stopped ? .remoteStopped : .remoteFailed)
            }
            refreshCameraStatus(deviceID: deviceID)
#if !GALAXYBRIDGE_APP_STORE
        case let .adbBindingResponse(response):
            guard let peer = companionClients[companionID]?.control.peer else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    if let record = try await adbIdentityBinder.accept(
                        response,
                        from: peer,
                        in: ADBBindingSession(companionID: companionID, generation: generation)
                    ) {
                        adoptVerifiedBinding(record)
                        mergeDevices()
                    }
                } catch {
                    // The binder owns bounded retry and emits one actionable
                    // exhausted state; individual proof/launch failures stay quiet.
                }
            }
#endif
        case let .error(error):
            lastError = UserFacingText.localized(
                CompanionRemoteErrorText.localizationKey(for: error.code)
            )
        default:
            break
        }
    }

    nonisolated private static func capabilityCode(_ capability: GBCapability) -> String? {
        switch capability {
        case .unspecified: "CAPABILITY_UNSPECIFIED"
        case .screenCapture: "CAPABILITY_SCREEN_CAPTURE"
        case .inputInjection: "CAPABILITY_INPUT_INJECTION"
        case .audioForwarding: "CAPABILITY_AUDIO_FORWARDING"
        case .clipboardRead: "CAPABILITY_CLIPBOARD_READ"
        case .clipboardWrite: "CAPABILITY_CLIPBOARD_WRITE"
        case .files: "CAPABILITY_FILES"
        case .notifications: "CAPABILITY_NOTIFICATIONS"
        case .sms: "CAPABILITY_SMS"
        case .calls: "CAPABILITY_CALLS"
        case .cameraStream: "CAPABILITY_CAMERA_STREAM"
        case .virtualDisplay: "CAPABILITY_VIRTUAL_DISPLAY"
        case .recording: "CAPABILITY_RECORDING"
        case .UNRECOGNIZED: nil
        }
    }

#if !GALAXYBRIDGE_APP_STORE
    private func adoptVerifiedBinding(_ record: ADBBindingRecord) {
        validatedWirelessSerials.insert(record.adbSerial)
        let oldID = "adb:\(record.adbSerial)"
        let newID = "device:\(record.deviceID)"
        guard oldID != newID else { return }
        if let surface = videoSurfaces.removeValue(forKey: oldID), videoSurfaces[newID] == nil { videoSurfaces[newID] = surface }
        if let surface = cameraSurfaces.removeValue(forKey: oldID), cameraSurfaces[newID] == nil { cameraSurfaces[newID] = surface }
        if let state = enhancedStates.removeValue(forKey: oldID), enhancedStates[newID] == nil { enhancedStates[newID] = state }
        if let gate = mediaTransportDispatchGates.removeValue(forKey: oldID), mediaTransportDispatchGates[newID] == nil {
            mediaTransportDispatchGates[newID] = gate
        }
        enhancedSessionDiagnostics.migrate(from: oldID, to: newID)
        primaryScreenDemand.migrate(from: oldID, to: newID)
        recordings.migrate(from: oldID, to: newID)
        if let source = recordingVideoSources.removeValue(forKey: oldID), recordingVideoSources[newID] == nil {
            recordingVideoSources[newID] = source
        }
        if let sources = recordingAudioSources.removeValue(forKey: oldID), recordingAudioSources[newID] == nil {
            recordingAudioSources[newID] = sources
        }
        updateRecordingSummaries()
        // Screen-interlock wiring follows the same verified logical identity.
        if let interlock = enhancedScreenInterlocks.removeValue(forKey: oldID), enhancedScreenInterlocks[newID] == nil {
            enhancedScreenInterlocks[newID] = interlock
        }
        if let ratio = videoAspectRatios.removeValue(forKey: oldID), videoAspectRatios[newID] == nil { videoAspectRatios[newID] = ratio }
        if let displays = enhancedDisplaysByDevice.removeValue(forKey: oldID), enhancedDisplaysByDevice[newID] == nil { enhancedDisplaysByDevice[newID] = displays }
        if let target = enhancedCaptureTargets.removeValue(forKey: oldID), enhancedCaptureTargets[newID] == nil { enhancedCaptureTargets[newID] = target }
        if let status = cameraStatusesByDevice.removeValue(forKey: oldID), cameraStatusesByDevice[newID] == nil { cameraStatusesByDevice[newID] = status }
        if let requestID = cameraRequestIDsByDevice.removeValue(forKey: oldID), cameraRequestIDsByDevice[newID] == nil { cameraRequestIDsByDevice[newID] = requestID }
        if let remote = cameraRemoteStatusesByDevice.removeValue(forKey: oldID), cameraRemoteStatusesByDevice[newID] == nil { cameraRemoteStatusesByDevice[newID] = remote }
        for id in Array(gamepadTargets.keys) where gamepadTargets[id] == oldID { gamepadTargets[id] = newID }
        if let session = scrcpySessions.removeValue(forKey: oldID) {
            enhancedReconnectTasks.removeValue(forKey: oldID)?.cancel()
            if scrcpySessions[newID] != nil {
                enhancedSubscriptions.removeValue(forKey: ObjectIdentifier(session))
                retireEnhancedScreenSession(session, deviceID: newID)
            } else {
                scrcpySessions[newID] = session
                bindEnhancedNativeFrames(session, deviceID: newID)
                if case .failed = session.state { scheduleEnhancedReconnect(deviceID: newID, session: session) }
            }
        }
        updateAudioPlaybackDemand(deviceID: newID)
        if selectedDeviceID == oldID { selectedDeviceID = newID }
    }
#endif

    private func acceptRemoteClipboard(
        deviceID: String,
        changeID: String,
        kind: GBClipboardKind,
        content: Data,
        sensitive: Bool
    ) {
        guard !sensitive else { return }
        // Cached change IDs survive process restarts. Consult them before the
        // process-local hub so a reconnect cannot replay an old phone write
        // into the Mac pasteboard or fan it out to the other Galaxy devices.
        guard !seenClipboardChangeIDs.contains(changeID) else { return }
        let decision = clipboardHub.acceptRemote(
            sourceDeviceID: deviceID,
            changeID: changeID
        )
        guard case let .accept(revision) = decision else { return }

        let pasteboard = NSPasteboard.general
        let verificationReceipt = clientSetupEvidenceReceipt(deviceID: deviceID, feature: .clipboard)
        var didWrite = false
        switch kind {
        case .text, .url:
            guard let text = String(data: content, encoding: .utf8) else { return }
            if pasteboard.string(forType: .string) != text {
                pasteboard.clearContents()
                didWrite = pasteboard.setString(text, forType: .string)
            }
        case .png:
            guard let image = NSImage(data: content) else { return }
            if pasteboard.data(forType: .png) != content {
                pasteboard.clearContents()
                didWrite = pasteboard.writeObjects([image])
            }
        default:
            return
        }

        if didWrite { verificationReceipt?() }
        seenClipboardChangeIDs.insert(changeID)
        if seenClipboardChangeIDs.count > 256 {
            seenClipboardChangeIDs = [changeID]
        }
        lastPasteboardChangeCount = pasteboard.changeCount
        try? availableContentCache()?.put(
            deviceID: deviceID,
            namespace: .clipboard,
            itemID: changeID,
            payload: content
        )
        let hubChangeID = clipboardHub.outboundChangeID(revision: revision)
        broadcastClipboard(
            kind: kind,
            content: content,
            changeID: hubChangeID,
            excluding: deviceID
        )
    }

    private func publishClipboardIfChanged() {
        guard terminationAdmission.admitsWork else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        let value = pasteboard.string(forType: .string)
        let png = Self.pngData(from: pasteboard)
        guard let candidate = MacClipboardPayloadPolicy.candidate(
            pasteboardTypes: pasteboard.types?.map(\.rawValue) ?? [],
            text: value,
            png: png
        ) else { return }
        let kind: GBClipboardKind = switch candidate.kind {
        case .text: .text
        case .url: .url
        case .png: .png
        }
        let revision = clipboardHub.acceptMacChange()
        broadcastClipboard(
            kind: kind,
            content: candidate.content,
            changeID: clipboardHub.outboundChangeID(revision: revision),
            excluding: nil
        )
    }

    private func broadcastClipboard(
        kind: GBClipboardKind,
        content: Data,
        changeID: String,
        excluding sourceDeviceID: String?
    ) {
        let destinationIDs = ClipboardHubState.destinations(
            allConnectedDeviceIDs: devices.filter(\.isReady).map(\.id),
            excluding: sourceDeviceID
        )
        for deviceID in destinationIDs {
            var delivered = false
            if let companionID = companionID(for: deviceID),
               companionStates[companionID] == .connected,
               let control = companionClients[companionID]?.control {
                var update = GBClipboardUpdate()
                update.changeID = changeID
                update.kind = kind
                update.content = content
                update.sensitive = false
                do {
                    try control.sendClipboard(update)
                    delivered = true
                } catch {
                    // A simultaneously retiring companion connection may still
                    // have a ready device row. Text can fall through to its
                    // capture-free enhanced channel below.
                }
            }
#if !GALAXYBRIDGE_APP_STORE
            if !delivered,
               (kind == .text || kind == .url),
               let value = String(data: content, encoding: .utf8),
               let clipboardSession = clipboardSessions[deviceID],
               clipboardSession.setText(value) {
                delivered = true
            }
            if !delivered,
               (kind == .text || kind == .url),
               let value = String(data: content, encoding: .utf8),
               let session = scrcpySessions[deviceID] {
                session.sendControl(
                    ScrcpyControlMessage.setClipboard(
                        sequence: clipboardSequence,
                        text: value,
                        paste: false
                    )
                )
                clipboardSequence &+= 1
                delivered = true
            }
#endif
            guard delivered else { continue }
            try? availableContentCache()?.put(
                deviceID: deviceID,
                namespace: .clipboard,
                itemID: changeID,
                payload: content
            )
        }
    }

    nonisolated private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func enqueueCompanionFilesEnvelope(
        companionID: String, generation: CompanionLogicalSessionRecoverySupervisor.Generation,
        deviceID: String, envelope: GBEnvelope, finished: @escaping @Sendable () -> Void
    ) {
        guard terminationAdmission.admitsWork,
              companionRecoverySupervisor.currentGeneration(companionID: companionID) == generation,
              let client = companionClients[companionID]?.files,
              "device:" + client.peer.deviceID == deviceID else { finished(); return }
        if case let .transferAck(ack) = envelope.payload {
            handleTransferAck(ack, deviceID: deviceID, companionID: companionID, generation: generation)
            finished(); return
        }
        if case .error = envelope.payload {
            handleCompanionEnvelope(companionID: companionID, generation: generation, deviceID: deviceID, envelope: envelope)
            finished(); return
        }
        let transferID: String
        switch envelope.payload {
        case let .transferManifest(value): transferID = value.transferID
        case let .transferChunk(value): transferID = value.transferID
        case let .transferCancel(value): transferID = value.transferID
        default: finished(); return
        }
        guard UUID(uuidString: transferID)?.uuidString.lowercased() == transferID else {
            var ack = GBTransferAck(); ack.transferID = String(transferID.prefix(128)); ack.failureReason = "invalid_manifest"
            try? client.sendTransferAck(ack); finished(); return
        }
#if GALAXYBRIDGE_APP_STORE
        // This variant currently has only user-selected file access. Do not
        // advertise or bypass a Downloads grant through the direct receiver.
        var ack = GBTransferAck(); ack.transferID = transferID
        ack.failureReason = "provider_no_resumable_write"
        try? client.sendTransferAck(ack)
        finished()
#else
        guard incomingFileTasks.count < 16 else { client.cancel(); finished(); return }
        let fingerprint = OutgoingFileTransferStore.peerFingerprint(identityKey: client.peer.identityPublicKey,
            tlsFingerprint: client.peer.tlsCertificateSHA256, pairedAt: client.peer.pairedAt)
        guard filePeerFingerprints[deviceID] == fingerprint else { finished(); return }
        let owner = IncomingFileOwner(deviceID: deviceID, fingerprint: fingerprint)
        if case .transferCancel = envelope.payload {
            incomingFileStore.requestCancellation(owner: owner, id: transferID)
        }
        let scope = deviceID + "/" + transferID
        if case .transferManifest = envelope.payload {
            incomingFileProofs[scope] = clientSetup.currentAttemptID(deviceID: deviceID, feature: .files)
        }
        let taskID = UUID(), store = incomingFileStore
        incomingFileTasks[taskID] = Task { [weak self] in
            defer { self?.incomingFileTasks.removeValue(forKey: taskID); finished() }
            let receipt: IncomingFileReceipt
            switch envelope.payload {
            case let .transferManifest(value):
                receipt = await store.manifest(owner: owner, manifest: IncomingFileManifest(id: value.transferID,
                    name: value.relativeName, size: value.size, sha256: value.sha256))
            case let .transferChunk(value):
                receipt = await store.chunk(owner: owner, id: value.transferID, offset: value.offset, bytes: value.content)
            case let .transferCancel(value):
                receipt = await store.cancel(owner: owner, id: value.transferID)
            default: return
            }
            guard let self, self.terminationAdmission.admitsWork,
                  self.filePeerFingerprints[deviceID] == fingerprint,
                  self.companionRecoverySupervisor.currentGeneration(companionID: companionID) == generation,
                  self.companionClients[companionID]?.files === client else { return }
            // An in-memory cancellation fence is not a durable receipt. The
            // queued cancel operation sends the terminal ACK after its commit.
            guard receipt.failureReason != "transfer_cancel_pending",
                  receipt.failureReason != "owner_revocation_pending" else { return }
            if case let .transferManifest(value) = envelope.payload, receipt.failureReason.isEmpty,
               self.incomingFilesByDevice[deviceID, default: []].allSatisfy({ $0.id != value.transferID }) {
                var rows = self.incomingFilesByDevice[deviceID, default: []]
                while rows.count >= 20, let index = rows.firstIndex(where: { !$0.active }) { rows.remove(at: index) }
                if rows.count < 20 { rows.append(IncomingFileRow(id: value.transferID, name: value.relativeName, size: value.size)) }
                self.incomingFilesByDevice[deviceID] = rows
            }
            self.updateIncomingFileRow(deviceID: deviceID, receipt: receipt)
            if receipt.complete {
                if let attempt = self.incomingFileProofs.removeValue(forKey: scope), receipt.publishedNow {
                    self.clientSetup.recordEvidence(deviceID: deviceID, feature: .files, attemptID: attempt)
                }
            } else if !receipt.failureReason.isEmpty {
                self.incomingFileProofs.removeValue(forKey: scope)
            }
            do { try client.sendTransferAck(Self.protobufIncomingReceipt(receipt)) }
            catch { /* Durable checkpoint is replayed when Android reconnects. */ }
        }
#endif
    }

#if !GALAXYBRIDGE_APP_STORE
    private func updateIncomingFileRow(deviceID: String, receipt: IncomingFileReceipt) {
        guard var rows = incomingFilesByDevice[deviceID], let index = rows.firstIndex(where: { $0.id == receipt.id }) else { return }
        rows[index].received = receipt.offset
        if receipt.complete {
            rows[index].active = false
            rows[index].status = String(localized: "FILE_COMPLETE") + "\n" + receipt.publishedName
        } else if receipt.failureReason == "transfer_cancelled" {
            rows[index].active = false
            rows[index].status = String(localized: "FILE_CANCELLED")
        } else if !receipt.failureReason.isEmpty {
            rows[index].status = FileTransferFailurePresentation.message(reason: receipt.failureReason)
        } else { rows[index].status = "\(receipt.offset) / \(rows[index].size)" }
        incomingFilesByDevice[deviceID] = rows
    }
    nonisolated private static func protobufIncomingReceipt(_ receipt: IncomingFileReceipt) -> GBTransferAck {
        var ack = GBTransferAck()
        ack.transferID = receipt.id; ack.confirmedOffset = receipt.offset
        ack.complete = receipt.complete; ack.failureReason = receipt.failureReason
        ack.publishedName = receipt.publishedName
        return ack
    }
    func cancelIncomingFile(deviceID: String, transferID: String) {
        // Local cancellation has a separate bounded lane (one per active row),
        // so a full receive queue cannot disable the user's Cancel button.
        guard terminationAdmission.admitsWork, incomingFileCancellations.count < 8,
              incomingFilesByDevice[deviceID, default: []].contains(where: { $0.id == transferID && $0.active }),
              let fingerprint = filePeerFingerprints[deviceID] else { return }
        let scope = deviceID + "/" + transferID
        guard incomingFileCancellations.insert(scope).inserted else { return }
        incomingFileProofs.removeValue(forKey: scope)
        let taskID = UUID(), store = incomingFileStore
        store.requestCancellation(owner: IncomingFileOwner(deviceID: deviceID, fingerprint: fingerprint), id: transferID)
        incomingFileTasks[taskID] = Task { [weak self] in
            defer {
                self?.incomingFileTasks.removeValue(forKey: taskID)
                self?.incomingFileCancellations.remove(scope)
            }
            let receipt = await store.cancel(owner: IncomingFileOwner(deviceID: deviceID, fingerprint: fingerprint), id: transferID)
            guard let self, self.terminationAdmission.admitsWork, self.filePeerFingerprints[deviceID] == fingerprint else { return }
            self.updateIncomingFileRow(deviceID: deviceID, receipt: receipt)
            try? self.companionFiles(for: deviceID)?.sendTransferAck(Self.protobufIncomingReceipt(receipt))
        }
    }
#endif

    private func handleTransferAck(_ ack: GBTransferAck, deviceID: String, companionID: String,
                                   generation: CompanionLogicalSessionRecoverySupervisor.Generation) {
        guard terminationAdmission.admitsWork, let transfer = pendingTransfers[ack.transferID],
              transfer.deviceID == deviceID, filePeerFingerprints[deviceID] == transfer.peerFingerprint,
              companionRecoverySupervisor.currentGeneration(companionID: companionID) == generation else { return }
        if ack.failureReason == "transfer_cancelled", transfer.cancelRequested {
            finishTransfer(transfer, status: String(localized: "FILE_CANCELLED"))
            activatePendingFileTransfers()
            return
        }
        // Cancellation can race a completed publication. Accept a valid completion,
        // but never schedule more content after the user's cancellation fence.
        if !ack.complete && (transfer.cancelRequested || fileCancellationPendingIDs.contains(transfer.id)) {
            fileTransferStatus[deviceID] = String(localized: "FILE_CANCEL_PENDING")
            return
        }
        guard let instruction = fileTransferResumeCoordinator.instruction(
            for: CompanionFileTransferAcknowledgement(
                sourceDeviceID: deviceID,
                transferID: ack.transferID,
                confirmedOffset: ack.confirmedOffset,
                complete: ack.complete,
                failureReason: ack.failureReason
            )
        ) else { return }
        switch instruction {
        case let .fail(reason):
            // Remote protocol reasons remain in the acknowledgement; present
            // local-language guidance instead of the phone's diagnostic text.
            pauseFileTransfer(transfer, status: FileTransferFailurePresentation.message(reason: reason))
        case .complete:
            let publishedName = ack.publishedName
            let safeName = !publishedName.isEmpty && publishedName.utf8.count <= 240
                && !publishedName.contains("/") && !publishedName.contains("\\")
                && !publishedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            let status = String(localized: "FILE_COMPLETE") + "\n" + (safeName ? publishedName : transfer.relativeName)
            if let attempt = fileVerificationAttempts.removeValue(forKey: transfer.id) {
                clientSetup.recordEvidence(deviceID: deviceID, feature: .files, attemptID: attempt)
            }
            finishTransfer(transfer, status: status)
            activatePendingFileTransfers()
        case let .sendChunk(offset, maximumLength):
            guard fileChunkTasks[transfer.id] == nil, let client = companionClients[companionID]?.files else { return }
            fileTransferStatus[transfer.deviceID] = "\(offset) / \(transfer.size)"
            let chunkToken = UUID()
            fileChunkTokens[transfer.id] = chunkToken
            fileChunkTasks[transfer.id] = Task {
                defer {
                    if fileChunkTokens[transfer.id] == chunkToken {
                        fileChunkTasks.removeValue(forKey: transfer.id)
                        fileChunkTokens.removeValue(forKey: transfer.id)
                    }
                }
                do {
                    let payload = try await Task.detached(priority: .utility) {
                        try transfer.read(offset: offset, maximumLength: maximumLength)
                    }.value
                    guard !Task.isCancelled, terminationAdmission.admitsWork,
                          pendingTransfers[transfer.id]?.peerFingerprint == transfer.peerFingerprint,
                          pendingTransfers[transfer.id]?.cancelRequested == false,
                          !fileCancellationPendingIDs.contains(transfer.id),
                          activeFileTransferIDs.contains(transfer.id),
                          fileChunkTokens[transfer.id] == chunkToken,
                          filePeerFingerprints[deviceID] == transfer.peerFingerprint,
                          companionRecoverySupervisor.currentGeneration(companionID: companionID) == generation,
                          companionClients[companionID]?.files === client else { return }
                    guard !payload.isEmpty else { throw FileTransferError.connectionUnavailable }
                    var chunk = GBTransferChunk()
                    chunk.transferID = transfer.id
                    chunk.offset = offset
                    chunk.content = payload
                    try client.sendTransferChunk(chunk)
                } catch {
                    guard !Task.isCancelled, pendingTransfers[transfer.id] != nil else { return }
                    pauseFileTransfer(transfer, status: error.localizedDescription)
                }
            }
        }
    }

    private func activatePendingFileTransfers() {
        guard terminationAdmission.admitsWork else { return }
        for transfer in pendingTransfers.values.sorted(by: { $0.id < $1.id })
        where !activeFileTransferIDs.contains(transfer.id) {
            guard activeFileTransferIDs.count < 8 else { break }
            guard filePeerFingerprints[transfer.deviceID] == transfer.peerFingerprint,
                  companionFiles(for: transfer.deviceID) != nil else { continue }
            activeFileTransferIDs.insert(transfer.id)
            fileTransferResumeCoordinator.register(transfer.companionManifest)
            sendPendingFileManifest(transfer)
        }
    }

    private func pauseFileTransfer(_ transfer: OutgoingFileTransfer, status: String) {
        activeFileTransferIDs.remove(transfer.id)
        fileChunkTokens.removeValue(forKey: transfer.id)
        fileChunkTasks.removeValue(forKey: transfer.id)?.cancel()
        fileTransferResumeCoordinator.remove(transferID: transfer.id)
        fileTransferStatus[transfer.deviceID] = status
    }

    func cancelFileTransfers(deviceID: String) {
        guard terminationAdmission.admitsWork else { return }
        // A preparation may still return a committed snapshot. Mark its exact job
        // so the completion removes it instead of admitting a new transfer.
        for (job, target) in filePreparationDevices where target == deviceID {
            cancelledFilePreparationIDs.insert(job)
            if newFilePreparationIDs.contains(job) { filePreparationTasks[job]?.cancel() }
        }
        fileTransferStatus[deviceID] = String(localized: "FILE_CANCEL_PENDING")
        for transfer in pendingTransfers.values where transfer.deviceID == deviceID {
            fileCancellationPendingIDs.insert(transfer.id)
            fileChunkTokens.removeValue(forKey: transfer.id)
            fileChunkTasks.removeValue(forKey: transfer.id)?.cancel()
            fileVerificationAttempts.removeValue(forKey: transfer.id)
            fileTransferStatus[deviceID] = String(localized: "FILE_CANCEL_PENDING")
            persistFileCancellation(transfer)
        }
    }

    private func persistFileCancellation(_ transfer: OutgoingFileTransfer) {
        guard fileCancellationTasks[transfer.id] == nil else { return }
        if transfer.cancelRequested { sendPendingFileManifest(transfer); return }
        let store = outgoingFileStore
        fileCancellationTasks[transfer.id] = Task {
            defer { fileCancellationTasks.removeValue(forKey: transfer.id) }
            do {
                let cancelled = try await Task.detached(priority: .utility) {
                    try store.requestCancellation(transfer)
                }.value
                guard pendingTransfers[transfer.id]?.peerFingerprint == transfer.peerFingerprint else { return }
                pendingTransfers[transfer.id] = cancelled
                // Keep admission alive for the cancellation ACK, including after a pause.
                fileTransferResumeCoordinator.register(cancelled.companionManifest)
                sendPendingFileManifest(cancelled)
            } catch {
                guard pendingTransfers[transfer.id] != nil else { return }
                fileTransferStatus[transfer.deviceID] = error.localizedDescription
            }
        }
    }

    func hasPendingFiles(deviceID: String) -> Bool {
        pendingTransfers.values.contains { $0.deviceID == deviceID }
            || filePreparationDevices.values.contains(deviceID)
    }
    func retryFileTransfers(deviceID: String) {
        activatePendingFileTransfers()
        resumePendingTransfers(deviceID: deviceID)
    }

    private func resumePendingTransfers(deviceID: String) {
        activatePendingFileTransfers()
        guard companionFiles(for: deviceID) != nil else { return }
        for manifest in fileTransferResumeCoordinator.manifestsForConnectedFilesChannel(deviceID: deviceID) {
            if let transfer = pendingTransfers[manifest.transferID] { sendPendingFileManifest(transfer) }
        }
    }

    nonisolated private static func protobufManifest(
        _ pending: PendingCompanionFileManifest
    ) -> GBTransferManifest {
        var manifest = GBTransferManifest()
        manifest.transferID = pending.transferID
        manifest.relativeName = pending.relativeName
        manifest.size = pending.size
        manifest.mimeType = pending.mimeType
        manifest.sha256 = pending.sha256
        return manifest
    }

    private func finishTransfer(_ transfer: OutgoingFileTransfer, status: String) {
        finishedFileTransferIDs.insert(transfer.id)
        pendingTransfers.removeValue(forKey: transfer.id)
        activeFileTransferIDs.remove(transfer.id)
        fileChunkTasks.removeValue(forKey: transfer.id)?.cancel()
        fileChunkTokens.removeValue(forKey: transfer.id)
        fileCancellationPendingIDs.remove(transfer.id)
        fileVerificationAttempts.removeValue(forKey: transfer.id)
        fileTransferResumeCoordinator.remove(transferID: transfer.id)
        let store = outgoingFileStore
        let removalID = UUID()
        let cancellation = fileCancellationTasks[transfer.id]
        fileRemovalTasks[removalID] = Task {
            defer { fileRemovalTasks.removeValue(forKey: removalID) }
            // A cancellation writer must settle before removing its manifest directory.
            await cancellation?.value
            do { try await Task.detached(priority: .utility) { try store.remove(transfer) }.value }
            catch { fileTransferStatus[transfer.deviceID] = error.localizedDescription }
        }
        fileTransferStatus[transfer.deviceID] = status
    }

#if !GALAXYBRIDGE_APP_STORE
    nonisolated private static func row(from device: ADBDevice) -> DeviceRow {
        DeviceRow(
            id: "adb:\(device.serial)",
            name: device.model ?? device.serial,
            subtitle: device.transport == .usbADB
                ? String(localized: "USB_ADB")
                : String(localized: "COMPANION_LAN"),
            transport: device.transport,
            isReady: device.state == .device,
            adbSerial: device.serial
        )
    }

    /// Test-only transport isolation for hardware QA while multiple aliases of
    /// the same phone are connected. Release builds always use normal routing.
    nonisolated private static var qaADBSerialOverride: String? {
        guard Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal" else { return nil }
        let prefix = "--qa-adb-serial="
        return ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(prefix) })
            .flatMap { argument in
                let value = String(argument.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
    }

    /// Internal-only exclusion keeps unrelated phones completely outside a
    /// hardware QA run without disconnecting their ADB sessions from the user.
    nonisolated private static var qaExcludedADBSerials: Set<String> {
        qaArgumentValues(prefix: "--qa-exclude-adb-serial=")
    }

#endif
    nonisolated private static var qaExcludedDeviceIDs: Set<String> {
#if GALAXYBRIDGE_APP_STORE
        []
#else
        Set(qaArgumentValues(prefix: "--qa-exclude-device-id=").map { $0.lowercased() })
#endif
    }

#if !GALAXYBRIDGE_APP_STORE
    nonisolated private static func qaArgumentValues(prefix: String) -> Set<String> {
        guard Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal" else { return [] }
        return Set(ProcessInfo.processInfo.arguments.compactMap { argument in
            guard argument.hasPrefix(prefix) else { return nil }
            let value = String(argument.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        })
    }
#endif
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

private struct CompanionConnections {
    let control: CompanionTLSClient
    let events: CompanionTLSClient
    let video: CompanionTLSClient
    let audio: CompanionTLSClient
    let camera: CompanionTLSClient
    let files: CompanionTLSClient

    var cancellationActions: [() -> Void] {
        [
            { control.cancel() },
            { events.cancel() },
            { video.cancel() },
            { audio.cancel() },
            { camera.cancel() },
            { files.cancel() },
        ]
    }

    func cancelAll() {
        control.cancel()
        events.cancel()
        video.cancel()
        audio.cancel()
        camera.cancel()
        files.cancel()
    }
}

private extension OutgoingFileTransfer {
    var companionManifest: PendingCompanionFileManifest {
        PendingCompanionFileManifest(transferID: id, deviceID: deviceID,
            relativeName: relativeName, size: size, mimeType: mimeType, sha256: sha256)
    }
}

private enum FileTransferError: Error, LocalizedError {
    case invalidFile
    case connectionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFile: String(localized: "FILE_INVALID")
        case .connectionUnavailable: String(localized: "FILE_CONNECTION_LOST")
        }
    }
}

private struct AppModelPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
