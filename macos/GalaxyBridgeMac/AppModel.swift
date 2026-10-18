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

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.postedAt == rhs.postedAt ? lhs.id < rhs.id : lhs.postedAt > rhs.postedAt
    }

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
    @Published private var companionConnectionErrors: [String: String] = [:]
    var displayedError: String? {
        lastError ?? selectedDeviceID.flatMap { companionConnectionErrors[$0] }
    }
    func dismissDisplayedError() {
        if lastError != nil { lastError = nil }
        else if let deviceID = selectedDeviceID { companionConnectionErrors.removeValue(forKey: deviceID) }
    }
    @Published var isPairingPresented = false
    @Published private(set) var enhancedStates: [String: ScrcpySessionState] = [:]
    private var enhancedSessionDiagnostics = EnhancedSessionDiagnostics()
    private let primaryMediaDiagnosticsEnabled: Bool
#if GB_INPUT_REPLAY_QA && !GALAXYBRIDGE_APP_STORE
    private let primaryTouchReplay = PrimaryTouchReplay()
#endif
    // Screen-interlock wiring is intentionally isolated from transport state.
    @Published private(set) var enhancedScreenInterlocks: [String: ScreenInterlockPresentation] = [:]
    @Published private(set) var recordingDeviceIDs: Set<String> = []
    @Published private(set) var activeRecordings: [ActiveRecordingSummary] = []
    @Published private(set) var notificationsByDevice: [String: [BridgeNotificationRow]] = [:]
    private var notificationSnapshotReconciliation = NotificationSnapshotReconciliation()
    @Published private(set) var notificationActions = NotificationActionState()
    private var notificationActionTimeouts: [String: Task<Void, Never>] = [:]
    private var notificationActionCleanup: Task<Void, Never>?
    private var notificationActionSavedRows: [NotificationActionIdentity: BridgeNotificationRow] = [:]
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
    @Published private(set) var applicationCatalogRequestsByDevice: [String: UUID] = [:]
    @Published private(set) var cameraStatusesByDevice: [String: CameraStatusViewState] = [:]

    let discovery = BonjourDiscovery()
    let pairing = PairingCoordinator()
    let cameraExtension = CameraExtensionManager()
    private var adbRows: [DeviceRow] = []
#if !GALAXYBRIDGE_APP_STORE
    private var adbTopologyRefreshState = ADBTopologyRefreshState()
    private var observedADBGeneration: UUID?
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
    private var shellProviders: [String: ShellCapabilityBridgeProvider] = [:]
    private var shellProviderSubscriptions: [String: AnyCancellable] = [:]
    private var shellProbeTasks: [String: Task<Void, Never>] = [:]
    private var shellProbeSessions: [String: String] = [:]
    private var shellProbeTickets: [String: UUID] = [:]
    private struct ShellReadinessPreparation {
        let ticket: UUID
        let deviceID: String
        let serial: String?
        let sessionID: String?
        let providerID: ObjectIdentifier
        let task: Task<Bool, Error>
    }
    private var shellRuntimeUpgradeTickets: [String: UUID] = [:]
    private var shellReadinessTasks: [String: ShellReadinessPreparation] = [:]
    private var shellPreferredDevices = Set<String>()
    private var captureRetirementAuthorities: [String: CaptureRetirementAuthority] = [:]
    private var requestedDirectDevices = Set<String>()
    private var preparingDirectDevices = Set<String>()
    @Published private var captureRouteTransitionDevices = Set<String>()
    private var captureRouteHandoffTasks: [String: Task<Void, Never>] = [:]
    private var captureRouteHandoffTickets: [String: UUID] = [:]
    private var captureRoutePendingWindows: [String: [ApplicationWindowCoordinator.RouteResume]] = [:]
    private var captureRoutePeerKeys: [String: Data] = [:]
    private var captureRouteRetryTasks: [String: Task<Void, Never>] = [:]
    private var captureRouteRetryTickets: [String: UUID] = [:]
    private var captureRouteAttemptSignatures: [String: String] = [:]
    private var captureRouteBackoffs: [String: ReconnectBackoff] = [:]
    @Published private var nearbyPreparationTasks: [String: Task<Void, Never>] = [:]
    private var nearbyPreparationTickets: [String: UUID] = [:]
    private var nearbyAutomaticPreparationTickets: [String: UUID] = [:]
    private struct NearbyReleasePending {
        let receipt: NearbyLeaseReceipt
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }
    private var nearbyReleasePending: [String: NearbyReleasePending] = [:]
    private weak var applicationWindowCoordinator: ApplicationWindowCoordinator?
    @Published private(set) var phoneDisplayPrivacyStatuses: [String: PhoneDisplayPrivacyStatus] = [:]
    @Published private var phonePrivacyPreferences = (UserDefaults.standard.dictionary(forKey: "PhoneDisplayPrivacyByDevice") as? [String: Bool]) ?? [:]
    private var phonePrivacyLeases: [UUID: (deviceID: String, serial: String)] = [:]
    private var primaryPhonePrivacyLeases: [ObjectIdentifier: UUID] = [:]
    private var phonePrivacyManualPower: [String: Bool] = [:]
    private var phonePrivacyUpdates: [String: Task<Void, Never>] = [:]
    private var phonePrivacyUpdateTickets: [String: UUID] = [:]
    private var phonePrivacyRoutes: [String: String] = [:]
    private var phonePrivacyAliases: [String: String] = [:]
    private lazy var phoneDisplayPrivacy: PhoneDisplayPrivacyCoordinator = {
        let coordinator = PhoneDisplayPrivacyCoordinator { [weak self] serial in
            return ScrcpyDisplayPowerSession(serial: serial, adb: try ADBClient(), shellProvider: self?.shellProviderForOwner(serial),
                shellProviderResolver: { [weak self] in self?.shellProviderForOwner($0) },
                retirementProofResolver: { [weak self] current in
                    let id = (try? ADBBindingStore().record(for: current)).map { "device:" + $0.deviceID } ?? "adb:" + current
                    return self?.displayControllerRetirementProof(deviceID: id, captureSerial: current)
                }, resourceReleaseResolver: { [weak self] current in
                    let id = (try? ADBBindingStore().record(for: current)).map { "device:" + $0.deviceID } ?? "adb:" + current
                    return self?.displayControllerResourceRelease(deviceID: id, captureSerial: current)
                })
        }
        coordinator.statusHandler = { [weak self] id, status in
            guard let self, self.activePhoneDisplayInteraction(deviceID: id) == nil else { return }
            if self.phoneDisplayPrivacyStatuses[id] != status { self.phoneDisplayPrivacyStatuses[id] = status }
        }
        coordinator.observedPowerHandler = { [weak self] id, on in
            if on { self?.phonePrivacyManualPower[id] = true }
            else { self?.phonePrivacyManualPower.removeValue(forKey: id) }
        }
        return coordinator
    }()
    private let companionTunnels = ADBCompanionTunnelCoordinator()
    private var companionTunnelLeases: [String: ADBCompanionTunnelLease] = [:]
    private var companionTunnelDesired: [String: (scope: String, serial: String)] = [:]
    private var companionTunnelTasks: [String: Task<Void, Never>] = [:]
    private var companionTunnelTokens: [String: UUID] = [:]
    private var enhancedSubscriptions: [ObjectIdentifier: Set<AnyCancellable>] = [:]
    private var enhancedRetirements: [UUID: Task<Void, Never>] = [:]
    private var unsettledEnhancedRetirements: [UUID: ScrcpySession] = [:]
    private var enhancedRetirementDeviceIDs: [UUID: String] = [:]
    private var enhancedReconnectTokens: [String: UUID] = [:]
    private var clipboardSessions: [String: ScrcpyClipboardSession] = [:]
    private var clipboardReconnectAttempts: [String: Int] = [:]
    private var clipboardReconnectTasks: [String: Task<Void, Never>] = [:]
#endif
    private var videoSurfaces: [String: VideoSurfaceModel] = [:]
    private var cameraSurfaces: [String: VideoSurfaceModel] = [:]
    let clientSetup = ClientSetupModel()
    private var featureConfigurationTimeouts: [String: Task<Void, Never>] = [:]
    private var featureConfigurationRequestIDs: [String: String] = [:]
    private var featureStartedMediaSessions: [String: String] = [:]
    private var featureStartedMediaFeatures: [String: Set<ClientSetupFeature>] = [:]
    private var featureClosedMediaChannels: [String: Set<ClientSetupFeature>] = [:]
    private var featureMediaChannelTokens: [String: [ClientSetupFeature: UUID]] = [:]
    private var featureIncomingTransferIDs: [String: Set<String>] = [:]
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
    private var clipboardPasteboard: NSPasteboard { .general }
    private let clipboardConversion = MacClipboardConversionWorker()
#if !GALAXYBRIDGE_APP_STORE
    private var clipboardSequence: UInt64 = 1
    private var clipboardVerifiedADBIdentities: [String: Data] = [:]
#endif
    private var pendingTransfers: [String: OutgoingFileTransfer] = [:]
    private let outgoingFileStore = OutgoingFileTransferStore()
#if !GALAXYBRIDGE_APP_STORE
    private let incomingDownloadsAccess = DownloadsFolderAccess()
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

#if !GALAXYBRIDGE_APP_STORE
    private var nearbyDirectEndpoints: [String: DiscoveredCompanion] = [:]
    private(set) lazy var internetSharing = InternetSharingCoordinator()

    @Published var isNearbyPairingPresented = false
    func nearbyIsPreparing(deviceID: String) -> Bool {
        let id = deviceID.hasPrefix("device:") ? deviceID : "device:" + deviceID
        return nearbyPreparationTasks[id] != nil || captureRouteHandoffTasks[id] != nil || captureRouteTransitionDevices.contains(id)
    }
    func nearbyConnectionHint(deviceID: String) -> String? {
        guard let id = companionID(for: deviceID), companionStates[id] == .connected,
              let control = companionClients[id]?.control else { return nil }
        return control.connectivityCapabilities.nearbyConnectionHint
    }
    func canConnectNearby(deviceID: String) -> Bool {
        canRevokePairing(deviceID: deviceID) && nearbyConnectionHint(deviceID: deviceID) == nil
    }
    func internetSharingAvailabilityKey(deviceID: String) -> String? {
        guard let id = companionID(for: deviceID), companionStates[id] == .connected,
              let control = companionClients[id]?.control else { return "INTERNET_PHONE_OFFLINE" }
        return control.connectivityCapabilities.internetSharingAvailabilityKey
    }
    private func nearbyPairingCommitted() {
        isNearbyPairingPresented = false
        mergeDevices()
    }
    @Published private var nearbyAutoPreferences = (UserDefaults.standard.dictionary(forKey: "NearbyAutoConnectByDevice") as? [String: Bool]) ?? [:]
    func nearbyAutoConnect(deviceID: String) -> Bool { nearbyAutoPreferences[deviceID] ?? true }
    func setNearbyAutoConnect(_ enabled: Bool, deviceID: String) {
        nearbyAutoPreferences[deviceID] = enabled
        UserDefaults.standard.set(nearbyAutoPreferences, forKey: "NearbyAutoConnectByDevice")
        if !enabled {
            if let ticket = nearbyAutomaticPreparationTickets[deviceID], nearbyPreparationTickets[deviceID] == ticket {
                // Retain the ticket until defer restores any suspended owners.
                nearbyPreparationTasks[deviceID]?.cancel()
                requestedDirectDevices.remove(deviceID)
            }
            nearbyConnection.cancelAutomaticConnection(deviceID: deviceID.removingPrefix("device:") ?? deviceID)
        }
        // Prepare advanced owners while their verified USB/ADB route still
        // exists, but do not change the Mac's healthy association in advance.
        if enabled, row(id: deviceID)?.adbSerial != nil {
            prepareNearbyConnection(deviceID: deviceID, automatic: true, connectAfterPreparation: false)
        }
    }
    private func reconnectNearbyIfIdle() {
        guard terminationAdmission.admitsWork else { return }
        for peer in (try? PairedPeerStore().peers()) ?? [] {
            let id = "device:" + peer.deviceID
            guard nearbyAutoConnect(deviceID: id), row(id: id)?.isReady != true else { continue }
            prepareNearbyConnection(deviceID: id, automatic: true)
        }
    }
    private(set) lazy var nearbyConnection: NearbyConnectionCoordinator = NearbyConnectionCoordinator(
        peers: { (try? PairedPeerStore().peers()) ?? [] },
        onDescriptor: { [weak self] descriptor in self?.acceptNearbyDescriptor(descriptor) },
        onPairingCommitted: { [weak self] in self?.nearbyPairingCommitted() },
        onVerifiedPairing: { [weak self] id in
            guard let self, self.nearbyAutoConnect(deviceID: "device:" + id) else { return }
            self.nearbyConnection.autoConnectIfUnassociated(deviceID: id)
        },
        onReleaseLease: { [weak self] deviceID, leaseID in
            guard let self else { return false }
            let released = await self.exchangeNearbyLease(deviceID: deviceID, leaseID: leaseID, confirmed: false)
            if !self.nearbyConnection.retainsLease(deviceID: deviceID) {
                self.nearbyDirectEndpoints.removeValue(forKey: deviceID)
                if self.terminationAdmission.admitsWork { self.mergeDevices() }
            }
            return released
        },
        onRenewLease: { [weak self] deviceID, leaseID in
            await self?.exchangeNearbyLease(deviceID: deviceID, leaseID: leaseID, confirmed: true) ?? false
        }
    )

    func setInternetSharing(_ enabled: Bool, deviceID: String) {
        guard !enabled || featureEnabled(.internet, deviceID: deviceID) else { return }
        let control = companionID(for: deviceID).flatMap { companionClients[$0]?.control }
        internetSharing.setEnabled(enabled, deviceID: deviceID, control: control)
    }
    func canShareInternet(deviceID: String) -> Bool {
        guard featureEnabled(.internet, deviceID: deviceID), let id = companionID(for: deviceID), companionStates[id] == .connected else { return false }
        return companionClients[id]?.control.supportsInternetGateway == true
    }
    func beginNearbyPairing() {
        beginNearbyPairing(candidateID: nil)
    }
    func beginNearbyPairing(candidateID: UUID?) {
        if let candidateID { nearbyConnection.beginConsentPairing(candidateID: candidateID) }
        else { nearbyConnection.showPairingChoices() }
        isNearbyPairingPresented = true
    }
    func connectNearby(deviceID: String) {
        prepareNearbyConnection(deviceID: deviceID, automatic: false)
    }
    func disconnectNearby(deviceID: String) {
        let id = deviceID.hasPrefix("device:") ? deviceID : "device:\(deviceID)"
        // Keep the canceled attempt's ticket until its defer restores any
        // suspended windows. A replacement cannot overtake that settlement.
        nearbyPreparationTasks[id]?.cancel()
        preparingDirectDevices.remove(id); shellPreferredDevices.remove(id)
        requestedDirectDevices.remove(id)
        let raw = deviceID.removingPrefix("device:") ?? deviceID
        nearbyConnection.disconnect(deviceID: raw)
        Task { [weak self] in
            guard let self else { return }
            await self.nearbyConnection.waitForRetirement()
            if !self.nearbyConnection.retainsLease(deviceID: raw) {
                self.nearbyDirectEndpoints.removeValue(forKey: raw)
                if self.terminationAdmission.admitsWork { self.mergeDevices() }
            }
        }
    }

    func registerApplicationWindowCoordinator(_ coordinator: ApplicationWindowCoordinator) { applicationWindowCoordinator = coordinator }

    func hasEnhancedTransport(deviceID: String) -> Bool {
#if GALAXYBRIDGE_APP_STORE
        return false
#else
        guard let device = row(id: deviceID), device.isReady else { return false }
        return device.adbSerial != nil || availableShellProvider(deviceID: deviceID) != nil
#endif
    }

#if !GALAXYBRIDGE_APP_STORE
    private func exchangeNearbyLease(deviceID: String, leaseID: String, confirmed: Bool) async -> Bool {
        let id = "device:" + deviceID
        guard UUID(uuidString: leaseID) != nil, nearbyReleasePending.count < 4,
              let control = companionControl(for: id) else { return false }
        let requestID = UUID().uuidString.lowercased()
        let receipt = NearbyLeaseReceipt(requestID: requestID, deviceID: deviceID, sessionID: control.authenticatedSessionID,
            expectedState: confirmed ? "established" : "disabled", expectedLeaseID: confirmed ? leaseID : "")
        return await withCheckedContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.nearbyReleasePending.removeValue(forKey: requestID)?.continuation.resume(returning: false)
            }
            nearbyReleasePending[requestID] = NearbyReleasePending(receipt: receipt, continuation: continuation, timeout: timeout)
            var request = GBDirectLinkRequest(); request.requestID = requestID; request.enabled = confirmed
            request.confirmed = confirmed; request.groupLeaseID = leaseID
            var envelope = GBEnvelope(); envelope.protocolMajor = 1
            envelope.deviceID = UserDefaults.standard.string(forKey: "com.xopmc.GalaxyBridge.host-id") ?? ""
            envelope.sessionID = control.authenticatedSessionID; envelope.directLinkRequest = request
            do { try control.send(envelope) }
            catch {
                if let pending = nearbyReleasePending.removeValue(forKey: requestID) {
                    pending.timeout.cancel(); pending.continuation.resume(returning: false)
                }
            }
        }
    }
    private func receiveNearbyRelease(_ status: GBDirectLinkStatus, deviceID: String, sessionID: String) {
        let raw = deviceID.removingPrefix("device:") ?? deviceID
        guard let pending = nearbyReleasePending[status.requestID],
              pending.receipt.accepts(requestID: status.requestID, deviceID: raw, sessionID: sessionID,
                                      state: status.state, error: status.errorCode, leaseID: status.groupLeaseID) else { return }
        nearbyReleasePending.removeValue(forKey: status.requestID)
        pending.timeout.cancel(); pending.continuation.resume(returning: true)
    }

    func shellBridgeProvider(deviceID: String) -> ShellCapabilityBridgeProvider? {
        if let existing = shellProviders[deviceID] { return existing }
        guard companionControl(for: deviceID)?.supportsShellBridge == true else { return nil }
        let hostID = UserDefaults.standard.string(forKey: "com.xopmc.GalaxyBridge.host-id") ?? ""
        let provider = ShellCapabilityBridgeProvider(hostID: hostID, control: { [weak self] in self?.companionControl(for: deviceID) })
        provider.runtimeUpgradeRequested = { [weak self, weak provider] in
            guard let self, let provider, self.shellProviders[deviceID] === provider,
                  self.shellProbeTasks[deviceID] == nil, self.terminationAdmission.admitsWork else { return }
            self.shellProbeSessions.removeValue(forKey: deviceID)
            self.reconcileShellCapabilities()
        }
        shellProviders[deviceID] = provider
        configurePhoneDisplayInteraction(provider.displayInteraction, deviceID: deviceID)
        shellProviderSubscriptions[deviceID] = provider.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return provider
    }
    private func availableShellProvider(deviceID: String) -> ShellCapabilityBridgeProvider? {
        guard let provider = shellProviders[deviceID], provider.available,
              let control = companionControl(for: deviceID),
              terminationAdmission.admitsWork, provider.bootGeneration != nil,
              let device = row(id: deviceID), device.isReady,
              deviceID == "device:" + control.peer.deviceID, control.supportsShellBridge,
              let id = companionID(for: deviceID), companionStates[id] == .connected else { return nil }
        return provider
    }
    private func activeShellProvider(deviceID: String) -> ShellCapabilityBridgeProvider? {
        guard let provider = availableShellProvider(deviceID: deviceID), let device = row(id: deviceID) else { return nil }
        if shellPreferredDevices.contains(deviceID) { return provider }
        // A prepared broker can serve new owners on the existing paired LAN.
        // Existing raw captures retain their backend until ordinary retirement.
#if GB_INPUT_REPLAY_QA
        if device.transport == .wirelessADB,
           PrimaryTouchReplayConfiguration.process?.prefersQuic(deviceID: deviceID,
               arguments: ProcessInfo.processInfo.arguments) == true { return nil }
#endif
        if QuicRuntimeArtifacts.explicitlyEnabled, device.transport == .wirelessADB { return nil }
        if let primary = scrcpySessions[deviceID], !primary.serial.hasPrefix("shell:") { return nil }
        if device.transport == .usbADB, device.adbSerial != nil,
           scrcpySessions[deviceID]?.serial.hasPrefix("shell:") != true,
           applicationWindowCoordinator?.hasOwnedShellCaptureWindows(deviceID: deviceID) != true { return nil }
        guard applicationWindowCoordinator?.hasOwnedADBCaptureWindows(deviceID: deviceID) != true,
              !enhancedRetirements.keys.contains(where: { enhancedRetirementDeviceIDs[$0] == deviceID }),
              !unsettledEnhancedRetirements.keys.contains(where: { enhancedRetirementDeviceIDs[$0] == deviceID }) else { return nil }
        return provider
    }
    private func shellProviderForOwner(_ serial: String) -> ShellCapabilityBridgeProvider? {
        guard serial.hasPrefix("shell:") else { return nil }
        return shellProviders["device:" + serial.dropFirst("shell:".count)]
    }
    func enhancedCaptureRoute(for device: DeviceRow) -> (serial: String, shellProvider: ShellCapabilityBridgeProvider?)? {
        guard device.isReady, !preparingDirectDevices.contains(device.id), !captureRouteTransitionDevices.contains(device.id) else { return nil }
#if GB_INPUT_REPLAY_QA
        if PrimaryTouchReplayConfiguration.process?.prefersQuic(deviceID: device.id,
            arguments: ProcessInfo.processInfo.arguments) == true {
            guard !shellPreferredDevices.contains(device.id),
                  scrcpySessions[device.id]?.serial.hasPrefix("shell:") != true,
                  applicationWindowCoordinator?.hasOwnedShellCaptureWindows(deviceID: device.id) != true,
                  !enhancedRetirements.keys.contains(where: { enhancedRetirementDeviceIDs[$0] == device.id }),
                  !unsettledEnhancedRetirements.keys.contains(where: { enhancedRetirementDeviceIDs[$0] == device.id }),
                  quicWirelessSelection(for: device) != nil else {
                Logger(subsystem: "com.xopmc.GalaxyBridge", category: "PrimaryTouchReplay")
                    .error("quic_replay_selection_rejected=incompatible_or_unvalidated_route")
                return nil
            }
        }
#endif
        if let provider = activeShellProvider(deviceID: device.id), let peer = companionControl(for: device.id)?.peer {
            return ("shell:" + peer.deviceID, provider)
        }
        guard let serial = device.adbSerial else { return nil }
        return (serial, nil)
    }
    private func enhancedContinuingRouteSerial(for device: DeviceRow, ownerSerial: String?) -> String? {
        guard device.isReady, !preparingDirectDevices.contains(device.id) else { return nil }
        if let ownerSerial, let provider = availableShellProvider(deviceID: device.id),
           provider === shellProviderForOwner(ownerSerial) { return ownerSerial }
        return enhancedCaptureRoute(for: device)?.serial
    }
    private func shellReadinessIsCurrent(deviceID: String, serial: String?, sessionID: String?,
                                         provider: ShellCapabilityBridgeProvider) -> Bool {
        terminationAdmission.admitsWork && row(id: deviceID) != nil && row(id: deviceID)?.adbSerial == serial &&
            companionControl(for: deviceID)?.authenticatedSessionID == sessionID && shellProviders[deviceID] === provider
    }

    private func refreshShellCapabilities(deviceID: String, serial: String?, sessionID: String?,
                                          provider: ShellCapabilityBridgeProvider) async throws -> Bool {
        try Task.checkCancellation()
        guard shellReadinessIsCurrent(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider) else {
            throw CancellationError()
        }
        let key = serial.map { "adb:" + $0 } ?? "device:" + deviceID
        if let preparation = shellReadinessTasks[key] ?? shellReadinessTasks.values.first(where: { $0.deviceID == deviceID }) {
            // A replacement route must let the old activation settle before it
            // can prepare the same physical phone under a new control session.
            if preparation.deviceID != deviceID || preparation.serial != serial || preparation.sessionID != sessionID ||
                preparation.providerID != ObjectIdentifier(provider) {
                _ = try? await preparation.task.value
                return try await refreshShellCapabilities(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider)
            }
            let ready = try await preparation.task.value
            try Task.checkCancellation()
            guard shellReadinessIsCurrent(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider) else {
                throw CancellationError()
            }
            return ready
        }
        let ticket = UUID()
        let task = Task { [weak self, weak provider] () throws -> Bool in
            guard let self, let provider else { throw CancellationError() }
            defer {
                if self.shellReadinessTasks[key]?.ticket == ticket { self.shellReadinessTasks.removeValue(forKey: key) }
            }
            let ready = await provider.refresh()
            try Task.checkCancellation()
            guard self.shellReadinessIsCurrent(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider) else {
                throw CancellationError()
            }
            if ready && !provider.needsRuntimeUpgrade { return true }
            guard let serial, let control = self.companionControl(for: deviceID),
                  ADBBindingStore().isVerified(serial: serial, peer: control.peer) else { return ready }
            guard provider.beginRuntimeUpgrade() else { return ready }
            self.shellRuntimeUpgradeTickets[deviceID] = ticket
            var pausedClipboard = false
            defer {
                provider.endRuntimeUpgrade()
                if self.shellRuntimeUpgradeTickets[deviceID] == ticket {
                    self.shellRuntimeUpgradeTickets.removeValue(forKey: deviceID)
                    if pausedClipboard && !self.preparingDirectDevices.contains(deviceID) {
                        self.reconcileEnhancedClipboardSessions()
                    }
                }
            }
            if ready, let clipboard = self.clipboardSessions[deviceID], clipboard.serial.hasPrefix("shell:") {
                self.clipboardSessions.removeValue(forKey: deviceID)
                self.clipboardReconnectTasks.removeValue(forKey: deviceID)?.cancel()
                self.clipboardReconnectAttempts.removeValue(forKey: deviceID)
                pausedClipboard = true
                await clipboard.stopAndWait()
            }
            try Task.checkCancellation()
            guard self.shellReadinessIsCurrent(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider) else {
                throw CancellationError()
            }
            guard provider.canUpgradeRuntimeSafely else { return ready }
            do { try await ShellCapabilityBridgeActivation.activate(adb: ADBClient(), serial: serial) }
            catch {
                try Task.checkCancellation()
                guard self.shellReadinessIsCurrent(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider) else {
                    throw CancellationError()
                }
                // Global Helper admission won a race with another owner. Keep
                // compatibility service alive; no busy runtime was replaced.
                if error as? ShellCapabilityBridgeFailure == .runtimeInUse { return await provider.refresh() }
                throw error
            }
            try Task.checkCancellation()
            guard self.shellReadinessIsCurrent(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider) else {
                throw CancellationError()
            }
            let activated = await provider.refresh()
            try Task.checkCancellation()
            guard self.shellReadinessIsCurrent(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider) else {
                throw CancellationError()
            }
            guard !activated || !control.supportsShellRuntimeIdentity || provider.currentRuntimeVerified else {
                throw ShellCapabilityBridgeFailure.invalidResult
            }
            return activated
        }
        shellReadinessTasks[key] = ShellReadinessPreparation(ticket: ticket, deviceID: deviceID, serial: serial,
            sessionID: sessionID, providerID: ObjectIdentifier(provider), task: task)
        let ready = try await task.value
        try Task.checkCancellation()
        guard shellReadinessIsCurrent(deviceID: deviceID, serial: serial, sessionID: sessionID, provider: provider) else {
            throw CancellationError()
        }
        return ready
    }

    private func validateNearbyPreparation(deviceID: String, ticket: UUID, automatic: Bool) throws {
        try Task.checkCancellation()
        guard terminationAdmission.admitsWork, nearbyPreparationTickets[deviceID] == ticket,
              !automatic || (nearbyAutoConnect(deviceID: deviceID) && nearbyAutomaticPreparationTickets[deviceID] == ticket)
        else { throw CancellationError() }
    }

    private func prepareNearbyConnection(deviceID: String, automatic: Bool, connectAfterPreparation: Bool = true) {
        let id = deviceID.hasPrefix("device:") ? deviceID : "device:" + deviceID
        guard terminationAdmission.admitsWork, (!automatic || nearbyAutoConnect(deviceID: id)),
              nearbyPreparationTasks[id] == nil, captureRouteHandoffTasks[id] == nil,
              !captureRouteTransitionDevices.contains(id), canConnectNearby(deviceID: id) else { return }
        let ticket = UUID(); nearbyPreparationTickets[id] = ticket
        if automatic { nearbyAutomaticPreparationTickets[id] = ticket }
        if connectAfterPreparation { requestedDirectDevices.insert(id) }
        nearbyPreparationTasks[id] = Task { [weak self] in
            guard let self else { return }
            var suspendedWindows: [ApplicationWindowCoordinator.RouteResume] = []
            var windowsResumed = false
            defer {
                if self.nearbyPreparationTickets[id] == ticket {
                    if self.nearbyAutomaticPreparationTickets[id] == ticket {
                        self.nearbyAutomaticPreparationTickets.removeValue(forKey: id)
                        if !self.nearbyAutoConnect(deviceID: id) || Task.isCancelled { self.requestedDirectDevices.remove(id) }
                    }
                    self.nearbyPreparationTickets.removeValue(forKey: id)
                    self.nearbyPreparationTasks.removeValue(forKey: id); self.preparingDirectDevices.remove(id)
                    if !windowsResumed, self.terminationAdmission.admitsWork, let device = self.row(id: id) {
                        self.reconcileEnhancedClipboardSessions(); self.reconcilePhoneDisplayPrivacyRoutes()
                        self.ensureEnhancedSessionForPrimaryDemand(for: device)
                        if !suspendedWindows.isEmpty {
                            self.applicationWindowCoordinator?.resumeAfterRouteChange(suspendedWindows, device: device, model: self)
                        }
                    }
                }
            }
            do {
                try self.validateNearbyPreparation(deviceID: id, ticket: ticket, automatic: automatic)
                guard let provider = self.shellBridgeProvider(deviceID: id), let device = self.row(id: id) else {
                    guard connectAfterPreparation else { return }
                    let raw = id.removingPrefix("device:") ?? id
                    if automatic { self.nearbyConnection.autoConnectIfUnassociated(deviceID: raw) }
                    else { self.nearbyConnection.connect(deviceID: raw) }
                    return
                }
                let serial = device.adbSerial
                let sessionID = self.companionControl(for: id)?.authenticatedSessionID
                do {
                    guard try await self.refreshShellCapabilities(deviceID: id, serial: serial, sessionID: sessionID, provider: provider) else {
                        throw ShellCapabilityBridgeFailure.unavailable
                    }
                } catch {
                    // Shell access is optional until advanced owners suspend.
                    // Cancellation or a replaced route must never use fallback.
                    try self.validateNearbyPreparation(deviceID: id, ticket: ticket, automatic: automatic)
                    if error is CancellationError { throw error }
                    guard self.shellReadinessIsCurrent(deviceID: id, serial: serial, sessionID: sessionID, provider: provider) else {
                        throw CancellationError()
                    }
                    guard connectAfterPreparation else { return }
                    let raw = id.removingPrefix("device:") ?? id
                    if automatic { self.nearbyConnection.autoConnectIfUnassociated(deviceID: raw) }
                    else { self.nearbyConnection.connect(deviceID: raw) }
                    return
                }
                try self.validateNearbyPreparation(deviceID: id, ticket: ticket, automatic: automatic)
                // Availability preparation must not interrupt active media or app windows.
                guard connectAfterPreparation else { return }
                let generation = provider.bootGeneration
                self.preparingDirectDevices.insert(id)
                let manualPower = self.phonePrivacyManualPower[id]
                let suspension = await self.applicationWindowCoordinator?.suspendForRouteChange(deviceID: id)
                suspendedWindows = suspension?.windows ?? []
                try self.validateNearbyPreparation(deviceID: id, ticket: ticket, automatic: automatic)
                guard suspension?.settled != false else { throw ShellCapabilityBridgeFailure.operationFailed }
                self.retireEnhancedScreenSession(deviceID: id)
                for (permit, task) in Array(self.enhancedRetirements) where self.enhancedRetirementDeviceIDs[permit] == id {
                    await task.value
                    try self.validateNearbyPreparation(deviceID: id, ticket: ticket, automatic: automatic)
                }
                guard !self.unsettledEnhancedRetirements.keys.contains(where: { self.enhancedRetirementDeviceIDs[$0] == id }) else {
                    throw ShellCapabilityBridgeFailure.operationFailed
                }
                if let clipboard = self.clipboardSessions.removeValue(forKey: id) { await clipboard.stopAndWait() }
                try self.validateNearbyPreparation(deviceID: id, ticket: ticket, automatic: automatic)
                await self.phoneDisplayPrivacy.waitForSettlement(deviceID: id)
                if case .failed = self.phoneDisplayPrivacy.status(deviceID: id) { throw ShellCapabilityBridgeFailure.operationFailed }
                try self.validateNearbyPreparation(deviceID: id, ticket: ticket, automatic: automatic)
                guard self.shellReadinessIsCurrent(deviceID: id, serial: serial, sessionID: sessionID, provider: provider),
                      provider.bootGeneration == generation else { throw CancellationError() }
                self.shellPreferredDevices.insert(id); self.preparingDirectDevices.remove(id)
                if let manualPower { self.phonePrivacyManualPower[id] = manualPower }
                self.reconcileEnhancedClipboardSessions(); self.reconcilePhoneDisplayPrivacyRoutes()
                if let device = self.row(id: id) {
                    self.ensureEnhancedSessionForPrimaryDemand(for: device)
                    self.applicationWindowCoordinator?.resumeAfterRouteChange(suspension?.windows ?? [], device: device, model: self)
                    windowsResumed = true
                }
                let raw = id.removingPrefix("device:") ?? id
                guard connectAfterPreparation else { return }
                if automatic { self.nearbyConnection.autoConnectIfUnassociated(deviceID: raw) }
                else { self.nearbyConnection.connect(deviceID: raw) }
            } catch is CancellationError {} catch { self.lastError = String(localized: "NEARBY_FAILED") }
        }
    }

    private func reconcileShellCapabilities() {
        guard terminationAdmission.admitsWork else { return }
        for device in devices where device.isReady {
            guard let control = companionControl(for: device.id), control.supportsShellBridge,
                  let provider = shellBridgeProvider(deviceID: device.id),
                  shellProbeTasks[device.id] == nil else { continue }
            let key = control.authenticatedSessionID + "|" + (device.adbSerial ?? "")
            guard shellProbeSessions[device.id] != key else { continue }
            shellProbeSessions[device.id] = key
            let ticket = UUID(); shellProbeTickets[device.id] = ticket
            shellProbeTasks[device.id] = Task { [weak self, weak provider] in
                guard let self, let provider else { return }
                defer {
                    if self.shellProbeTickets[device.id] == ticket {
                        self.shellProbeTickets.removeValue(forKey: device.id)
                        self.shellProbeTasks.removeValue(forKey: device.id)
                    }
                }
                let ready: Bool
                do {
                    ready = try await self.refreshShellCapabilities(deviceID: device.id, serial: device.adbSerial,
                        sessionID: control.authenticatedSessionID, provider: provider)
                } catch {
                    guard !(error is CancellationError), !Task.isCancelled,
                          self.shellReadinessIsCurrent(deviceID: device.id, serial: device.adbSerial,
                              sessionID: control.authenticatedSessionID, provider: provider) else { return }
                    ready = false // No capability is advertised until a current STATUS succeeds.
                }
                guard !Task.isCancelled,
                      self.shellReadinessIsCurrent(deviceID: device.id, serial: device.adbSerial,
                          sessionID: control.authenticatedSessionID, provider: provider) else { return }
                if ready, !self.shellPreferredDevices.contains(device.id),
                   self.requestedDirectDevices.contains(device.id) || (self.nearbyAutoConnect(deviceID: device.id) && device.adbSerial != nil) {
                    self.prepareNearbyConnection(deviceID: device.id, automatic: self.nearbyAutoConnect(deviceID: device.id),
                        connectAfterPreparation: self.requestedDirectDevices.contains(device.id))
                }
                if device.adbSerial == nil { self.loadApplicationCatalog(deviceID: device.id, force: true) }
                self.reconcileCaptureRouteHandoffs()
                self.reconcileEnhancedClipboardSessions(); self.reconcileEnhancedPrimaryRoutes(); self.reconcilePhoneDisplayPrivacyRoutes()
            }
        }
    }
#endif
    private func acceptNearbyDescriptor(_ descriptor: GBDirectLinkDescriptor) {
        guard terminationAdmission.admitsWork,
              let peer = (try? PairedPeerStore().peers())?.first(where: { $0.deviceID == descriptor.deviceID }),
              peer.identityPublicKey == descriptor.identityPublicKey,
              peer.tlsCertificateSHA256 == descriptor.tlsCertificateSha256,
              descriptor.companionPort > 0, descriptor.companionPort <= 65535,
              !descriptor.deviceAddress.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(descriptor.companionPort)) else { return }
        nearbyDirectEndpoints[peer.deviceID] = DiscoveredCompanion(id: "nearby:\(peer.deviceID)",
            name: peer.displayName, endpointDescription: String(localized: "NEARBY_CONNECTION"),
            endpoint: .hostPort(host: .init(descriptor.deviceAddress), port: port),
            identity: .init(deviceID: peer.deviceID,
                publicKeyFingerprint: Data(SHA256.hash(data: peer.identityPublicKey)), protocolMajor: 1))
        mergeDevices()
    }
#endif

#if GALAXYBRIDGE_APP_STORE
    func hasEnhancedTransport(deviceID: String) -> Bool { false }
#endif

    init() {
        primaryMediaDiagnosticsEnabled = PrimaryMediaDiagnostics.isEnabled(
            arguments: ProcessInfo.processInfo.arguments, bundleID: Bundle.main.bundleIdentifier
        )
        CompanionLifecycleEvents.pairingStoredPublisher()
            .sink { [cacheMaintenance] event in
                guard let peer = event.object as? PairedPeer,
                      let occurrence = event.userInfo?["cachePromotionOccurrence"] as? UUID else { return }
                let fingerprint = OutgoingFileTransferStore.peerFingerprint(identityKey: peer.identityPublicKey,
                    tlsFingerprint: peer.tlsCertificateSHA256, pairedAt: peer.pairedAt)
                cacheMaintenance.invalidateDevice("device:\(peer.deviceID)", occurrence: occurrence,
                    clipboardFingerprint: fingerprint, clipboardIdentity: ClipboardPeerIdentity.fingerprint(
                        publicKey: peer.identityPublicKey, tlsFingerprint: peer.tlsCertificateSHA256))
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
                        dismiss: response.dismiss,
                        composeID: response.reply == nil ? "" : UUID().uuidString.lowercased(),
                        replyPackageName: response.packageName,
                        replyAppLabel: response.appLabel
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
        discovery.companionsDidChange
            .prepend(())
            .sink { [weak self] _ in self?.mergeDevices() }
            .store(in: &cancellables)
        discovery.start()
#if !GALAXYBRIDGE_APP_STORE
        nearbyConnection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        internetSharing.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        nearbyConnection.startDiscovery()
        Timer.publish(every: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.reconnectNearbyIfIdle() }.store(in: &cancellables)
#endif
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
                    return (rows, routedAddresses, restoredWirelessSerials, client.acquiredGeneration)
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
                // A replacement daemon may enumerate identical USB serials;
                // its pinned capture clients still need ownership handoff.
                if observedADBGeneration != result.3 { shouldMerge = true }
                observedADBGeneration = result.3
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
        clipboardConversion.stop()
#if !GALAXYBRIDGE_APP_STORE
        for task in nearbyPreparationTasks.values { task.cancel() }
        for task in captureRouteHandoffTasks.values { task.cancel() }
        for task in captureRouteRetryTasks.values { task.cancel() }
        captureRoutePendingWindows.removeAll()
        for task in shellProbeTasks.values { task.cancel() }
        for preparation in shellReadinessTasks.values { preparation.task.cancel() }
        ADBOwnedRuntime.shared.beginShutdown()
#endif
        let cacheShutdown = cacheMaintenance.beginShutdown()
        for id in Array(audioVerificationRequests.keys) { cancelAudioVerification(deviceID: id) }
        clientSetup.invalidateAll()
        for task in featureConfigurationTimeouts.values { task.cancel() }; featureConfigurationTimeouts.removeAll()
        for task in fileChunkTasks.values { task.cancel() }
        primaryScreenDemand.removeAllDemand()
        let preparingFiles = Array(filePreparationTasks.values)
        for task in preparingFiles { task.cancel() }
        companionRecoverySupervisor.beginApplicationTermination()
        // Close every callback and timer admission point before the first
        // awaited cleanup. An in-flight topology result must not recreate a
        // clipboard or screen session while termination is draining its owner.
#if !GALAXYBRIDGE_APP_STORE
        await internetSharing.stop()
#endif
        cancellables.removeAll()
        pairing.stop()
        discovery.stop()
#if !GALAXYBRIDGE_APP_STORE
        nearbyDirectEndpoints.removeAll()
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
        for update in Array(phonePrivacyUpdates.values) { await update.value }
        await phoneDisplayPrivacy.stopAndWait()
        await nearbyConnection.stopAndWait()
#endif
        for connections in companionClients.values { connections.cancelAll() }
        companionClients.removeAll()
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
#if !GALAXYBRIDGE_APP_STORE
        nearbyPreparationTasks[deviceID]?.cancel()
        captureRouteHandoffTasks.removeValue(forKey: deviceID)?.cancel()
        captureRouteHandoffTickets.removeValue(forKey: deviceID)
        captureRouteRetryTasks.removeValue(forKey: deviceID)?.cancel()
        captureRouteRetryTickets.removeValue(forKey: deviceID)
        captureRoutePendingWindows.removeValue(forKey: deviceID)
        captureRoutePeerKeys.removeValue(forKey: deviceID)
        captureRouteTransitionDevices.remove(deviceID)
        captureRouteBackoffs.removeValue(forKey: deviceID)
        captureRouteAttemptSignatures.removeValue(forKey: deviceID)
        internetSharing.forget(deviceID: deviceID)
        nearbyConnection.revoke(deviceID: peerID)
        nearbyDirectEndpoints.removeValue(forKey: peerID)
        nearbyAutoPreferences.removeValue(forKey: deviceID)
        UserDefaults.standard.set(nearbyAutoPreferences, forKey: "NearbyAutoConnectByDevice")
#endif
        cacheMaintenance.invalidateDevice(deviceID, revoke: true)
        cancelAudioVerification(deviceID: deviceID)
        clientSetup.invalidate(deviceID: deviceID)
        do { try clientSetup.forget(deviceID: deviceID) }
        catch { lastError = String(localized: "CLIENT_SETUP_SAVE_FAILED") }
        primaryScreenDemand.revoke(deviceID)
#if !GALAXYBRIDGE_APP_STORE
        for (leaseID, lease) in Array(phonePrivacyLeases) where lease.deviceID == deviceID {
            releasePhoneDisplaySession(leaseID)
        }
#endif
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

            companionConnectionErrors.removeValue(forKey: deviceID)
            notificationsByDevice.removeValue(forKey: deviceID)
#if !GALAXYBRIDGE_APP_STORE
            shellProbeTasks.removeValue(forKey: deviceID)?.cancel()
            shellProbeSessions.removeValue(forKey: deviceID)
            shellProbeTickets.removeValue(forKey: deviceID)
            shellProviders.removeValue(forKey: deviceID)
            shellProviderSubscriptions.removeValue(forKey: deviceID)?.cancel()
            shellPreferredDevices.remove(deviceID); requestedDirectDevices.remove(deviceID)
#endif
            let notificationRequestIDs = notificationActions.pending.values.filter { $0.identity.deviceID == deviceID }.map(\.requestID)
            notificationRequestIDs.forEach { notificationActionTimeouts.removeValue(forKey: $0)?.cancel() }
            notificationActions.forget(deviceID: deviceID)
            notificationActionSavedRows = notificationActionSavedRows.filter { $0.key.deviceID != deviceID }
            maintainNotificationActions()
            notificationSnapshotReconciliation.forget(deviceID: deviceID)
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
            applicationCatalogRequestsByDevice.removeValue(forKey: deviceID)
            cameraStatusesByDevice.removeValue(forKey: deviceID)
            cameraRequestIDsByDevice.removeValue(forKey: deviceID)
            cameraLifecyclesByDevice.removeValue(forKey: deviceID)
            cameraRemoteStatusesByDevice.removeValue(forKey: deviceID)
            if selectedDeviceID == deviceID { selectedDeviceID = nil }
            mergeDevices()
            if devices.isEmpty { lastError = nil }
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

    func featureEnabled(_ feature: ClientSetupFeature, deviceID: String) -> Bool {
        clientSetup.isEnabled(feature, deviceID: deviceID)
    }

    func setFeatureSelection(deviceID: String, features: Set<ClientSetupFeature>) {
        let previous = clientSetup.selection(deviceID: deviceID)
        do { try clientSetup.saveSelection(deviceID: deviceID, features: features) }
        catch { lastError = String(localized: "CLIENT_SETUP_SAVE_FAILED"); return }
        let disabled = previous.subtracting(features)
        if previous.contains(.clipboard) != features.contains(.clipboard) {
            clipboardHub.forgetClipboard(deviceID: deviceID)
        }
        if disabled.contains(.notifications) {
            for row in notificationsByDevice[deviceID, default: []] {
                macNotifications.remove(deviceID: deviceID, notificationID: row.id)
            }
            notificationsByDevice.removeValue(forKey: deviceID)
            notificationSnapshotReconciliation.forget(deviceID: deviceID)
        }
        if disabled.contains(.calls) { callByDevice.removeValue(forKey: deviceID); callHistoryByDevice.removeValue(forKey: deviceID) }
        if disabled.contains(.audio) {
            cancelAudioVerification(deviceID: deviceID)
            recordingAudioSources.removeValue(forKey: deviceID)
        }
        updateAudioPlaybackDemand(deviceID: deviceID)
        if disabled.contains(.camera) { configureCamera(deviceID: deviceID, enabled: false) }
        if disabled.contains(.recording) || disabled.contains(.screen) {
            for recording in activeRecordings.filter({ $0.deviceID == deviceID }) { stopRecording(id: recording.id) }
        }
#if !GALAXYBRIDGE_APP_STORE
        // Audio is part of the scrcpy launch contract. Muting cannot revoke capture;
        // use the existing exact-owner retirement/settlement path before recreating it.
        if previous.contains(.audio) != features.contains(.audio), scrcpySessions[deviceID] != nil {
            retireEnhancedScreenSession(deviceID: deviceID)
        }
        if disabled.contains(.screen) {
            retireEnhancedScreenSession(deviceID: deviceID)
            videoSurfaces[deviceID]?.clearFrame()
        }
        if disabled.contains(.applications) {
            applicationCatalogRequestsByDevice.removeValue(forKey: deviceID)
            applicationCatalogsByDevice.removeValue(forKey: deviceID)
            applicationWindowCoordinator?.closeForFeaturePolicy(deviceID: deviceID)
        }
        if disabled.contains(.files) {
            for (jobID, owner) in filePreparationDevices where owner == deviceID {
                cancelledFilePreparationIDs.insert(jobID); filePreparationTasks[jobID]?.cancel()
            }
            for transfer in pendingTransfers.values.filter({ $0.deviceID == deviceID }) {
                pauseFileTransfer(transfer, status: String(localized: "FEATURE_DISABLED"))
            }
            if let fingerprint = filePeerFingerprints[deviceID] {
                let owner = IncomingFileOwner(deviceID: deviceID, fingerprint: fingerprint), store = incomingFileStore
                let ids = featureIncomingTransferIDs.removeValue(forKey: deviceID) ?? []
                for transferID in ids {
                    store.requestCancellation(owner: owner, id: transferID)
                    let taskID = UUID()
                    incomingFileTasks[taskID] = Task { [weak self] in
                        defer { self?.incomingFileTasks.removeValue(forKey: taskID) }
                        let receipt = await store.cancel(owner: owner, id: transferID)
                        self?.updateIncomingFileRow(deviceID: deviceID, receipt: receipt)
                    }
                }
            }
        }
        if disabled.contains(.internet) { setInternetSharing(false, deviceID: deviceID) }
        reconcileEnhancedClipboardSessions()
        if features.contains(.screen), let device = row(id: deviceID), primaryScreenDemand.hasViewer(deviceID) {
            ensureEnhancedSession(for: device)
        }
#endif
        if let id = companionID(for: deviceID), let connections = companionClients[id] {
            for feature in disabled.intersection([.screen, .audio, .camera, .files]) {
                featureClosedMediaChannels[deviceID, default: []].insert(feature)
                featureStartedMediaFeatures[deviceID]?.remove(feature)
                featureMediaChannelTokens[deviceID]?.removeValue(forKey: feature)
                switch feature {
                case .screen: connections.video.cancel()
                case .audio: connections.audio.cancel()
                case .camera: connections.camera.cancel()
                case .files: connections.files.cancel()
                default: break
                }
            }
        }
        reconcileFeatureConfiguration(deviceID: deviceID, force: true)
        objectWillChange.send()
    }

    private func reconcileFeatureConfiguration(deviceID: String, force: Bool = false) {
        guard let id = companionID(for: deviceID), companionStates[id] == .connected,
              let control = companionClients[id]?.control, control.connectivityCapabilities.negotiated else { return }
        guard control.supportsFeatureConfiguration else {
            clientSetup.markLegacy(deviceID: deviceID)
            startConfiguredCompanionMedia(deviceID: deviceID)
            return
        }
        guard force || clientSetup.synchronization(deviceID: deviceID) == .pending else { return }
        // One pending owner per phone. Capability refreshes must not replace its request.
        if !force, featureConfigurationTimeouts[deviceID] != nil { return }
        featureConfigurationTimeouts.removeValue(forKey: deviceID)?.cancel()
        do {
            let pending = try clientSetup.beginConfiguration(deviceID: deviceID, sessionID: control.authenticatedSessionID)
            var request = GBFeatureConfigurationRequest()
            request.requestID = pending.requestID; request.targetDeviceID = control.peer.deviceID
            request.revision = pending.revision; request.enabledFeatureIds = pending.enabledIDs.sorted()
            try control.sendFeatureConfiguration(request)
            featureConfigurationRequestIDs[deviceID] = pending.requestID
            featureConfigurationTimeouts[deviceID] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled, let self, self.featureConfigurationRequestIDs[deviceID] == pending.requestID else { return }
                self.featureConfigurationTimeouts.removeValue(forKey: deviceID)
                self.featureConfigurationRequestIDs.removeValue(forKey: deviceID)
                self.clientSetup.markConfigurationFailed(deviceID: deviceID, requestID: pending.requestID)
            }
        } catch {
            // Preserve the durable local policy. A send/storage failure is never phone acknowledgement.
            featureConfigurationRequestIDs.removeValue(forKey: deviceID)
            clientSetup.markConfigurationFailure(deviceID: deviceID)
        }
    }

    private func resetFeatureConfigurationForSession(deviceID: String) {
        featureConfigurationTimeouts.removeValue(forKey: deviceID)?.cancel()
        featureConfigurationRequestIDs.removeValue(forKey: deviceID)
        featureStartedMediaSessions.removeValue(forKey: deviceID)
        featureStartedMediaFeatures.removeValue(forKey: deviceID)
        featureClosedMediaChannels.removeValue(forKey: deviceID)
        featureMediaChannelTokens.removeValue(forKey: deviceID)
        clientSetup.disconnectConfiguration(deviceID: deviceID)
    }

    private func startConfiguredCompanionMedia(deviceID: String) {
        guard let id = companionID(for: deviceID), var connections = companionClients[id],
              companionStates[id] == .connected else { return }
        let sessionID = connections.control.authenticatedSessionID
        if featureStartedMediaSessions[deviceID] != sessionID {
            featureStartedMediaSessions[deviceID] = sessionID
            featureStartedMediaFeatures[deviceID] = []
        }
        for feature: ClientSetupFeature in [.screen, .audio, .camera, .files]
        where featureEnabled(feature, deviceID: deviceID) && featureStartedMediaFeatures[deviceID]?.contains(feature) != true {
            if featureClosedMediaChannels[deviceID]?.contains(feature) == true {
                guard let factory = connections.mediaFactories[feature] else { continue }
                let replacement = factory()
                switch feature {
                case .screen: connections.video = replacement
                case .audio: connections.audio = replacement
                case .camera: connections.camera = replacement
                case .files: connections.files = replacement
                default: continue
                }
                featureClosedMediaChannels[deviceID]?.remove(feature)
            }
            // Publish the replacement before starting it; callbacks must see their exact owner.
            companionClients[id] = connections
            featureStartedMediaFeatures[deviceID, default: []].insert(feature)
            switch feature {
            case .screen: connections.video.start()
            case .audio: connections.audio.start()
            case .camera: connections.camera.start()
            case .files: connections.files.start()
            default: break
            }
        }
#if !GALAXYBRIDGE_APP_STORE
        if let device = row(id: deviceID) { ensureEnhancedSessionForPrimaryDemand(for: device) }
#endif
    }

    private func handleFeatureConfigurationResult(companionID: String, deviceID: String,
        envelope: GBEnvelope, result: GBFeatureConfigurationResult) {
        guard let control = companionClients[companionID]?.control,
              result.targetDeviceID == control.peer.deviceID, envelope.deviceID == control.peer.deviceID,
              envelope.sessionID == control.authenticatedSessionID else { return }
        if clientSetup.receiveConfiguration(deviceID: deviceID, sessionID: envelope.sessionID,
            requestID: result.requestID, revision: result.revision,
            enabledIDs: Set(result.enabledFeatureIds), accepted: result.accepted) {
            featureConfigurationTimeouts.removeValue(forKey: deviceID)?.cancel()
            featureConfigurationRequestIDs.removeValue(forKey: deviceID)
            if result.accepted { startConfiguredCompanionMedia(deviceID: deviceID) }
        }
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
        guard terminationAdmission.admitsWork, featureEnabled(.recording, deviceID: deviceID), primaryScreenDemand.hasViewer(deviceID),
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
        guard terminationAdmission.admitsWork, featureEnabled(.recording, deviceID: deviceID), primaryScreenDemand.hasViewer(deviceID),
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
        guard terminationAdmission.admitsWork, featureEnabled(.applications, deviceID: deviceID) else { return }
        guard applicationCatalogRequestsByDevice[deviceID] == nil else { return }
        if !force, case .available = applicationCatalogsByDevice[deviceID] { return }
        guard let device = row(id: deviceID) else { return }
#if GALAXYBRIDGE_APP_STORE
        applicationCatalogsByDevice[deviceID] = .unavailable(.storeBuildUnsupported)
#else
        guard device.adbSerial != nil || companionControl(for: deviceID) != nil else {
            applicationCatalogsByDevice[deviceID] = .unavailable(.directConnectionRequired)
            return
        }
        let serial = device.adbSerial
        let preparedCatalogProvider = availableShellProvider(deviceID: deviceID)
            .flatMap { $0.currentRuntimeVerified ? $0 : nil }
        let catalogProvider = preparedCatalogProvider ?? (serial == nil ? shellBridgeProvider(deviceID: deviceID) : nil)
        let catalogControl = companionControl(for: deviceID)
        let catalogSession = catalogControl?.authenticatedSessionID
        let requestID = UUID()
        applicationCatalogRequestsByDevice[deviceID] = requestID
        let previous = applicationCatalogsByDevice[deviceID]
        if case .available = previous {} else { applicationCatalogsByDevice[deviceID] = .loading }
        let catalogStartedAt = ProcessInfo.processInfo.systemUptime
        Task {
            var usedBroker = catalogProvider != nil
            let loadUsingADB: @MainActor (String) async throws -> [ApplicationCatalogItem] = { [self] serial in
                guard terminationAdmission.admitsWork, featureEnabled(.applications, deviceID: deviceID),
                      applicationCatalogRequestsByDevice[deviceID] == requestID,
                      row(id: deviceID)?.adbSerial == serial else { throw CancellationError() }
                let client = ApplicationCatalogEnhancedClient(adb: try ADBClient())
                return try await Task.detached(priority: .userInitiated) {
                    try client.load(deviceID: deviceID, serial: serial)
                }.value
            }
            defer {
                if applicationCatalogRequestsByDevice[deviceID] == requestID {
                    applicationCatalogRequestsByDevice.removeValue(forKey: deviceID)
                    if case .loading = applicationCatalogsByDevice[deviceID] {
                        applicationCatalogsByDevice[deviceID] = .idle
                    }
                    if let current = row(id: deviceID), current.adbSerial != serial ||
                        (usedBroker && (companionControl(for: deviceID) !== catalogControl ||
                            companionControl(for: deviceID)?.authenticatedSessionID != catalogSession)) {
                        // A USB/Wi-Fi route change may have arrived while this
                        // request was running. Its view task could not start a
                        // second load until this owner had retired.
                        loadApplicationCatalog(deviceID: deviceID, force: true)
                    }
                }
            }
            guard terminationAdmission.admitsWork, featureEnabled(.applications, deviceID: deviceID),
                  applicationCatalogRequestsByDevice[deviceID] == requestID else { return }
            do {
                let items: [ApplicationCatalogItem]
                if let catalogProvider {
                    do {
                        items = try await catalogProvider.fetchApplicationCatalog()
                    } catch let failure as ShellCapabilityBridgeFailure where failure == .unavailable || failure == .timeout {
                        guard let serial, terminationAdmission.admitsWork, featureEnabled(.applications, deviceID: deviceID),
                              applicationCatalogRequestsByDevice[deviceID] == requestID,
                              row(id: deviceID)?.adbSerial == serial,
                              companionControl(for: deviceID) === catalogControl,
                              companionControl(for: deviceID)?.authenticatedSessionID == catalogSession else { throw CancellationError() }
                        usedBroker = false
                        items = try await loadUsingADB(serial)
                    }
                } else if let serial { items = try await loadUsingADB(serial) }
                else { throw ShellCapabilityBridgeFailure.unavailable }
                guard terminationAdmission.admitsWork, featureEnabled(.applications, deviceID: deviceID), applicationCatalogRequestsByDevice[deviceID] == requestID,
                      row(id: deviceID)?.adbSerial == serial,
                      !usedBroker || (companionControl(for: deviceID) === catalogControl &&
                          companionControl(for: deviceID)?.authenticatedSessionID == catalogSession) else { return }
                if primaryMediaDiagnosticsEnabled {
                    let source = usedBroker ? "broker" : "adb"
                    let elapsed = (ProcessInfo.processInfo.systemUptime - catalogStartedAt) * 1_000
                    let icons = items.filter { $0.iconPNG != nil }.count
                    Logger(subsystem: "com.xopmc.GalaxyBridge", category: "ApplicationCatalog")
                        .info("catalog_ready source=\(source, privacy: .public) count=\(items.count) elapsed_ms=\(elapsed) icons=\(icons)")
                }
                applicationCatalogsByDevice[deviceID] = .available(items)
            } catch {
                guard terminationAdmission.admitsWork, featureEnabled(.applications, deviceID: deviceID), applicationCatalogRequestsByDevice[deviceID] == requestID,
                      row(id: deviceID)?.adbSerial == serial,
                      !usedBroker || (companionControl(for: deviceID) === catalogControl &&
                          companionControl(for: deviceID)?.authenticatedSessionID == catalogSession) else { return }
                if primaryMediaDiagnosticsEnabled {
                    let kind = (error as? ShellCapabilityBridgeFailure).map { String(describing: $0) }
                        ?? String(reflecting: type(of: error))
                    Logger(subsystem: "com.xopmc.GalaxyBridge", category: "ApplicationCatalog")
                        .info("catalog_failed broker=\(usedBroker) error_type=\(kind, privacy: .public)")
                }
                if case .available = previous {
                    lastError = error.localizedDescription
                } else {
                    applicationCatalogsByDevice[deviceID] = .failed(error.localizedDescription)
                }
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

    func enhancedClipboardIdentity(deviceID: String, serial: String) -> Data? {
#if !GALAXYBRIDGE_APP_STORE
        if serial.hasPrefix("shell:"), let peer = companionControl(for: deviceID)?.peer {
            return ClipboardPeerIdentity.fingerprint(publicKey: peer.identityPublicKey, tlsFingerprint: peer.tlsCertificateSHA256)
        }
        return clipboardVerifiedADBIdentities[serial]
#else
        return nil
#endif
    }

    func acceptEnhancedClipboard(deviceID: String, changeID: String, content: Data, sourceIdentity: Data? = nil) {
#if !GALAXYBRIDGE_APP_STORE
        guard clipboardSessions[deviceID]?.usesClipboardOccurrences != true else { return }
#endif
        acceptRemoteClipboard(
            deviceID: deviceID,
            changeID: changeID,
            kind: .text,
            content: content,
            sensitive: false,
            sourceIdentity: sourceIdentity
        )
    }

    #if !GALAXYBRIDGE_APP_STORE
    func quicWirelessSelection(for device: DeviceRow) -> QuicWirelessSelection? {
#if GB_INPUT_REPLAY_QA
        let enabled = QuicRuntimeArtifacts.explicitlyEnabled ||
            PrimaryTouchReplayConfiguration.process?.prefersQuic(deviceID: device.id,
                arguments: ProcessInfo.processInfo.arguments) == true
#else
        let enabled = QuicRuntimeArtifacts.explicitlyEnabled
#endif
        guard enabled, device.transport == .wirelessADB, device.isReady,
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
        guard terminationAdmission.admitsWork, featureEnabled(.screen, deviceID: device.id), primaryScreenDemand.canStart(device.id) else { return }
        guard device.isReady, let route = enhancedCaptureRoute(for: device) else { return }
        if route.shellProvider != nil, let control = companionControl(for: device.id), control.supportsFeatureConfiguration,
           clientSetup.synchronization(deviceID: device.id) != .acknowledged { return }
        if let existing = scrcpySessions[device.id] {
            if existing.serial != route.serial, activeShellProvider(deviceID: device.id) != nil || existing.serial.hasPrefix("shell:") {
                retireEnhancedScreenSession(deviceID: device.id); return
            }
            if let serial = device.adbSerial, serial != existing.serial,
               let route = verifiedEnhancedRetirementRoute(deviceID: device.id, captureSerial: existing.serial) {
                existing.installVerifiedCleanupRoute(route)
                retireEnhancedScreenSession(deviceID: device.id)
                return
            }
            if case .failed = existing.state { scheduleEnhancedReconnect(deviceID: device.id, session: existing) }
            return
        }
        guard canStartLogicalSession(device.id) else { return }
        let serial = route.serial
        do {
            // Hardware QA can explicitly preserve an unlocked phone's display.
            // This does not alter customer preferences or production behavior.
            let preservePhoneDisplay = Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
                && ProcessInfo.processInfo.arguments.contains("--keep-phone-display-on")
            let session = ScrcpySession(serial: serial, adb: try ADBClient(),
                automaticDisplayManagement: false,
                primaryDiagnosticsEnabled: primaryMediaDiagnosticsEnabled,
                clipboardPollingEnabled: false,
                audioCaptureEnabled: featureEnabled(.audio, deviceID: device.id),
                quicSelection: quicWirelessSelection(for: device), shellProvider: route.shellProvider,
                remoteAbsenceProof: captureRetirementAbsenceProof(deviceID: device.id, captureSerial: serial))
            scrcpySessions[device.id] = session
            primaryPhonePrivacyLeases[ObjectIdentifier(session)] = UUID()
            var subscriptions = Set<AnyCancellable>()
            bindEnhancedNativeFrames(session, deviceID: device.id)
            session.clipboardEventHandler = { [weak self, weak session] update in
                guard let self, let session, let targetID = self.activeEnhancedDeviceID(session) else { return }
                guard self.clipboardSessions[targetID]?.usesClipboardOccurrences != true else { return }
                self.acceptRemoteClipboard(deviceID: targetID, changeID: update.changeID,
                    kind: update.kind == .png ? .png : .text, content: update.content, sensitive: false,
                    sourceRouteID: "screen:" + session.clipboardTrustGeneration.uuidString)
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
                case .preparing:
                    self.releasePrimaryPhonePrivacy(session)
                    self.videoSurfaces[targetID]?.clearFrame()
                case .streaming:
                    if serial.hasPrefix("shell:") { self.cacheMaintenance.reevaluateClipboardRoutes(deviceID: targetID) }
                    self.enhancedReconnectAttempts[targetID] = 0
                    self.enhancedReconnectTasks.removeValue(forKey: targetID)?.cancel()
                    self.detachGamepads(from: targetID)
                    self.syncGamepadsToSelectedSession()
                    if route.shellProvider == nil { self.loadEnhancedDisplays(deviceID: targetID, serial: serial) }
                case .failed:
                    self.releasePrimaryPhonePrivacy(session)
                    self.cancelAudioVerification(deviceID: targetID)
                    self.clientSetup.invalidate(deviceID: targetID)
                    self.scheduleEnhancedReconnect(deviceID: targetID, session: session)
                case .stopped:
                    self.releasePrimaryPhonePrivacy(session)
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
            session.$phoneDisplayPrivacyReady.sink { [weak self, weak session] ready in
                guard ready, !preservePhoneDisplay, let self, let session,
                      !session.usesCompositeDisplayInteraction,
                      let targetID = self.activeEnhancedDeviceID(session),
                      let lease = self.primaryPhonePrivacyLeases[ObjectIdentifier(session)] else { return }
                self.phoneDisplaySessionReady(deviceID: targetID, serial: session.serial, leaseID: lease)
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
        let enabled = featureEnabled(.audio, deviceID: deviceID) && primaryScreenDemand.hasViewer(deviceID)
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
        releasePrimaryPhonePrivacy(session)
        primaryPhonePrivacyLeases.removeValue(forKey: ObjectIdentifier(session))
        enhancedSubscriptions.removeValue(forKey: ObjectIdentifier(session))
        enhancedStates[deviceID] = .stopped
        _ = mediaTransportDispatchGate(for: deviceID).update(enhancedState: .stopped)
        retireEnhancedScreenSession(session, deviceID: deviceID)
    }

    private func retireEnhancedScreenSession(_ session: ScrcpySession, deviceID: String) {
        let permit = primaryScreenDemand.beginRetirement(deviceID)
        enhancedRetirementDeviceIDs[permit] = deviceID
        // Stop closes transport/frame admission before returning; the async
        // barrier settles resource acquisition and native work before restart.
        session.stop()
        videoSurfaces[deviceID]?.clearFrame()
        enhancedRetirements[permit] = Task { [weak self] in
            await session.stopAndWaitForCleanup()
            guard let self else { return }
            if let failure = session.displayRestorationFailure {
                self.phoneDisplayPrivacyStatuses[deviceID] = .failed(failure)
            }
            self.enhancedRetirements.removeValue(forKey: permit)
            guard session.cleanupPhysicallySettled else {
                self.unsettledEnhancedRetirements[permit] = session
                self.lastError = String(localized: "ERROR_MEDIA_CLEANUP")
                return
            }
            guard let canonicalID = self.primaryScreenDemand.finishRetirement(permit),
                  self.terminationAdmission.admitsWork,
                  let device = self.row(id: canonicalID) else { return }
            self.enhancedRetirementDeviceIDs.removeValue(forKey: permit)
            self.ensureEnhancedSession(for: device)
        }
    }

    private func releasePhysicallySettledEnhancedRetirements() {
        for (permit, session) in unsettledEnhancedRetirements where session.cleanupPhysicallySettled {
            unsettledEnhancedRetirements.removeValue(forKey: permit)
            enhancedRetirementDeviceIDs.removeValue(forKey: permit)
            _ = primaryScreenDemand.finishRetirement(permit)
        }
    }
#endif

#if !GALAXYBRIDGE_APP_STORE
    private func bindEnhancedNativeFrames(_ session: ScrcpySession, deviceID: String) {
        let surface = videoSurface(for: deviceID)
        session.setPlaybackEnabled(featureEnabled(.audio, deviceID: deviceID) && primaryScreenDemand.hasViewer(deviceID))
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
#if GB_INPUT_REPLAY_QA && !GALAXYBRIDGE_APP_STORE
            self.observePrimaryTouchReplay(frame, session: session, deviceID: deviceID)
#endif
        }
    }

#if GB_INPUT_REPLAY_QA && !GALAXYBRIDGE_APP_STORE
    private func observePrimaryTouchReplay(_ frame: NativeDecodedFrame, session: ScrcpySession, deviceID: String) {
        if frame.isAdmitted, self.acceptsScreenMedia(.enhanced, deviceID: deviceID),
           let diagnostics = session.primaryDiagnostics {
            let source = frame.context.attempt.id.attemptID
            let binding = frame.context.binding
            let size = session.videoSize
            self.primaryTouchReplay.observe(peerID: deviceID, attemptID: source,
                markerReady: diagnostics.touchReplayBaselineReady, retire: { [weak session] in
                    guard let session, session.nativeOwner?.attempt.id.attemptID == source else { return }
                    session.stop()
                }) { [weak self, weak session] event in
                guard let self, let session, self.activeEnhancedDeviceID(session) == deviceID,
                      session.nativeOwner?.attempt.id.attemptID == source, session.nativeOwner?.attempt.isAdmitted == true,
                      binding?.isAdmitted ?? true,
                      self.acceptsScreenMedia(.enhanced, deviceID: deviceID),
                      let deliverySize = event.deliverySize(initial: size, current: session.videoSize) else { return false }
                let action: ScrcpyMotionAction = switch event.action {
                case .down: .down; case .move: .move; case .up: .up; case .cancel: .cancel
                }
                let width = UInt16(deliverySize.width), height = UInt16(deliverySize.height)
                var bytes = ScrcpyControlMessage.virtualFingerTouch(action: action,
                    x: Int32(event.x * Double(width - 1)), y: Int32(event.y * Double(height - 1)),
                    screenWidth: width, screenHeight: height, pressure: event.counter == nil ? 0 : 1)
                guard bytes.count == 32 else { return false }
                bytes[22] = UInt8(event.pressure >> 8); bytes[23] = UInt8(event.pressure & 255)
                let trace = diagnostics.received(stream: .control, bytes: bytes.count, pts: nil, epoch: nil, now: ProcessInfo.processInfo.systemUptime)
                session.sendControl(bytes, diagnosticTrace: trace)
                return true
            }
        }
    }
#endif

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
        guard hasEnhancedTransport(deviceID: deviceID) else { return }
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
        if row(id: deviceID)?.transport == .companionLAN && !hasEnhancedTransport(deviceID: deviceID) {
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
        guard featureEnabled(.clipboard, deviceID: deviceID), hasEnhancedTransport(deviceID: deviceID) else { return false }
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
        guard featureEnabled(.clipboard, deviceID: deviceID) else { return false }
        return sendEnhancedKeyViaCompanion(
            deviceID: deviceID,
            isDown: true,
            keycode: operation == .cut ? 52 : 31,
            repeatCount: 0,
            modifiers: 0x1000 | 0x2000
        )
    }

    func sendText(deviceID: String, text: String) {
        guard !text.isEmpty else { return }
        if row(id: deviceID)?.transport == .companionLAN && !hasEnhancedTransport(deviceID: deviceID) {
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
        let id = canonicalPhonePrivacyID(deviceID)
        phonePrivacyManualPower[id] = on
        if let interaction = activePhoneDisplayInteraction(deviceID: id) {
            interaction.setManualPower(on: on)
            return
        }
        requestPhoneDisplayPrivacyUpdate(deviceID: id)
#endif
    }

#if !GALAXYBRIDGE_APP_STORE
    private func activePhoneDisplayInteraction(deviceID: String) -> PhoneDisplayInteractionCoordinator? {
        guard let interaction = shellProviders[deviceID]?.displayInteraction,
              interaction.hasOutstandingOwnership else { return nil }
        return interaction
    }

    private func configurePhoneDisplayInteraction(_ interaction: PhoneDisplayInteractionCoordinator, deviceID: String) {
        interaction.setPrivacyEnabled(phoneDisplayPrivacyEnabled(deviceID: deviceID))
        interaction.statusHandler = { [weak self, weak interaction] status in
            guard let self, let interaction, self.shellProviders[deviceID]?.displayInteraction === interaction else { return }
            if status == .preparing, let manual = self.phonePrivacyManualPower[deviceID] {
                interaction.setManualPower(on: manual)
            }
            self.publishCompositePhoneDisplayStatus(status, deviceID: deviceID)
        }
        publishCompositePhoneDisplayStatus(interaction.status, deviceID: deviceID)
    }

    private func publishCompositePhoneDisplayStatus(_ status: PhoneDisplayInteractionCoordinator.Status, deviceID: String) {
        let value: PhoneDisplayPrivacyStatus
        switch status {
        case .idle:
            guard !phonePrivacyLeases.values.contains(where: { $0.deviceID == deviceID }) else { return }
            if activePhoneDisplayInteraction(deviceID: deviceID) == nil, captureRouteHandoffTasks[deviceID] == nil {
                phonePrivacyManualPower.removeValue(forKey: deviceID)
            }
            value = phoneDisplayPrivacyEnabled(deviceID: deviceID) ? .waitingForSession : .disabled
        case .preparing: value = .preparing
        case .hidden: value = .hidden
        case .visible: value = .visible
        case .restoring: value = .restoring
        case .failed: value = .failed(String(localized: "ERROR_SCREEN_CONNECTION"))
        }
        if phoneDisplayPrivacyStatuses[deviceID] != value { phoneDisplayPrivacyStatuses[deviceID] = value }
    }

    func phoneDisplayPrivacyEnabled(deviceID: String) -> Bool {
        phonePrivacyPreferences[canonicalPhonePrivacyID(deviceID)] ?? true
    }

    func setPhoneDisplayPrivacy(_ enabled: Bool, deviceID: String) {
        let id = canonicalPhonePrivacyID(deviceID)
        phonePrivacyPreferences[id] = enabled
        UserDefaults.standard.set(phonePrivacyPreferences, forKey: "PhoneDisplayPrivacyByDevice")
        phonePrivacyManualPower.removeValue(forKey: id)
        if let interaction = shellProviders[id]?.displayInteraction {
            interaction.setPrivacyEnabled(enabled)
            if interaction.hasOutstandingOwnership { return }
            publishCompositePhoneDisplayStatus(interaction.status, deviceID: id)
        }
        requestPhoneDisplayPrivacyUpdate(deviceID: id)
    }

    func retryPhoneDisplayPrivacy(deviceID: String) {
        let id = canonicalPhonePrivacyID(deviceID)
        guard terminationAdmission.admitsWork, captureRouteHandoffTasks[id] == nil else { return }
        guard let interaction = activePhoneDisplayInteraction(deviceID: id) else {
            requestPhoneDisplayPrivacyUpdate(deviceID: id)
            return
        }
        let preceding = phonePrivacyUpdates[id], ticket = UUID()
        phonePrivacyUpdateTickets[id] = ticket
        phonePrivacyUpdates[id] = Task { [weak self] in
            await preceding?.value
            guard let self else { return }
            defer {
                if self.phonePrivacyUpdateTickets[id] == ticket {
                    self.phonePrivacyUpdates.removeValue(forKey: id)
                    self.phonePrivacyUpdateTickets.removeValue(forKey: id)
                }
            }
            @MainActor func isCurrent() -> Bool {
                self.terminationAdmission.admitsWork && self.phonePrivacyUpdateTickets[id] == ticket
                    && self.captureRouteHandoffTasks[id] == nil
                    && self.shellProviders[id]?.displayInteraction === interaction
            }
            guard isCurrent() else { return }
            // Producers retain their demands until exact owned cleanup is
            // confirmed. Poll cannot release a panel owner with demands left.
            _ = await self.settlePrimaryCaptureRetirements(deviceID: id)
            guard isCurrent() else { return }
            _ = await self.applicationWindowCoordinator?.retryRetiringOwners(deviceID: id)
            guard isCurrent() else { return }
            await interaction.poll()
        }
    }

    func phoneDisplaySessionReady(deviceID: String, serial: String, leaseID: UUID) {
        let id = canonicalPhonePrivacyID(deviceID)
        guard phonePrivacyLeases[leaseID] == nil, terminationAdmission.admitsWork else { return }
        phonePrivacyLeases[leaseID] = (id, serial)
        phonePrivacyRoutes[id] = row(id: id)?.isReady == true ? row(id: id)?.adbSerial : nil
        phoneDisplayPrivacy.acquireLease(deviceID: id, leaseID: leaseID)
        requestPhoneDisplayPrivacyUpdate(deviceID: id)
    }

    func releasePhoneDisplaySession(_ leaseID: UUID) {
        guard let lease = phonePrivacyLeases.removeValue(forKey: leaseID) else { return }
        phoneDisplayPrivacy.releaseLease(deviceID: lease.deviceID, leaseID: leaseID)
        if captureRouteHandoffTasks[lease.deviceID] == nil,
           !phonePrivacyLeases.values.contains(where: { $0.deviceID == lease.deviceID }) {
            phonePrivacyManualPower.removeValue(forKey: lease.deviceID)
        }
    }

    private func releasePrimaryPhonePrivacy(_ session: ScrcpySession) {
        if let lease = primaryPhonePrivacyLeases[ObjectIdentifier(session)] { releasePhoneDisplaySession(lease) }
    }

    private func canonicalPhonePrivacyID(_ id: String) -> String { phonePrivacyAliases[id] ?? id }

    private func requestPhoneDisplayPrivacyUpdate(deviceID: String) {
        let preceding = phonePrivacyUpdates[deviceID]
        let ticket = UUID()
        phonePrivacyUpdateTickets[deviceID] = ticket
        phonePrivacyUpdates[deviceID] = Task { [weak self] in
            await preceding?.value
            guard let self, self.phonePrivacyUpdateTickets[deviceID] == ticket else { return }
            defer {
                if self.phonePrivacyUpdateTickets[deviceID] == ticket {
                    self.phonePrivacyUpdates.removeValue(forKey: deviceID)
                    self.phonePrivacyUpdateTickets.removeValue(forKey: deviceID)
                }
            }
            if let interaction = self.activePhoneDisplayInteraction(deviceID: deviceID) {
                interaction.setPrivacyEnabled(self.phoneDisplayPrivacyEnabled(deviceID: deviceID))
                if let manual = self.phonePrivacyManualPower[deviceID] { interaction.setManualPower(on: manual) }
                await interaction.waitForSettlement()
                return
            }
            let ready = self.row(id: deviceID)
            let ownedSerial = self.phonePrivacyLeases.values.first(where: { $0.deviceID == deviceID })?.serial
            let serial = ready.flatMap { self.enhancedContinuingRouteSerial(for: $0, ownerSerial: ownedSerial) } ?? ownedSerial
            guard let serial else { return }
            let requested = self.phoneDisplayPrivacyEnabled(deviceID: deviceID)
            let manualPower = self.phonePrivacyManualPower[deviceID]
            let reachable = self.hasEnhancedTransport(deviceID: deviceID) && !self.preparingDirectDevices.contains(deviceID)
            do {
                // The privacy coordinator is the sole panel owner. OFF means
                // leave the phone active, never enter legacy brightness blackout.
                try await self.scrcpySessions[deviceID]?.setAutomaticDisplayManagement(false)
                self.phoneDisplayPrivacy.setEnabled(requested && reachable, deviceID: deviceID, serial: serial)
                if reachable, let manualPower {
                    self.phoneDisplayPrivacy.setManualPower(on: manualPower, deviceID: deviceID, serial: serial)
                }
                await self.phoneDisplayPrivacy.waitForSettlement(deviceID: deviceID)
                if case .failed = self.phoneDisplayPrivacy.status(deviceID: deviceID) { return }
            } catch {
                self.phoneDisplayPrivacyStatuses[deviceID] = .failed(String(describing: error))
            }
        }
    }

    private func migratePhoneDisplayPrivacy(from oldID: String, to newID: String) {
        phonePrivacyAliases[oldID] = newID
        if phonePrivacyPreferences[newID] == nil, let preference = phonePrivacyPreferences[oldID] {
            phonePrivacyPreferences[newID] = preference
            UserDefaults.standard.set(phonePrivacyPreferences, forKey: "PhoneDisplayPrivacyByDevice")
        }
        let migrating = phonePrivacyLeases.filter { $0.value.deviceID == oldID }
        guard !migrating.isEmpty else { return }
        let oldUpdate = phonePrivacyUpdates[oldID], newUpdate = phonePrivacyUpdates[newID]
        for (leaseID, lease) in migrating { phonePrivacyLeases[leaseID] = (newID, lease.serial) }
        phonePrivacyManualPower[newID] = phonePrivacyManualPower.removeValue(forKey: oldID)
        phonePrivacyUpdates[newID] = Task { [weak self] in
            await oldUpdate?.value
            await newUpdate?.value
            guard let self else { return }
            for leaseID in migrating.keys {
                self.phoneDisplayPrivacy.releaseLease(deviceID: oldID, leaseID: leaseID)
            }
            await self.phoneDisplayPrivacy.waitForSettlement(deviceID: oldID)
            if case let .failed(message) = self.phoneDisplayPrivacy.status(deviceID: oldID) {
                self.phoneDisplayPrivacyStatuses[newID] = .failed(message)
                return
            }
            for leaseID in migrating.keys where self.phonePrivacyLeases[leaseID]?.deviceID == newID {
                self.phoneDisplayPrivacy.acquireLease(deviceID: newID, leaseID: leaseID)
            }
            self.requestPhoneDisplayPrivacyUpdate(deviceID: newID)
        }
    }

    private func reconcilePhoneDisplayPrivacyRoutes() {
        let ids = Set(phonePrivacyLeases.values.map(\.deviceID)).union(phonePrivacyRoutes.keys)
        for id in ids {
            let device = row(id: id)
            let ownedSerial = phonePrivacyLeases.values.first(where: { $0.deviceID == id })?.serial
            let route = device.flatMap { enhancedContinuingRouteSerial(for: $0, ownerSerial: ownedSerial) }
            if phonePrivacyRoutes[id] != route {
                phonePrivacyRoutes[id] = route
                requestPhoneDisplayPrivacyUpdate(deviceID: id)
            }
        }
    }
#endif

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
            guard hasEnhancedTransport(deviceID: deviceID),
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
        guard terminationAdmission.admitsWork, featureEnabled(.recording, deviceID: deviceID), primaryScreenDemand.hasViewer(deviceID),
              !recordingDeviceIDs.contains(deviceID),
              let device = row(id: deviceID), device.isReady, hasEnhancedTransport(deviceID: deviceID),
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
        guard featureEnabled(.recording, deviceID: deviceID), featureEnabled(.screen, deviceID: deviceID), let recordingDevice = row(id: deviceID) else { return }
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
              featureEnabled(.recording, deviceID: deviceID), featureEnabled(.screen, deviceID: deviceID),
              row(id: deviceID) == recordingDevice,
              !recordingDeviceIDs.contains(deviceID) else { return }
        guard let sourceID = recordingVideoSources[deviceID] else { return }
        let audioConfiguration = featureEnabled(.audio, deviceID: deviceID) ? recordingAudioSources[deviceID]?.values.first(where: { $0.id == sourceID })?.configuration : nil
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
        guard terminationAdmission.admitsWork, featureEnabled(.audio, deviceID: deviceID) else { return }
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

    func companionIsConnected(deviceID: String) -> Bool {
        guard let id = companionID(for: deviceID), companionClients[id] != nil else { return false }
        return companionStates[id] == .connected
    }

    private func recordCompanionConnectionError(_ message: String, peerID: String?) {
        if let peerID { companionConnectionErrors["device:" + peerID] = message }
        else { lastError = message }
    }

    func notifications(for deviceID: String) -> [BridgeNotificationRow] {
        guard featureEnabled(.notifications, deviceID: deviceID) else { return [] }
        let muted = mutedPackages(for: deviceID)
        var rows = notificationsByDevice[deviceID, default: []]
        let liveIDs = Set(rows.map(\.id))
        // A phone may remove its notification before its result reaches us. Keep an
        // unresolved draft accessible rather than losing it with the disappearing card.
        for (identity, row) in notificationActionSavedRows where identity.deviceID == deviceID && !liveIDs.contains(row.id) {
            if !notificationActions.entry(identity).draft.isEmpty && !rows.contains(where: { $0.id == row.id }) { rows.append(row) }
        }
        return rows.sorted(by: BridgeNotificationRow.newestFirst).filter { !muted.contains($0.packageName) }
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

    func canSendNotificationAction(deviceID: String) -> Bool {
        featureEnabled(.notifications, deviceID: deviceID) && companionControl(for: deviceID) != nil
    }

    func notificationActionEntry(deviceID: String, notificationID: String, actionID: String, composeID: String = "") -> NotificationActionEntry {
        notificationActions.entry(.init(deviceID: deviceID, notificationID: notificationID, actionID: actionID, composeID: composeID))
    }

    func notificationComposeIDs(deviceID: String, notificationID: String, actionID: String) -> [String] {
        let native = notificationActions.entries.filter {
            $0.key.deviceID == deviceID && $0.key.notificationID == notificationID && $0.key.actionID == actionID &&
                !$0.key.composeID.isEmpty && (!$0.value.draft.isEmpty || $0.value.phase == .pending)
        }.keys.map(\.composeID).sorted()
        return [""] + native
    }

    func notificationSavedReplyActionIDs(deviceID: String, notificationID: String) -> [String] {
        Set(notificationActions.entries.filter {
            $0.key.deviceID == deviceID && $0.key.notificationID == notificationID && !$0.value.draft.isEmpty
        }.keys.map(\.actionID)).sorted()
    }

    func notificationActionIsPending(deviceID: String, notificationID: String) -> Bool {
        notificationActions.pending.values.contains { $0.identity.deviceID == deviceID && $0.identity.notificationID == notificationID }
    }

    func notificationActionHasRemovedDraft(deviceID: String, notificationID: String, actionID: String, composeID: String = "") -> Bool {
        let identity = NotificationActionIdentity(deviceID: deviceID, notificationID: notificationID, actionID: actionID, composeID: composeID)
        return notificationActions.isOrphan(identity) && !notificationActions.entry(identity).draft.isEmpty
    }

    func setNotificationReply(_ text: String, deviceID: String, notificationID: String, actionID: String, composeID: String = "") {
        let identity = NotificationActionIdentity(deviceID: deviceID, notificationID: notificationID, actionID: actionID, composeID: composeID)
        if !notificationActions.setDraft(text, for: identity) { lastError = String(localized: "NOTIFICATION_ACTION_BUSY") }
        if !text.isEmpty, notificationActions.entries[identity] != nil,
           let row = notificationsByDevice[deviceID]?.first(where: { $0.id == notificationID }) {
            notificationActionSavedRows[identity] = row
        }
        if text.isEmpty && notificationActions.entry(identity).phase != .pending { notificationActionSavedRows.removeValue(forKey: identity) }
        maintainNotificationActions()
    }

    private func maintainNotificationActions() {
        notificationActions.expireOrphans(now: ProcessInfo.processInfo.systemUptime)
        notificationActionSavedRows = notificationActionSavedRows.filter {
            notificationActions.entries[$0.key] != nil && !notificationActions.entry($0.key).draft.isEmpty
        }
        for id in Array(notificationActionTimeouts.keys) where notificationActions.pending[id] == nil {
            notificationActionTimeouts.removeValue(forKey: id)?.cancel()
        }
        notificationActionCleanup?.cancel()
        notificationActionCleanup = nil
        if let deadline = notificationActions.nextOrphanDeadline {
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            notificationActionCleanup = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.maintainNotificationActions()
            }
        }
    }

    private func retireNotificationActions(companionID: String, generation: UInt64) {
        let ids = notificationActions.disconnect(companionID: companionID, generation: generation)
        ids.forEach { notificationActionTimeouts.removeValue(forKey: $0)?.cancel() }
        maintainNotificationActions()
    }

    @discardableResult
    func performNotificationAction(
        deviceID: String,
        notificationID: String,
        actionID: String,
        reply: String? = nil,
        dismiss: Bool = false,
        composeID: String = "",
        replyPackageName: String? = nil,
        replyAppLabel: String? = nil
    ) -> Bool {
        guard featureEnabled(.notifications, deviceID: deviceID) else { return false }
        let identity = NotificationActionIdentity(deviceID: deviceID, notificationID: notificationID, actionID: actionID, composeID: composeID)
        // Native Notification Center replies enter here without a preceding binding write.
        // Admit their independent draft before any route/generation/pending guard can reject it.
        if let reply {
            guard notificationActions.setDraft(reply, for: identity) else {
                lastError = String(localized: "NOTIFICATION_ACTION_BUSY")
                return false
            }
            if let row = notificationsByDevice[deviceID]?.first(where: { $0.id == notificationID }) {
                notificationActionSavedRows[identity] = row
            } else if notificationActionSavedRows[identity] == nil {
                notificationActionSavedRows[identity] = BridgeNotificationRow(
                    id: notificationID, packageName: replyPackageName ?? "",
                    appLabel: replyAppLabel ?? String(localized: "NOTIFICATIONS"), title: "", body: "",
                    postedAt: Date(), actions: [.init(id: actionID, title: String(localized: "REPLY"), acceptsText: true)],
                    appIconPNG: nil
                )
            }
            maintainNotificationActions()
        }
        guard let control = companionControl(for: deviceID), let companionID = companionID(for: deviceID),
              let generation = companionRecoverySupervisor.currentGeneration(companionID: companionID) else {
            if notificationActions.entries[identity] != nil && notificationActions.entry(identity).phase != .pending {
                notificationActions.localFailure(identity: identity)
            }
            lastError = String(localized: "PHONE_CONNECTION_HINT")
            return false
        }
        var action = GBNotificationAction()
        action.notificationID = notificationID
        action.actionID = actionID
        action.replyText = reply ?? ""
        action.dismiss = dismiss
        let requestID = UUID().uuidString.lowercased()
        let supportsResults = control.supportsNotificationActionResults
        guard notificationActions.begin(identity: identity, companionID: companionID, generation: generation,
            requestID: requestID, draft: reply ?? "", supportsResults: supportsResults) != nil else {
            if notificationActions.entries[identity] != nil && notificationActions.entry(identity).phase != .pending {
                notificationActions.localFailure(identity: identity)
            }
            lastError = String(localized: "NOTIFICATION_ACTION_BUSY")
            return false
        }
        if let row = notificationsByDevice[deviceID]?.first(where: { $0.id == notificationID }), reply != nil {
            notificationActionSavedRows[identity] = row
        }
        maintainNotificationActions()
        // Legacy peers cannot acknowledge. Preserve their draft and explicitly show that state.
        action.requestID = supportsResults ? requestID : ""
        do {
            try control.sendNotificationAction(action)
            if supportsResults {
                notificationActionTimeouts[requestID] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self else { return }
                    _ = self.notificationActions.fail(requestID: requestID, unknown: true)
                    self.notificationActionTimeouts.removeValue(forKey: requestID)
                    self.maintainNotificationActions()
                }
            }
            return true
        } catch {
            _ = notificationActions.fail(requestID: requestID, unknown: false)
            notificationActions.localFailure(identity: identity)
            maintainNotificationActions()
            lastError = error.localizedDescription
            return false
        }
    }

#if !GALAXYBRIDGE_APP_STORE
    var hasIncomingDownloadsSelection: Bool { incomingDownloadsAccess.hasSelection }

    func authorizeIncomingDownloads() {
        guard terminationAdmission.admitsWork else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        panel.message = String(localized: "FILES_RECEIVE_AUTHORIZE_HINT")
        guard panel.runModal() == .OK, let url = panel.url, terminationAdmission.admitsWork else { return }
        do {
            objectWillChange.send()
            try incomingDownloadsAccess.grant(url)
            lastError = nil
        } catch {
            lastError = String(localized: "FILES_RECEIVE_AUTHORIZE_HINT")
        }
    }
#endif

    func sendFile(deviceID: String, url: URL) {
        guard terminationAdmission.admitsWork, featureEnabled(.files, deviceID: deviceID) else { return }
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



    func canStartCamera(deviceID: String) -> Bool {
        featureEnabled(.camera, deviceID: deviceID) && companionControl(for: deviceID) != nil && companionCameraSessions[deviceID] != nil
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
        if enabled && !featureEnabled(.camera, deviceID: deviceID) { return Task {} }
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
        let enhancedReady = hasEnhancedTransport(deviceID: deviceID)
#endif
        let effective = EffectiveDeviceCapabilities.resolve(
            companionAvailable: availableCapabilitiesByDevice[deviceID, default: []],
            companionUnavailable: capabilityReasonsByDevice[deviceID, default: [:]],
            hasEnhancedTransport: enhancedReady
        )
        let featureCodes: [ClientSetupFeature: Set<String>] = [
            .screen: ["CAPABILITY_SCREEN_CAPTURE", "CAPABILITY_INPUT_INJECTION"],
            .applications: ["CAPABILITY_VIRTUAL_DISPLAY"], .audio: ["CAPABILITY_AUDIO_FORWARDING"],
            .clipboard: ["CAPABILITY_CLIPBOARD_READ", "CAPABILITY_CLIPBOARD_WRITE"], .files: ["CAPABILITY_FILES"],
            .notifications: ["CAPABILITY_NOTIFICATIONS"], .camera: ["CAPABILITY_CAMERA_STREAM"],
            .calls: ["CAPABILITY_CALLS"], .recording: ["CAPABILITY_RECORDING"], .internet: ["CAPABILITY_INTERNET_GATEWAY"],
        ]
        let blocked = featureCodes.filter { !featureEnabled($0.key, deviceID: deviceID) }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var unavailable = effective.unavailableReasons
        for code in blocked { unavailable[code] = "feature_disabled" }
        return EffectiveDeviceCapabilities(available: effective.available.subtracting(blocked), unavailableReasons: unavailable)
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
        guard featureEnabled(.calls, deviceID: deviceID), let control = companionControl(for: deviceID) else { return }
        var call = GBCallEvent()
        call.callID = callID
        call.address = address
        call.state = state
        do { try control.sendCall(call) } catch { lastError = error.localizedDescription }
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
        for record in cachedNotifications {
            guard notificationSnapshotReconciliation.shouldRestore(deviceID: deviceID, notificationID: record.itemID) else {
                cacheMaintenance.remove(.init(deviceID: deviceID, namespace: .notifications, itemID: record.itemID))
                continue
            }
            guard !liveNotificationIDs.contains(record.itemID),
                  cacheMaintenance.shouldRestore(.init(deviceID: deviceID, namespace: .notifications, itemID: record.itemID)) else { continue }
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
        notificationRows.sort(by: BridgeNotificationRow.newestFirst)
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
        clipboardVerifiedADBIdentities.removeAll(keepingCapacity: true)
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
            if hasPersistentlyVerifiedBinding, let serial, let persistedPeer {
                clipboardVerifiedADBIdentities[serial] = ClipboardPeerIdentity.fingerprint(publicKey: persistedPeer.identityPublicKey,
                    tlsFingerprint: persistedPeer.tlsCertificateSHA256)
            }
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
        devices = DeviceRowMerger.restoringSavedPeers(
            peers.map { (deviceID: $0.deviceID, name: $0.displayName) },
            reachableRows: rowsByID
        ).sorted { left, right in
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
        reconcileCaptureRouteHandoffs()
        reconcileEnhancedClipboardSessions()
        reconcileEnhancedPrimaryRoutes()
        reconcilePhoneDisplayPrivacyRoutes()
        reconcileShellCapabilities()
#endif
        revalidateClipboardTrust(for: peers)
    }

#if !GALAXYBRIDGE_APP_STORE
    private func capturedRouteSerials(deviceID: String) -> Set<String> {
        var serials = applicationWindowCoordinator?.captureSerials(deviceID: deviceID) ?? []
        if let session = scrcpySessions[deviceID] { serials.insert(session.serial) }
        for (permit, session) in unsettledEnhancedRetirements where enhancedRetirementDeviceIDs[permit] == deviceID {
            serials.insert(session.serial)
        }
        return serials
    }

    private func handoffHelperID(for device: DeviceRow, serials: Set<String>) -> String? {
        guard let provider = availableShellProvider(deviceID: device.id), let control = companionControl(for: device.id) else { return nil }
        if device.adbSerial == nil, serials.contains(where: { !$0.hasPrefix("shell:") }),
           !control.supportsCaptureRetirementProof || provider.needsRuntimeUpgrade { return nil }
        return control.peer.deviceID
    }

    private func captureHandoffPlan(for device: DeviceRow) -> CaptureRouteHandoffPlan? {
        let serials = capturedRouteSerials(deviceID: device.id)
        let pendingPrimary = enhancedRetirements.keys.contains { enhancedRetirementDeviceIDs[$0] == device.id }
            || unsettledEnhancedRetirements.keys.contains { enhancedRetirementDeviceIDs[$0] == device.id }
        let generationChanged = ADBOwnedRuntime.shared.activeGeneration.map { current in
            scrcpySessions[device.id]?.capturedADBGeneration.map { $0 != current } == true
                || unsettledEnhancedRetirements.contains { permit, session in
                    enhancedRetirementDeviceIDs[permit] == device.id
                        && session.capturedADBGeneration.map { $0 != current } == true
                }
                || applicationWindowCoordinator?.hasStaleADBGeneration(deviceID: device.id, currentGeneration: current) == true
        } ?? false
        return CaptureRouteHandoffPlan.resolve(deviceReady: device.isReady, adbSerial: device.adbSerial,
            helperDeviceID: handoffHelperID(for: device, serials: serials), capturedSerials: serials,
            retirementsPending: pendingPrimary || applicationWindowCoordinator?.hasRetiringOwners(deviceID: device.id) == true,
            windowsPending: captureRouteTransitionDevices.contains(device.id) || !(captureRoutePendingWindows[device.id] ?? []).isEmpty,
            generationChanged: generationChanged)
    }

    private func validateCaptureHandoff(deviceID: String, ticket: UUID, peerKey: Data) throws {
        try Task.checkCancellation()
        guard terminationAdmission.admitsWork, captureRouteHandoffTickets[deviceID] == ticket,
              let peers = try? PairedPeerStore().peers(),
              peers.contains(where: { "device:\($0.deviceID)" == deviceID && $0.identityPublicKey == peerKey }) else {
            throw CancellationError()
        }
    }

    private func settlePrimaryCaptureRetirements(deviceID: String) async -> Bool {
        for (permit, work) in Array(enhancedRetirements) where enhancedRetirementDeviceIDs[permit] == deviceID { await work.value }
        for (permit, session) in Array(unsettledEnhancedRetirements) where enhancedRetirementDeviceIDs[permit] == deviceID {
            if let route = verifiedEnhancedRetirementRoute(deviceID: deviceID, captureSerial: session.serial) {
                session.installVerifiedCleanupRoute(route)
            } else { session.retryOwnedCleanup() }
            await session.waitForScheduledCleanup()
        }
        releasePhysicallySettledEnhancedRetirements()
        return !enhancedRetirements.keys.contains { enhancedRetirementDeviceIDs[$0] == deviceID }
            && !unsettledEnhancedRetirements.keys.contains { enhancedRetirementDeviceIDs[$0] == deviceID }
    }

    private func scheduleCaptureRouteRetry(deviceID: String) {
        guard terminationAdmission.admitsWork, captureRouteRetryTasks[deviceID] == nil else { return }
        var backoff = captureRouteBackoffs[deviceID] ?? ReconnectBackoff()
        let delay = backoff.nextDelay(); captureRouteBackoffs[deviceID] = backoff
        let ticket = UUID(); captureRouteRetryTickets[deviceID] = ticket
        captureRouteRetryTasks[deviceID] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.captureRouteRetryTickets[deviceID] == ticket else { return }
            self.captureRouteRetryTasks.removeValue(forKey: deviceID)
            self.captureRouteRetryTickets.removeValue(forKey: deviceID)
            if self.terminationAdmission.admitsWork { self.reconcileCaptureRouteHandoffs() }
        }
    }

    private func reconcileCaptureRouteHandoffs() {
        guard terminationAdmission.admitsWork, let peers = try? PairedPeerStore().peers() else { return }
        for device in devices where device.isReady {
            let id = device.id
            guard let peer = peers.first(where: { "device:\($0.deviceID)" == id }) else { continue }
            if let oldKey = captureRoutePeerKeys[id], oldKey != peer.identityPublicKey {
                captureRouteHandoffTasks.removeValue(forKey: id)?.cancel(); captureRouteHandoffTickets.removeValue(forKey: id)
                captureRouteRetryTasks.removeValue(forKey: id)?.cancel(); captureRouteRetryTickets.removeValue(forKey: id)
                captureRoutePendingWindows.removeValue(forKey: id); captureRouteTransitionDevices.remove(id)
                captureRouteBackoffs.removeValue(forKey: id); captureRouteAttemptSignatures.removeValue(forKey: id)
                captureRoutePeerKeys.removeValue(forKey: id); preparingDirectDevices.remove(id)
            }
            guard captureRouteHandoffTasks[id] == nil, nearbyPreparationTasks[id] == nil,
                  !preparingDirectDevices.contains(id),
                  !shellReadinessTasks.values.contains(where: { $0.deviceID == id }),
                  let plan = captureHandoffPlan(for: device) else { continue }
            let signature = [device.adbSerial ?? "", plan.destinationSerial, shellProviders[id]?.bootGeneration ?? "",
                companionControl(for: id)?.authenticatedSessionID ?? "", ADBOwnedRuntime.shared.activeGeneration?.uuidString ?? ""].joined(separator: "|")
            if captureRouteRetryTasks[id] != nil {
                guard captureRouteAttemptSignatures[id] != signature else { continue }
                captureRouteRetryTasks.removeValue(forKey: id)?.cancel(); captureRouteRetryTickets.removeValue(forKey: id)
                captureRouteBackoffs.removeValue(forKey: id)
            }
            captureRouteAttemptSignatures[id] = signature; captureRoutePeerKeys[id] = peer.identityPublicKey
            let transition = plan.requiresMigration || captureRouteTransitionDevices.contains(id)
                || !(captureRoutePendingWindows[id] ?? []).isEmpty
            if transition { captureRouteTransitionDevices.insert(id); preparingDirectDevices.insert(id) }
            let ticket = UUID(); captureRouteHandoffTickets[id] = ticket
            captureRouteHandoffTasks[id] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.captureRouteHandoffTickets[id] == ticket {
                        self.captureRouteHandoffTasks.removeValue(forKey: id); self.captureRouteHandoffTickets.removeValue(forKey: id)
                        self.preparingDirectDevices.remove(id)
                        if !self.primaryScreenDemand.hasDemand(id), (self.captureRoutePendingWindows[id] ?? []).isEmpty,
                           self.applicationWindowCoordinator?.captureSerials(deviceID: id).isEmpty != false {
                            self.phonePrivacyManualPower.removeValue(forKey: id)
                        }
                        self.objectWillChange.send()
                        self.reconcileEnhancedClipboardSessions(); self.reconcilePhoneDisplayPrivacyRoutes()
                    }
                }
                do {
                    try self.validateCaptureHandoff(deviceID: id, ticket: ticket, peerKey: peer.identityPublicKey)
                    for serial in self.applicationWindowCoordinator?.captureSerials(deviceID: id) ?? [] {
                        if let route = self.verifiedEnhancedRetirementRoute(deviceID: id, captureSerial: serial) {
                            self.applicationWindowCoordinator?.installRetirementRoute(route, deviceID: id)
                        }
                    }
                    if transition {
                        let suspension = await self.applicationWindowCoordinator?.suspendForRouteChange(deviceID: id)
                        try self.validateCaptureHandoff(deviceID: id, ticket: ticket, peerKey: peer.identityPublicKey)
                        var saved: [String: ApplicationWindowCoordinator.RouteResume] = [:]
                        for window in (self.captureRoutePendingWindows[id] ?? []) + (suspension?.windows ?? []) {
                            saved[window.application.packageName] = window
                        }
                        self.captureRoutePendingWindows[id] = saved.values.sorted { $0.application.packageName < $1.application.packageName }
                        guard suspension?.settled != false else { throw ShellCapabilityBridgeFailure.operationFailed }
                        self.retireEnhancedScreenSession(deviceID: id)
                    }
                    let appsSettled = await self.applicationWindowCoordinator?.retryRetiringOwners(deviceID: id) ?? true
                    let primarySettled = await self.settlePrimaryCaptureRetirements(deviceID: id)
                    try self.validateCaptureHandoff(deviceID: id, ticket: ticket, peerKey: peer.identityPublicKey)
                    guard appsSettled && primarySettled else { throw ShellCapabilityBridgeFailure.operationFailed }
                    guard let current = self.row(id: id), current.isReady else { throw ShellCapabilityBridgeFailure.unavailable }
                    if transition {
                        if let clipboard = self.clipboardSessions.removeValue(forKey: id) { await clipboard.stopAndWait() }
                        self.clipboardReconnectTasks.removeValue(forKey: id)?.cancel()
                        self.clipboardReconnectAttempts.removeValue(forKey: id)
                        try self.validateCaptureHandoff(deviceID: id, ticket: ticket, peerKey: peer.identityPublicKey)
                        guard let powerDevice = self.row(id: id), powerDevice.isReady else { throw ShellCapabilityBridgeFailure.unavailable }
                        let serials = self.capturedRouteSerials(deviceID: id)
                        guard let destination = CaptureRouteHandoffPlan.destination(adbSerial: powerDevice.adbSerial,
                            helperDeviceID: self.handoffHelperID(for: powerDevice, serials: serials), capturedSerials: serials) else {
                            throw ShellCapabilityBridgeFailure.unavailable
                        }
                        self.phoneDisplayPrivacy.setEnabled(false, deviceID: id, serial: destination)
                        await self.phoneDisplayPrivacy.waitForSettlement(deviceID: id)
                        try self.validateCaptureHandoff(deviceID: id, ticket: ticket, peerKey: peer.identityPublicKey)
                        if case .failed = self.phoneDisplayPrivacy.status(deviceID: id) { throw ShellCapabilityBridgeFailure.operationFailed }
                        guard let latest = self.row(id: id), latest.isReady else { throw ShellCapabilityBridgeFailure.unavailable }
                        if latest.adbSerial == nil, let control = self.companionControl(for: id), control.supportsFeatureConfiguration,
                           self.clientSetup.synchronization(deviceID: id) != .acknowledged { return }
                        self.captureRouteTransitionDevices.remove(id); self.preparingDirectDevices.remove(id)
                        self.ensureEnhancedSessionForPrimaryDemand(for: latest)
                        let windows = self.captureRoutePendingWindows.removeValue(forKey: id) ?? []
                        self.applicationWindowCoordinator?.resumeAfterRouteChange(windows, device: latest, model: self, activate: false)
                    } else { self.ensureEnhancedSessionForPrimaryDemand(for: current) }
                    self.captureRouteBackoffs.removeValue(forKey: id); self.captureRouteAttemptSignatures.removeValue(forKey: id)
                    self.captureRoutePeerKeys.removeValue(forKey: id)
                    if self.selectedDeviceID == id, self.lastError == String(localized: "ERROR_MEDIA_CLEANUP") { self.lastError = nil }
                } catch is CancellationError {
                    // Revocation/termination owns cancellation and forbids any late resume.
                } catch {
                    if self.captureRouteHandoffTickets[id] == ticket {
                        if self.selectedDeviceID == id { self.lastError = String(localized: "ERROR_MEDIA_CLEANUP") }
                        self.scheduleCaptureRouteRetry(deviceID: id)
                    }
                }
            }
            objectWillChange.send()
        }
    }

    private func captureRetirementIdentity(deviceID: String, captureSerial: String) -> VerifiedCaptureRetirementPeer? {
        let store = ADBBindingStore()
        guard !captureSerial.hasPrefix("shell:"), let binding = try? store.record(for: captureSerial),
              let peers = try? PairedPeerStore().peers(),
              let peer = peers.first(where: { "device:\($0.deviceID)" == deviceID }) else { return nil }
        return VerifiedCaptureRetirementPeer(logicalDeviceID: deviceID, bindingDeviceID: binding.deviceID,
            publicKeySHA256: binding.identityPublicKeySHA256, bindingVerified: store.isVerified(serial: captureSerial, peer: peer))
    }

    private func retirementProvider(for identity: VerifiedCaptureRetirementPeer) -> ShellCapabilityBridgeProvider? {
        guard let provider = shellProviders[identity.logicalDeviceID], provider.available, provider.bootGeneration != nil,
              let control = companionControl(for: identity.logicalDeviceID), control.supportsShellBridge,
              identity.accepts(deviceID: control.peer.deviceID,
                  publicKeySHA256: Data(SHA256.hash(data: control.peer.identityPublicKey)),
                  authenticated: companionStates[companionID(for: identity.logicalDeviceID) ?? ""] == .connected)
        else { return nil }
        return provider
    }

    private func captureRetirementAuthority(deviceID: String, captureSerial: String) -> CaptureRetirementAuthority {
        let peer = captureRetirementIdentity(deviceID: deviceID, captureSerial: captureSerial)
        let generation = ADBOwnedRuntime.shared.activeGeneration
        if let existing = captureRetirementAuthorities[captureSerial] {
            if let frozen = existing.peer, let peer, frozen.deviceID == peer.deviceID,
               frozen.publicKeySHA256 == peer.publicKeySHA256 { return existing }
            if existing.peer == nil, let generation, existing.captureGeneration == generation { return existing }
        }
        let authority = CaptureRetirementAuthority(captureSerial: captureSerial, peer: peer, generation: generation)
        captureRetirementAuthorities[captureSerial] = authority
        return authority
    }

    private func adoptCaptureRetirementIdentity(_ record: ADBBindingRecord) {
        // Called only after the binder accepted this session's signed nonce.
        guard adbRows.contains(where: { $0.isReady && $0.adbSerial == record.adbSerial }),
              let peer = captureRetirementIdentity(deviceID: "device:" + record.deviceID, captureSerial: record.adbSerial),
              let control = companionControl(for: peer.logicalDeviceID),
              peer.accepts(deviceID: control.peer.deviceID, publicKeySHA256: Data(SHA256.hash(data: control.peer.identityPublicKey)),
                authenticated: companionStates[companionID(for: peer.logicalDeviceID) ?? ""] == .connected)
        else { return }
        captureRetirementAuthorities[record.adbSerial]?.adopt(peer, currentADBSerial: record.adbSerial, generation: ADBOwnedRuntime.shared.activeGeneration)
    }

    func captureRetirementAbsenceProof(deviceID: String, captureSerial: String) -> EnhancedCaptureAbsenceProof? {
        let authority = captureRetirementAuthority(deviceID: deviceID, captureSerial: captureSerial)
        return { [weak self, authority] scid in
            guard let identity = authority.peer, let provider = self?.retirementProvider(for: identity) else { throw ShellCapabilityBridgeFailure.sessionChanged }
            try await provider.confirmADBCaptureAbsent(scid: scid)
        }
    }

    private func displayControllerRetirementProof(deviceID: String, captureSerial: String) -> DisplayControllerRetirementProof? {
        let authority = captureRetirementAuthority(deviceID: deviceID, captureSerial: captureSerial)
        return { [weak self, authority] process, initial in
            guard let identity = authority.peer, let provider = self?.retirementProvider(for: identity) else { throw ShellCapabilityBridgeFailure.sessionChanged }
            try await provider.confirmDisplayControllerRetired(identity: process, initial: initial)
        }
    }

    private func displayControllerResourceRelease(deviceID: String, captureSerial: String) -> DisplayControllerResourceRelease? {
        let authority = captureRetirementAuthority(deviceID: deviceID, captureSerial: captureSerial)
        return { [weak self, authority] process, resourceID in
            guard let identity = authority.peer, let provider = self?.retirementProvider(for: identity) else { throw ShellCapabilityBridgeFailure.sessionChanged }
            try await provider.releaseRetiredControllerResource(identity: process, resourceID: resourceID)
        }
    }

    private func verifiedEnhancedRetirementRoute(deviceID: String, captureSerial: String) -> VerifiedEnhancedRetirementRoute? {
        guard let device = row(id: deviceID), device.isReady, device.transport != .companionLAN,
              let serial = device.adbSerial,
              device.transport != .wirelessADB || validatedWirelessSerials.contains(serial),
              let capture = try? ADBBindingStore().record(for: captureSerial),
              let destination = try? ADBBindingStore().record(for: serial),
              let peers = try? PairedPeerStore().peers(),
              let peer = peers.first(where: { "device:\($0.deviceID)" == deviceID }),
              ADBBindingStore().isVerified(serial: captureSerial, peer: peer),
              ADBBindingStore().isVerified(serial: serial, peer: peer) else { return nil }
        return VerifiedEnhancedRetirementRoute(logicalDeviceID: deviceID, captureSerial: captureSerial,
            routeSerial: serial, captureBindingDeviceID: capture.deviceID, routeBindingDeviceID: destination.deviceID,
            captureIdentity: capture.identityPublicKeySHA256, routeIdentity: destination.identityPublicKeySHA256,
            routeCurrentlyVerified: true)
    }

    private func reconcileEnhancedPrimaryRoutes() {
        guard terminationAdmission.admitsWork else { return }
        releasePhysicallySettledEnhancedRetirements()
        for (permit, session) in Array(unsettledEnhancedRetirements) where enhancedRetirements[permit] == nil {
            guard let deviceID = enhancedRetirementDeviceIDs[permit], let device = row(id: deviceID), device.isReady else { continue }
            if let route = verifiedEnhancedRetirementRoute(deviceID: deviceID, captureSerial: session.serial) {
                session.installVerifiedCleanupRoute(route)
            } else if device.adbSerial == session.serial {
                session.retryOwnedCleanup()
            } else if session.serial.hasPrefix("shell:"), let provider = availableShellProvider(deviceID: deviceID),
                      provider === shellProviderForOwner(session.serial) {
                session.retryOwnedCleanup()
            } else { continue }
            enhancedRetirements[permit] = Task { [weak self] in
                await session.waitForScheduledCleanup()
                guard let self else { return }
                self.enhancedRetirements.removeValue(forKey: permit)
                guard session.cleanupPhysicallySettled else { return }
                self.unsettledEnhancedRetirements.removeValue(forKey: permit)
                self.enhancedRetirementDeviceIDs.removeValue(forKey: permit)
                guard let canonicalID = self.primaryScreenDemand.finishRetirement(permit),
                      self.terminationAdmission.admitsWork, let current = self.row(id: canonicalID) else { return }
                self.ensureEnhancedSession(for: current)
            }
        }
        for device in devices where primaryScreenDemand.hasDemand(device.id) {
            ensureEnhancedSession(for: device)
        }
    }

    /// Keeps one low-bandwidth control-only clipboard channel per reachable ADB
    /// phone. Its lifetime follows device connectivity, never a mirror window.
    private func reconcileEnhancedClipboardSessions() {
        guard terminationAdmission.admitsWork else { return }
        let desired = Dictionary(
            uniqueKeysWithValues: devices.compactMap { device -> (String, String)? in
                guard featureEnabled(.clipboard, deviceID: device.id),
                      let serial = enhancedContinuingRouteSerial(for: device, ownerSerial: clipboardSessions[device.id]?.serial)
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
        guard terminationAdmission.admitsWork, featureEnabled(.clipboard, deviceID: deviceID),
              shellRuntimeUpgradeTickets[deviceID] == nil, clipboardSessions[deviceID] == nil,
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
                self.cacheMaintenance.reevaluateClipboardRoutes(deviceID: deviceID)
                self.revalidateClipboardTrust(for: self.companionConnectionBootstrap?.peers(merging: []) ?? [])
            },
            failureHandler: { [weak self] failedSerial in
                self?.handleEnhancedClipboardFailure(deviceID: deviceID, serial: failedSerial)
            }, shellProvider: serial.hasPrefix("shell:") ? shellProviders[deviceID] : nil
        )
        session.clipboardEventHandler = { [weak self, weak session] update in
            guard let self, let session, self.clipboardSessions[deviceID] === session else { return }
            self.acceptRemoteClipboard(deviceID: deviceID, changeID: update.changeID,
                kind: update.kind == .png ? .png : .text, content: update.content, sensitive: false,
                sourceRouteID: "clipboard:" + session.clipboardTrustGeneration.uuidString)
        }
        clipboardSessions[deviceID] = session
        session.clipboardUnavailableHandler = { [weak self, weak session] in
            guard let self, let session, self.clipboardSessions[deviceID] === session else { return }
            self.clipboardHub.forgetClipboard(deviceID: deviceID)
        }
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
                  self.enhancedCaptureRoute(for: device)?.serial == serial
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
                + ":adb:" + (observedADBGeneration?.uuidString ?? "unowned")
            desired["device:" + peer.deviceID] = (scope, serial)
        }
        companionTunnelDesired = desired
        for (deviceID, lease) in companionTunnelLeases
        where desired[deviceID]?.scope != lease.peerID || desired[deviceID]?.serial != lease.serial {
            companionTunnelLeases.removeValue(forKey: deviceID)
            retireCompanionTunnelRoute(deviceID: deviceID)
            let token = UUID()
            companionTunnelTokens[deviceID] = token
            companionTunnelTasks[deviceID] = Task { [weak self, companionTunnels] in
                do { try await companionTunnels.release(lease) }
                catch { self?.fileTransferStatus[deviceID] = String(localized: "FILE_CONNECTION_LOST") }
                guard let self, self.companionTunnelTokens[deviceID] == token else { return }
                self.companionTunnelTasks.removeValue(forKey: deviceID)
                self.companionTunnelTokens.removeValue(forKey: deviceID)
                if self.terminationAdmission.admitsWork { self.mergeDevices() }
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
                        if self.terminationAdmission.admitsWork, self.companionTunnelLeases[deviceID] == nil,
                           let latest = self.companionTunnelDesired[deviceID],
                           latest.scope != target.scope || latest.serial != target.serial {
                            self.mergeDevices()
                        }
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
        // Bonjour discovery is only reachability metadata. Publishing an
        // unmatched advertisement here made every Helper on the LAN appear as
        // an already-added phone, including on a clean first launch. Build the
        // visible/connection candidate set exclusively from committed peers.
        guard CompanionDiscoveryPresentationPolicy.shouldPublish(hasCommittedPeer: !peers.isEmpty) else {
            return []
        }
        var candidates: [DiscoveredCompanion] = []
        for peer in peers {
#if !GALAXYBRIDGE_APP_STORE
            if let direct = nearbyDirectEndpoints[peer.deviceID] {
                let active = companionClients.first { $0.value.control.peer.deviceID == peer.deviceID }?.key
                if active == nil || active == direct.id {
                    candidates.append(direct)
                    continue
                }
            }
#endif
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
        featureEnabled(.screen, deviceID: deviceID) && mediaTransportDispatchGate(for: deviceID).shouldDispatch(
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
            resetFeatureConfigurationForSession(deviceID: deviceID)
            companionLifecycleLogger.info("connection bundle starting")
            if primaryMediaDiagnosticsEnabled {
                // Opt-in diagnostics correlate a logical session without
                // logging phone names, serials, addresses or key material.
                let peerToken = SHA256.hash(data: peer.identityPublicKey).prefix(8)
                    .map { String(format: "%02x", $0) }.joined()
                let route = companion.id.hasPrefix("usb-companion:") ? "usb_forward"
                    : companion.id.hasPrefix("routed:") ? "routed_lan" : "discovered"
                companionLifecycleLogger.info("connection target generation=\(generation, privacy: .public) peer_token=\(peerToken, privacy: .public) route=\(route, privacy: .public)")
            }
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
            audioPlayer.setPlaybackEnabled(featureEnabled(.audio, deviceID: deviceID) && primaryScreenDemand.hasViewer(deviceID))
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
            let makeVideo: @MainActor () -> CompanionTLSClient = { [weak self] in
                let channelToken = UUID()
                self?.featureMediaChannelTokens[deviceID, default: [:]][.screen] = channelToken
                return CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .video,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleFeatureMediaState(deviceID: deviceID, feature: .screen, channelToken: channelToken,
                            companionID: companion.id,
                            generation: generation,
                            channel: .video,
                            state: state
                        )
                    }
                },
                envelopeHandler: { _, _ in },
                mediaHandler: { [weak self, weak videoSession] packet in
                    guard mediaDispatchGate.shouldDispatch(
                        .companion,
                        isConfiguration: packet.flags.contains(.configuration)
                    ) else { return }
                    Task { @MainActor [weak self] in
                        guard self?.featureEnabled(.screen, deviceID: deviceID) == true, self?.featureMediaChannelTokens[deviceID]?[.screen] == channelToken else { return }
                        videoSession?.consume(packet)
                    }
                }
            )
            }
            let video = makeVideo()
            let makeAudio: @MainActor () -> CompanionTLSClient = { [weak self] in
                let channelToken = UUID()
                self?.featureMediaChannelTokens[deviceID, default: [:]][.audio] = channelToken
                return CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .audio,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleFeatureMediaState(deviceID: deviceID, feature: .audio, channelToken: channelToken,
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
                              self.companionAudioPlayers[deviceID] === audioPlayer, self.featureEnabled(.audio, deviceID: deviceID), self.featureMediaChannelTokens[deviceID]?[.audio] == channelToken else { return }
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
            }
            let audio = makeAudio()
            let makeCamera: @MainActor () -> CompanionTLSClient = { [weak self] in
                let channelToken = UUID()
                self?.featureMediaChannelTokens[deviceID, default: [:]][.camera] = channelToken
                return CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .camera,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleFeatureMediaState(deviceID: deviceID, feature: .camera, channelToken: channelToken,
                            companionID: companion.id,
                            generation: generation,
                            channel: .camera,
                            state: state
                        )
                    }
                },
                envelopeHandler: { _, _ in },
                mediaHandler: { [weak self, weak cameraSession] packet in
                    Task { @MainActor in
                        guard let self, self.featureEnabled(.camera, deviceID: deviceID), self.featureMediaChannelTokens[deviceID]?[.camera] == channelToken,
                              self.companionRecoverySupervisor.currentGeneration(companionID: companion.id) == generation else { return }
                        cameraSession?.consume(packet)
                    }
                }
            )
            }
            let camera = makeCamera()
            let fileIngress = CompanionFileIngressGate()
            let makeFiles: @MainActor () -> CompanionTLSClient = { [weak self] in
                let channelToken = UUID()
                self?.featureMediaChannelTokens[deviceID, default: [:]][.files] = channelToken
                return CompanionTLSClient(
                endpoint: companion.endpoint,
                peer: peer,
                hostID: hostID,
                sessionID: logicalSessionID,
                channelKind: .files,
                bundleGeneration: generation,
                diagnosticSink: diagnosticSink,
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleFeatureMediaState(deviceID: deviceID, feature: .files, channelToken: channelToken,
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
                                      self.companionRecoverySupervisor.currentGeneration(companionID: companion.id) == generation,
                                      self.featureMediaChannelTokens[deviceID]?[.files] == channelToken else { return }
                                self.companionClients[companion.id]?.files.cancel()
                            }
                        }
                        return
                    }
                    Task { @MainActor in
                        guard let self, self.featureMediaChannelTokens[deviceID]?[.files] == channelToken else { fileIngress.finish(bytes: cost); return }
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
            }
            let files = makeFiles()
            companionClients[companion.id] = CompanionConnections(
                control: control,
                events: events,
                video: video,
                audio: audio,
                camera: camera,
                files: files,
                mediaFactories: [.screen: makeVideo, .audio: makeAudio, .camera: makeCamera, .files: makeFiles]
            )
            armAudioVerificationIfPossible(deviceID: deviceID)
            control.start()
            events.start()
            // Policy-capable phones may still have these channels disabled durably.
            // Start media after their exact configuration receipt (legacy after negotiation).
        }
    }

    private func handleFeatureMediaState(deviceID: String, feature: ClientSetupFeature, channelToken: UUID,
        companionID: String, generation: CompanionLogicalSessionRecoverySupervisor.Generation,
        channel: GBChannelKind, state: CompanionConnectionState) {
        guard featureMediaChannelTokens[deviceID]?[feature] == channelToken,
              companionRecoverySupervisor.currentGeneration(companionID: companionID) == generation else { return }
        handleCompanionState(companionID: companionID, generation: generation, channel: channel, state: state)
    }

    private func handleCompanionState(
        companionID: String,
        generation: CompanionLogicalSessionRecoverySupervisor.Generation,
        channel: GBChannelKind,
        state: CompanionConnectionState
    ) {
        let peerID = companionClients[companionID]?.control.peer.deviceID
        if let peerID {
            let feature: ClientSetupFeature? = switch channel {
            case .video: .screen
            case .audio: .audio
            case .camera: .camera
            case .files: .files
            default: nil
            }
            if let feature, !featureEnabled(feature, deviceID: "device:" + peerID) { return }
        }
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
            if channel == .control {
                switch state {
                case .failed, .authenticationRejected, .disconnected:
                    retireNotificationActions(companionID: companionID, generation: generation)
                default: break
                }
            }
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
                if let peerID { companionConnectionErrors.removeValue(forKey: "device:" + peerID) }
                reconnectAttempts[companionID] = 0
                companionRecoverySupervisor.cancelDelayedRetry(companionID: companionID)
                reconcileADBBindings(for: companionID)
                mergeDevices()
            case let .failed(message):
                if let peerID {
                    notificationSnapshotReconciliation.abort(deviceID: "device:" + peerID)
                    cancelAudioVerification(deviceID: "device:" + peerID)
                    clientSetup.invalidate(deviceID: "device:" + peerID)
                    clientSetup.disconnectConfiguration(deviceID: "device:" + peerID)
                    featureConfigurationTimeouts.removeValue(forKey: "device:" + peerID)?.cancel()
                }
                companionStates[companionID] = state
                companionConnectingWatchdog.connectionSettled(companionID: companionID)
                if let peerID, companionAuthenticationBlockedPeerIDs.contains(peerID) {
                    recoveryAccepted = false
                    return
                }
                recordCompanionConnectionError(UserFacingText.formatted(
                    "COMPANION_CONNECTION_FAILED", message
                ), peerID: peerID)
                recoveryAccepted = recoverCompanionSession(
                    companionID: companionID,
                    generation: generation
                )
            case let .authenticationRejected(message):
                if let peerID {
                    notificationSnapshotReconciliation.abort(deviceID: "device:" + peerID)
                    cancelAudioVerification(deviceID: "device:" + peerID)
                    clientSetup.invalidate(deviceID: "device:" + peerID)
                    clientSetup.disconnectConfiguration(deviceID: "device:" + peerID)
                    featureConfigurationTimeouts.removeValue(forKey: "device:" + peerID)?.cancel()
                }
                companionStates[companionID] = state
                if let peerID { companionAuthenticationBlockedPeerIDs.insert(peerID) }
                companionConnectingWatchdog.connectionSettled(companionID: companionID)
                companionRecoverySupervisor.cancelDelayedRetry(companionID: companionID)
                reconnectAttempts[companionID] = 0
                recordCompanionConnectionError(message, peerID: peerID)
                recoveryAccepted = false
            case .disconnected:
                if let peerID {
                    notificationSnapshotReconciliation.abort(deviceID: "device:" + peerID)
                    cancelAudioVerification(deviceID: "device:" + peerID)
                    clientSetup.invalidate(deviceID: "device:" + peerID)
                    clientSetup.disconnectConfiguration(deviceID: "device:" + peerID)
                    featureConfigurationTimeouts.removeValue(forKey: "device:" + peerID)?.cancel()
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
        retireNotificationActions(companionID: companionID, generation: generation)
        retireCamera(companionID: companionID, generation: generation)
        let peerID = companionClients[companionID]?.control.peer.deviceID
#if !GALAXYBRIDGE_APP_STORE
        if let control = companionClients[companionID]?.control {
            shellProviders["device:" + control.peer.deviceID]?.disconnected(authenticatedSessionID: control.authenticatedSessionID)
            internetSharing.retire(deviceID: "device:\(control.peer.deviceID)", control: control)
        }
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
                    resetFeatureConfigurationForSession(deviceID: deviceID)
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
            if let current = self.row(id: deviceID), current.adbSerial != session.serial,
               let route = self.verifiedEnhancedRetirementRoute(deviceID: deviceID, captureSerial: session.serial) {
                session.installVerifiedCleanupRoute(route)
                self.retireEnhancedScreenSession(deviceID: deviceID)
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
        if hasEnhancedTransport(deviceID: deviceID) { return nil }
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
        guard featureEnabled(.files, deviceID: deviceID), let companionID = companionID(for: deviceID) else { return nil }
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
#if !GALAXYBRIDGE_APP_STORE
        // Termination closes all normal callback admission, but the bounded
        // exact pending STOP receipts must still retire shell owners before
        // their current TLS route and Nearby association are torn down.
        if terminationAdmission.isTerminating, case let .shellBridgeResult(result)? = envelope.payload,
           let control = companionClients[companionID]?.control {
            shellProviders[deviceID]?.receive(result, authenticatedSessionID: control.authenticatedSessionID)
            return
        }
        if terminationAdmission.isTerminating, case let .directLinkStatus(status)? = envelope.payload,
           let control = companionClients[companionID]?.control {
            receiveNearbyRelease(status, deviceID: deviceID, sessionID: control.authenticatedSessionID)
            return
        }
#endif
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
        case let .directLinkStatus(status):
#if !GALAXYBRIDGE_APP_STORE
            if let control = companionClients[companionID]?.control {
                receiveNearbyRelease(status, deviceID: deviceID, sessionID: control.authenticatedSessionID)
            }
#endif
        case let .shellBridgeResult(result):
#if !GALAXYBRIDGE_APP_STORE
            if let control = companionClients[companionID]?.control {
                shellProviders[deviceID]?.receive(result, authenticatedSessionID: control.authenticatedSessionID)
            }
#endif
        case let .internetSharingStatus(status):
#if !GALAXYBRIDGE_APP_STORE
            if let control = companionClients[companionID]?.control {
                internetSharing.receive(status, deviceID: deviceID, control: control)
            }
#endif
        case let .notificationActionResult(result):
            if notificationActions.resolve(requestID: result.requestID, notificationID: result.notificationID,
                actionID: result.actionID, companionID: companionID, generation: generation,
                accepted: result.accepted, errorCode: result.errorCode) {
                notificationActionTimeouts.removeValue(forKey: result.requestID)?.cancel()
                if !result.accepted { lastError = String(localized: "NOTIFICATION_ACTION_FAILED") }
                maintainNotificationActions()
            }
        case let .notificationSnapshot(snapshot):
            guard featureEnabled(.notifications, deviceID: deviceID) else { return }
            if !snapshot.complete {
                notificationSnapshotReconciliation.begin(deviceID: deviceID)
            } else if let stale = notificationSnapshotReconciliation.complete(
                deviceID: deviceID,
                knownIDs: Set(notificationsByDevice[deviceID, default: []].map(\.id))
            ) {
                notificationsByDevice[deviceID, default: []].removeAll { stale.contains($0.id) }
                for notificationID in stale {
                    macNotifications.remove(deviceID: deviceID, notificationID: notificationID)
                    cacheMaintenance.remove(.init(deviceID: deviceID, namespace: .notifications, itemID: notificationID))
                }
                if let active = notificationSnapshotReconciliation.activeIDs(deviceID: deviceID) {
                    macNotifications.reconcile(deviceID: deviceID, activeNotificationIDs: active)
                    notificationActions.reconcile(deviceID: deviceID, activeNotificationIDs: active,
                        now: ProcessInfo.processInfo.systemUptime)
                    maintainNotificationActions()
                }
            }
        case let .notificationEvent(event):
            guard featureEnabled(.notifications, deviceID: deviceID) else { return }
            notificationActions.observe(deviceID: deviceID, notificationID: event.notificationID,
                removed: event.removed, now: ProcessInfo.processInfo.systemUptime)
            maintainNotificationActions()
            notificationSnapshotReconciliation.observe(
                deviceID: deviceID, notificationID: event.notificationID, removed: event.removed
            )
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
                rows.sort(by: BridgeNotificationRow.newestFirst)
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
                                      self.companionRecoverySupervisor.currentGeneration(companionID: companionID) == generation,
                                      self.featureEnabled(.notifications, deviceID: deviceID) else { return }
                                self.clientSetup.recordEvidence(deviceID: deviceID, feature: .notifications, attemptID: notificationAttempt)
                            }
                        }
                    )
                }
            }
            notificationsByDevice[deviceID] = rows
        case let .clipboardUpdate(update):
#if !GALAXYBRIDGE_APP_STORE
            // The shell agent observes every clipboard occurrence, including
            // copied images while Helper is in background. A parallel Helper
            // or mirror-control notification must not become a second writer.
            guard clipboardSessions[deviceID]?.usesClipboardOccurrences != true else { return }
#endif
            guard let control = companionClients[companionID]?.control else { return }
            acceptRemoteClipboard(deviceID: deviceID, changeID: update.changeID, kind: update.kind,
                content: update.content, sensitive: update.sensitive,
                sourceRouteID: "control:" + control.authenticatedSessionID)
        case let .featureConfigurationResult(result):
            handleFeatureConfigurationResult(companionID: companionID, deviceID: deviceID, envelope: envelope, result: result)
#if !GALAXYBRIDGE_APP_STORE
            reconcileCaptureRouteHandoffs()
#endif
        case let .capabilityUpdate(update):
            if update.available.contains(.calls) {
                do { try clientSetup.preserveAvailableOptionalCalls(deviceID: deviceID) }
                catch { lastError = String(localized: "CLIENT_SETUP_SAVE_FAILED") }
            }
            reconcileFeatureConfiguration(deviceID: deviceID)
#if !GALAXYBRIDGE_APP_STORE
            if let control = companionClients[companionID]?.control {
                internetSharing.reconnectIfNeeded(deviceID: deviceID, control: control)
            }
#endif
            availableCapabilitiesByDevice[deviceID] = Set(update.available.compactMap(Self.capabilityCode))
            capabilityReasonsByDevice[deviceID] = update.unavailableReasons
#if !GALAXYBRIDGE_APP_STORE
            reconcileShellCapabilities()
#endif
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
            guard featureEnabled(.calls, deviceID: deviceID) else { return }
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
        case .notificationActionResults: "CAPABILITY_NOTIFICATION_ACTION_RESULTS"
        case .nearbyLink: "CAPABILITY_NEARBY_LINK"
        case .internetGateway: "CAPABILITY_INTERNET_GATEWAY"
        case .privilegedBridge: "CAPABILITY_PRIVILEGED_BRIDGE"
        case .featureConfiguration: "CAPABILITY_FEATURE_CONFIGURATION"
        case .captureRetirementProof: "CAPABILITY_CAPTURE_RETIREMENT_PROOF"
        case .compositeDisplayState: "CAPABILITY_COMPOSITE_DISPLAY_STATE"
        case .shellRuntimeIdentity: "CAPABILITY_SHELL_RUNTIME_IDENTITY"
        case .UNRECOGNIZED: nil
        }
    }

#if !GALAXYBRIDGE_APP_STORE
    private func adoptVerifiedBinding(_ record: ADBBindingRecord) {
        adoptCaptureRetirementIdentity(record)
        validatedWirelessSerials.insert(record.adbSerial)
        let oldID = "adb:\(record.adbSerial)"
        let newID = "device:\(record.deviceID)"
        cacheMaintenance.reevaluateClipboardRoutes(deviceID: newID)
        guard oldID != newID else { return }
        applicationWindowCoordinator?.adoptDeviceIdentity(from: oldID, to: newID)
        migratePhoneDisplayPrivacy(from: oldID, to: newID)
        if let surface = videoSurfaces.removeValue(forKey: oldID), videoSurfaces[newID] == nil { videoSurfaces[newID] = surface }
        if let surface = cameraSurfaces.removeValue(forKey: oldID), cameraSurfaces[newID] == nil { cameraSurfaces[newID] = surface }
        if let state = enhancedStates.removeValue(forKey: oldID), enhancedStates[newID] == nil { enhancedStates[newID] = state }
        if let gate = mediaTransportDispatchGates.removeValue(forKey: oldID), mediaTransportDispatchGates[newID] == nil {
            mediaTransportDispatchGates[newID] = gate
        }
        enhancedSessionDiagnostics.migrate(from: oldID, to: newID)
        primaryScreenDemand.migrate(from: oldID, to: newID)
        for permit in enhancedRetirementDeviceIDs.keys where enhancedRetirementDeviceIDs[permit] == oldID {
            enhancedRetirementDeviceIDs[permit] = newID
        }
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
        sensitive: Bool,
        sourceRouteID: String? = nil,
        sourceIdentity: Data? = nil
    ) {
        guard terminationAdmission.admitsWork, featureEnabled(.clipboard, deviceID: deviceID), row(id: deviceID) != nil, !sensitive,
              let trust = cacheMaintenance.clipboardTrustToken(deviceID: deviceID),
              cacheMaintenance.isCurrent(trust, routeID: sourceRouteID, sourceIdentity: sourceIdentity) else { return }
        if kind == .text || kind == .url || kind == .png {
            var confirmed = false
#if !GALAXYBRIDGE_APP_STORE
            if let observer = clipboardSessions[deviceID], observer.supportsClipboardAvailability,
               sourceRouteID == "clipboard:" + observer.clipboardTrustGeneration.uuidString { confirmed = true }
#endif
            clipboardHub.observeClipboard(deviceID: deviceID,
                epoch: .init(trustGeneration: trust.generation, routeIDs: clipboardRouteIDs(deviceID: deviceID)),
                kind: kind == .png ? .png : .text, content: content, confirmed: confirmed)
        }
        // Cached change IDs survive process restarts. Consult them before the
        // process-local hub so a reconnect cannot replay an old phone write
        // into the Mac pasteboard or fan it out to the other Galaxy devices.
        guard !seenClipboardChangeIDs.contains(changeID) else { return }
        let decision = clipboardHub.acceptRemote(
            sourceDeviceID: deviceID,
            changeID: changeID
        )
        guard case let .accept(revision) = decision else { return }
        // Even a remote occurrence with identical bytes supersedes an older
        // local conversion. It must not later echo as a new Mac copy.
        clipboardConversion.invalidate()

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
            if pasteboard.data(forType: .png) != content {
                guard MacClipboardImageWriter.write(content, to: pasteboard) else { return }
                didWrite = true
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
        cacheMaintenance.store(.init(deviceID: deviceID, namespace: .clipboard, itemID: changeID), payload: content,
            clipboardTrust: trust)
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
        let pasteboard = clipboardPasteboard
        let occurrence = pasteboard.changeCount
        guard occurrence != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = occurrence
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let recipients = clipboardRecipients(excluding: nil)
        guard MacClipboardPayloadPolicy.isEligible(pasteboardTypes: types, hasDestination: !recipients.isEmpty) else {
            clipboardConversion.invalidate()
            return
        }
        let snapshot = MacClipboardSnapshot(occurrence: occurrence, pasteboardTypes: types,
            text: pasteboard.string(forType: .string), image: Self.clipboardImageSource(from: pasteboard))
        guard pasteboard.changeCount == occurrence else { clipboardConversion.invalidate(); return }
        // Assign the hub revision at ingress, before background conversion,
        // preserving ordering against remote clipboard occurrences.
        let revision = clipboardHub.acceptMacChange()
        clipboardConversion.submit(snapshot, hasDestination: true) { [weak self] result in
            Task { @MainActor in self?.acceptConvertedClipboard(result, revision: revision, recipients: recipients) }
        }
    }

    private func acceptConvertedClipboard(_ result: MacClipboardConversionWorker.Result, revision: UInt64,
                                          recipients: [ClipboardRecipient]) {
        guard terminationAdmission.admitsWork, clipboardConversion.isCurrent(result),
              clipboardPasteboard.changeCount == result.occurrence else { return }
        let candidate = result.candidate
        let kind: GBClipboardKind = switch candidate.kind {
        case .text: .text
        case .url: .url
        case .png: .png
        }
        broadcastClipboard(
            kind: kind,
            content: candidate.content,
            changeID: clipboardHub.outboundChangeID(revision: revision),
            excluding: nil,
            recipients: recipients
        )
    }

    @MainActor
    private struct ClipboardRecipient {
        let deviceID: String
        let peerFingerprint: Data?
        let trust: ContentCacheMaintenanceCoordinator.ClipboardTrustToken
        let companionSessionID: String?
        let controlRouteID: String?
        weak var control: CompanionTLSClient?
#if !GALAXYBRIDGE_APP_STORE
        var clipboardRouteID: String?
        var screenRouteID: String?
        weak var clipboardSession: ScrcpyClipboardSession?
        weak var screenSession: ScrcpySession?
#endif
    }

    /// Freeze occurrence recipients before conversion. Weak route identities do
    /// not retain retired connections or permit a newly joined/re-paired phone
    /// to acquire a copy from before its admission.
    private func clipboardRecipients(excluding sourceDeviceID: String?) -> [ClipboardRecipient] {
        ClipboardHubState.destinations(allConnectedDeviceIDs: devices.filter(\.isReady).map(\.id), excluding: sourceDeviceID)
            .compactMap { deviceID in
                guard featureEnabled(.clipboard, deviceID: deviceID), let trust = cacheMaintenance.clipboardTrustToken(deviceID: deviceID) else { return nil }
                let control = companionID(for: deviceID).flatMap { id in
                    companionStates[id] == .connected ? companionClients[id]?.control : nil
                }
                let controlID = control.map { "control:" + $0.authenticatedSessionID }
                let admittedControl = controlID.map { cacheMaintenance.isCurrent(trust, routeID: $0) } == true ? control : nil
                var recipient = ClipboardRecipient(deviceID: deviceID, peerFingerprint: filePeerFingerprints[deviceID],
                    trust: trust, companionSessionID: admittedControl?.authenticatedSessionID,
                    controlRouteID: admittedControl == nil ? nil : controlID, control: admittedControl)
                var hasRoute = admittedControl != nil
#if !GALAXYBRIDGE_APP_STORE
                if let session = clipboardSessions[deviceID] {
                    let routeID = "clipboard:" + session.clipboardTrustGeneration.uuidString
                    if cacheMaintenance.isCurrent(trust, routeID: routeID) {
                        recipient.clipboardSession = session; recipient.clipboardRouteID = routeID
                    }
                }
                if let session = scrcpySessions[deviceID] {
                    let routeID = "screen:" + session.clipboardTrustGeneration.uuidString
                    if cacheMaintenance.isCurrent(trust, routeID: routeID) {
                        recipient.screenSession = session; recipient.screenRouteID = routeID
                    }
                }
                hasRoute = hasRoute || recipient.clipboardSession != nil || recipient.screenSession != nil
#endif
                return hasRoute ? recipient : nil
            }
    }

    private func broadcastClipboard(
        kind: GBClipboardKind,
        content: Data,
        changeID: String,
        excluding sourceDeviceID: String?,
        recipients capturedRecipients: [ClipboardRecipient]? = nil
    ) {
        let recipients = capturedRecipients ?? clipboardRecipients(excluding: sourceDeviceID)
        for recipient in recipients {
            let deviceID = recipient.deviceID
            guard featureEnabled(.clipboard, deviceID: deviceID), deviceID != sourceDeviceID, row(id: deviceID)?.isReady == true,
                  filePeerFingerprints[deviceID] == recipient.peerFingerprint else { continue }
            let epoch = ClipboardDeliveryEpoch(trustGeneration: recipient.trust.generation,
                routeIDs: clipboardRouteIDs(deviceID: deviceID))
            let payloadKind: ClipboardDeliveryKind = kind == .png ? .png : .text
            let needsWrite = clipboardHub.needsDelivery(deviceID: deviceID, epoch: epoch, kind: payloadKind, content: content)
            var delivered = false
            if let control = recipient.control, let companionID = companionID(for: deviceID),
               let routeID = recipient.controlRouteID,
               cacheMaintenance.isCurrent(recipient.trust, routeID: routeID),
               companionStates[companionID] == .connected,
               companionClients[companionID]?.control === control,
               control.authenticatedSessionID == recipient.companionSessionID {
                var update = GBClipboardUpdate()
                update.changeID = changeID
                update.kind = kind
                update.content = content
                update.sensitive = false
                do {
                    if needsWrite { try control.sendClipboard(update) }
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
               let clipboardSession = recipient.clipboardSession,
               let routeID = recipient.clipboardRouteID,
               "clipboard:" + clipboardSession.clipboardTrustGeneration.uuidString == routeID,
               cacheMaintenance.isCurrent(recipient.trust, routeID: routeID),
               clipboardSessions[deviceID] === clipboardSession {
                delivered = !needsWrite || clipboardSession.setText(value, changeID: changeID)
            }
            if !delivered,
               (kind == .text || kind == .url),
               let value = String(data: content, encoding: .utf8),
               let session = recipient.screenSession,
               let routeID = recipient.screenRouteID,
               "screen:" + session.clipboardTrustGeneration.uuidString == routeID,
               cacheMaintenance.isCurrent(recipient.trust, routeID: routeID),
               scrcpySessions[deviceID] === session {
                if needsWrite { session.sendControl(
                    ScrcpyControlMessage.setClipboard(
                        sequence: clipboardSequence,
                        text: value,
                        paste: false
                    )
                ) }
                clipboardSequence &+= 1
                delivered = true
            }
#endif
            guard delivered else { continue }
            clipboardHub.observeClipboard(deviceID: deviceID, epoch: epoch, kind: payloadKind, content: content)
            cacheMaintenance.store(.init(deviceID: deviceID, namespace: .clipboard, itemID: changeID), payload: content,
                clipboardTrust: recipient.trust)
        }
    }

    private func clipboardRouteIDs(deviceID: String) -> Set<String> {
        var routes = Set<String>()
        if let id = companionID(for: deviceID), companionStates[id] == .connected,
           let control = companionClients[id]?.control { routes.insert("control:" + control.authenticatedSessionID) }
#if !GALAXYBRIDGE_APP_STORE
        if let session = clipboardSessions[deviceID] { routes.insert("clipboard:" + session.clipboardTrustGeneration.uuidString) }
        if let session = scrcpySessions[deviceID] { routes.insert("screen:" + session.clipboardTrustGeneration.uuidString) }
#endif
        return routes
    }

    private func revalidateClipboardTrust(for peers: [PairedPeer]) {
        for peer in peers {
            let deviceID = "device:" + peer.deviceID
            let fingerprint = OutgoingFileTransferStore.peerFingerprint(identityKey: peer.identityPublicKey,
                tlsFingerprint: peer.tlsCertificateSHA256, pairedAt: peer.pairedAt)
            guard filePeerFingerprints[deviceID] == fingerprint else { continue }
            let evaluated = clipboardRouteIDs(deviceID: deviceID)
            guard let trust = cacheMaintenance.clipboardValidationToken(deviceID: deviceID,
                fingerprint: fingerprint, routes: evaluated) else { continue }
            var approved = Set<String>()
            let matches: (PairedPeer) -> Bool = {
                $0.deviceID == peer.deviceID && $0.identityPublicKey == peer.identityPublicKey
                    && $0.tlsCertificateSHA256 == peer.tlsCertificateSHA256
            }
            if let id = companionID(for: deviceID), companionStates[id] == .connected,
               let control = companionClients[id]?.control, matches(control.peer) {
                approved.insert("control:" + control.authenticatedSessionID)
            }
#if !GALAXYBRIDGE_APP_STORE
            let bindings = ADBBindingStore()
            if let session = clipboardSessions[deviceID],
               session.clipboardTrustPeer.map(matches) ?? bindings.isVerified(serial: session.serial, peer: peer) {
                approved.insert("clipboard:" + session.clipboardTrustGeneration.uuidString)
            }
            if let session = scrcpySessions[deviceID],
               session.clipboardTrustPeer.map(matches) ?? bindings.isVerified(serial: session.serial, peer: peer) {
                approved.insert("screen:" + session.clipboardTrustGeneration.uuidString)
            }
#endif
            cacheMaintenance.validateClipboardRoutes(trust, fingerprint: fingerprint, evaluated: evaluated, approved: approved)
        }
    }

    private static func clipboardImageSource(from pasteboard: NSPasteboard) -> MacClipboardImageSource? {
        if let png = pasteboard.data(forType: .png) { return .png(png) }
        let imageTypes = NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        guard let type = pasteboard.availableType(from: imageTypes),
              let data = pasteboard.data(forType: type) else { return nil }
        return .encoded(data)
    }

    private func enqueueCompanionFilesEnvelope(
        companionID: String, generation: CompanionLogicalSessionRecoverySupervisor.Generation,
        deviceID: String, envelope: GBEnvelope, finished: @escaping @Sendable () -> Void
    ) {
        guard terminationAdmission.admitsWork, featureEnabled(.files, deviceID: deviceID),
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
        featureIncomingTransferIDs[deviceID, default: []].insert(transferID)
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
            guard let self, self.terminationAdmission.admitsWork, self.featureEnabled(.files, deviceID: deviceID),
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
            if receipt.complete || receipt.failureReason == "transfer_cancelled" {
                self.featureIncomingTransferIDs[deviceID]?.remove(transferID)
            }
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
        guard terminationAdmission.admitsWork, featureEnabled(.files, deviceID: deviceID), let transfer = pendingTransfers[ack.transferID],
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
                          featureEnabled(.files, deviceID: deviceID), pendingTransfers[transfer.id]?.peerFingerprint == transfer.peerFingerprint,
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
    var video: CompanionTLSClient
    var audio: CompanionTLSClient
    var camera: CompanionTLSClient
    var files: CompanionTLSClient
    let mediaFactories: [ClientSetupFeature: @MainActor () -> CompanionTLSClient]

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
