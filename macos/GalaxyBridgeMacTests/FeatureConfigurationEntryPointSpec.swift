import Foundation
import Combine

struct GBFeatureConfigurationRequest { var requestID = ""; var targetDeviceID = ""; var revision: UInt64 = 0; var enabledFeatureIds: [String] = [] }
struct GBFeatureConfigurationResult { var requestID = ""; var targetDeviceID = "phone"; var revision: UInt64 = 0; var accepted = true; var enabledFeatureIds: [String] = [] }
struct GBEnvelope { var deviceID = "phone"; var sessionID = "session-a" }
@MainActor final class CompanionTLSClient {
    struct Peer { var deviceID = "phone" }
    struct Capabilities { var negotiated = true }
    var peer = Peer(); var authenticatedSessionID = "session-a"; var connectivityCapabilities = Capabilities()
    var supportsFeatureConfiguration = true; var sent: [GBFeatureConfigurationRequest] = []
    var starts = 0; var cancellations = 0
    func sendFeatureConfiguration(_ request: GBFeatureConfigurationRequest) throws { sent.append(request) }
    func start() { starts += 1 }
    func cancel() { cancellations += 1 }
}
struct CompanionConnections {
    let control = CompanionTLSClient(); let events = CompanionTLSClient()
    var video = CompanionTLSClient(); var audio = CompanionTLSClient(); var camera = CompanionTLSClient(); var files = CompanionTLSClient()
    let mediaFactories: [ClientSetupFeature: @MainActor () -> CompanionTLSClient] = [.screen: { CompanionTLSClient() }, .audio: { CompanionTLSClient() }, .camera: { CompanionTLSClient() }, .files: { CompanionTLSClient() }]
}
struct DeviceRow { var id: String }
enum CompanionConnectionState: Equatable { case connected, disconnected, connecting, failed(String), authenticationRejected(String), transportInterrupted(String) }
enum GBChannelKind { case video, audio, camera, files }
@MainActor final class Supervisor { typealias Generation = UInt64; func currentGeneration(companionID: String) -> UInt64? { 1 } }
enum CompanionLogicalSessionRecoverySupervisor { typealias Generation = UInt64 }
struct BridgeNotificationRow { let id: String }
@MainActor struct NotificationBridge { func remove(deviceID: String, notificationID: String) {} }
struct Snapshot { mutating func forget(deviceID: String) {} }
struct Recording { let id: UUID; let deviceID: String }
struct IncomingFileOwner { let deviceID: String; let fingerprint: Data }
struct Receipt { }
@MainActor struct Store { func requestCancellation(owner: IncomingFileOwner, id: String) {} ; func cancel(owner: IncomingFileOwner, id: String) async -> Receipt { .init() } }
struct Transfer { let deviceID: String; var id = "transfer" }
@MainActor final class Windows { var closed: [String] = []; func closeForFeaturePolicy(deviceID: String) { closed.append(deviceID) } }
@MainActor final class Demand { var viewers: Set<String> = []; func hasViewer(_ id: String) -> Bool { viewers.contains(id) } }
@MainActor final class Surface { func clearFrame() {} }
struct Route { var shellProvider: String? = nil }
struct ADBClient { init() throws {} }
typealias EnhancedCaptureAbsenceProof = @MainActor @Sendable (UInt32) async throws -> Void
@MainActor final class ScrcpySession {
    enum CopyKey { case none, copy, cut }
    let remoteAbsenceProof: EnhancedCaptureAbsenceProof?
    let audioCaptureEnabled: Bool; var playbackEnabled = true; var clipboardReads = 0
    init(serial: String, adb: ADBClient, automaticDisplayManagement: Bool, primaryDiagnosticsEnabled: Bool, clipboardPollingEnabled: Bool,
        audioCaptureEnabled: Bool = true, quicSelection: String?, shellProvider: String?, remoteAbsenceProof: EnhancedCaptureAbsenceProof? = nil) {
        self.audioCaptureEnabled = audioCaptureEnabled; self.remoteAbsenceProof = remoteAbsenceProof
    }
    func setPlaybackEnabled(_ enabled: Bool) { playbackEnabled = enabled }
    func requestClipboard(copyKey: CopyKey, afterExternalCopy: Bool = false) { clipboardReads += 1 }
}
enum RemoteClipboardCommand { case copy, cut }
enum EnhancedClipboardOperation { case copy, cut }
enum EnhancedClipboardRequest { case readCurrent, atomicCopy, atomicCut }
@MainActor enum EnhancedClipboardRequestDispatcher {
    static func request(_ operation: EnhancedClipboardOperation, companion: (EnhancedClipboardOperation)->Bool, scrcpy: (EnhancedClipboardRequest)->Void) {
        if !companion(operation) { scrcpy(operation == .copy ? .atomicCopy : .atomicCut) }
    }
}
@MainActor final class AppModel: ObservableObject {
    struct Termination { var admitsWork = true }
    let clientSetup: ClientSetupModel
    var clipboardHub = ClipboardHubState()
    var featureConfigurationTimeouts: [String: Task<Void, Never>] = [:]
    var featureConfigurationRequestIDs: [String: String] = [:]
    var featureStartedMediaSessions: [String: String] = [:]
    var featureStartedMediaFeatures: [String: Set<ClientSetupFeature>] = [:]
    var featureClosedMediaChannels: [String: Set<ClientSetupFeature>] = [:]
    var featureMediaChannelTokens: [String: [ClientSetupFeature: UUID]] = [:]
    var featureMediaRetryTasks: [String: [ClientSetupFeature: Task<Void, Never>]] = [:]
    var featureMediaRetryTokens: [String: [ClientSetupFeature: UUID]] = [:]
    var featureMediaRetryAttempts: [String: [ClientSetupFeature: Int]] = [:]
    var fileChunkTasks: [String: Task<Void, Never>] = [:]
    var fileChunkTokens: [String: UUID] = [:]
    var featureIncomingTransferIDs: [String: Set<String>] = [:]
    var companionClients: [String: CompanionConnections] = ["route": .init()]
    var companionStates: [String: CompanionConnectionState] = ["route": .connected]
    let companionRecoverySupervisor = Supervisor()
    var proofRequests: [(String, String, UInt32)] = []
    var recoveryCount = 0; var keyCount = 0; var mediaStateCallbacks = 0
    var notificationsByDevice: [String: [BridgeNotificationRow]] = [:]; let macNotifications = NotificationBridge(); var notificationSnapshotReconciliation = Snapshot()
    var callByDevice: [String: String] = [:]; var callHistoryByDevice: [String: String] = [:]; var recordingAudioSources: [String: String] = [:]
    var applicationCatalogRequestsByDevice: [String: String] = [:]; var applicationCatalogsByDevice: [String: String] = [:]
    var activeRecordings: [Recording] = []; var filePreparationDevices: [UUID: String] = [:]; var cancelledFilePreparationIDs = Set<UUID>()
    var filePreparationTasks: [UUID: Task<Void, Never>] = [:]; var pendingTransfers: [String: Transfer] = [:]; var filePeerFingerprints: [String: Data] = [:]
    let incomingFileStore = Store(); var incomingFileTasks: [UUID: Task<Void, Never>] = [:]
    var videoSurfaces: [String: Surface] = [:]; var scrcpySessions: [String: ScrcpySession] = [:]
    let primaryScreenDemand = Demand(); var applicationWindowCoordinator: Windows? = Windows()
    var primaryDiagnosticsEnabled = false; var primaryMediaDiagnosticsEnabled = false; var phonePrivacyManualPower: [String: String] = [:]
    var terminationAdmission = Termination(); var lastError: String?; var retiredPrimary: [String] = []; var ensuredPrimary: [String] = []
    init(_ url: URL) { clientSetup = .init(storageURL: url) }
    func companionID(for id: String) -> String? { companionClients["route"] == nil ? nil : "route" }
    func companionControl(for id: String) -> CompanionTLSClient? { companionClients["route"]?.control }
    func row(id: String) -> DeviceRow? { .init(id: id) }
    func cancelAudioVerification(deviceID: String) {}
    func updateAudioPlaybackDemand(deviceID: String) { scrcpySessions[deviceID]?.setPlaybackEnabled(featureEnabled(.audio, deviceID: deviceID) && primaryScreenDemand.hasViewer(deviceID)) }
    func configureCamera(deviceID: String, enabled: Bool) {}
    func stopRecording(id: UUID) {}
    func retireEnhancedScreenSession(deviceID: String) { retiredPrimary.append(deviceID); scrcpySessions.removeValue(forKey: deviceID) }
    func pauseFileTransfer(_ transfer: Transfer, status: String) {}
    func updateIncomingFileRow(deviceID: String, receipt: Receipt) {}
    func setInternetSharing(_ enabled: Bool, deviceID: String) {}
    func reconcileEnhancedClipboardSessions() {}
    func ensureEnhancedSession(for device: DeviceRow) { ensuredPrimary.append(device.id) }
    func ensureEnhancedSessionForPrimaryDemand(for device: DeviceRow) { if primaryScreenDemand.hasViewer(device.id) { ensureEnhancedSession(for: device) } }
    func handleCompanionState(companionID: String, generation: UInt64, channel: GBChannelKind, state: CompanionConnectionState) { mediaStateCallbacks += 1 }
    func recoverCompanionSession(companionID: String, generation: UInt64) -> Bool { recoveryCount += 1; return true }
    func phoneDisplayPrivacyEnabled(deviceID: String) -> Bool { false }
    func quicWirelessSelection(for device: DeviceRow) -> String? { nil }
    func captureRetirementAbsenceProof(deviceID: String, captureSerial: String) -> EnhancedCaptureAbsenceProof? {
        { [weak self] scid in self?.proofRequests.append((deviceID, captureSerial, scid)) }
    }
    func videoSurface(for id: String) -> Surface { .init() }
    func hasEnhancedTransport(deviceID: String) -> Bool { true }
    func sendEnhancedKeyViaCompanion(deviceID: String, isDown: Bool, keycode: Int, repeatCount: Int, modifiers: Int) -> Bool { keyCount += 1; return true }
    // ACTUAL_FEATURE_ENTRY_POINTS
}
@main enum FeatureConfigurationEntryPointSpec {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-feature-entry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = "device:" + UUID().uuidString.lowercased()
        let model = AppModel(root.appendingPathComponent("one.json"))
        try model.clientSetup.saveSelection(deviceID: phone, features: [.clipboard])
        model.featureStartedMediaSessions[phone] = "session-a"
        let originalControl = model.companionClients["route"]!.control, oldVideo = model.companionClients["route"]!.video
        oldVideo.cancel(); model.featureClosedMediaChannels[phone] = [.screen]
        model.setFeatureSelection(deviceID: phone, features: [.clipboard, .screen])
        precondition(model.recoveryCount == 0, "Re-enable retired its CONTROL socket before exact phone acknowledgement")
        let request = model.companionClients["route"]!.control.sent.last!
        var result = GBFeatureConfigurationResult(requestID: request.requestID, revision: request.revision, enabledFeatureIds: request.enabledFeatureIds)
        model.handleFeatureConfigurationResult(companionID: "route", deviceID: phone, envelope: GBEnvelope(sessionID: "old"), result: result)
        precondition(model.recoveryCount == 0, "Stale session receipt restarted channels")
        model.handleFeatureConfigurationResult(companionID: "route", deviceID: phone, envelope: .init(), result: result)
        precondition(model.recoveryCount == 0 && model.featureConfigurationTimeouts[phone] == nil, "Accepted exact policy must reopen the auxiliary channel after retiring its timeout")
        precondition(model.companionClients["route"]!.control === originalControl && model.companionClients["route"]!.video !== oldVideo && model.companionClients["route"]!.video.starts == 1,
            "Re-enable must replace only the closed media channel and preserve its control/session")
        model.resetFeatureConfigurationForSession(deviceID: phone)
        model.companionClients["route"] = .init()
        model.companionClients["route"]!.control.authenticatedSessionID = "session-b"
        model.reconcileFeatureConfiguration(deviceID: phone)
        let next = model.companionClients["route"]!.control.sent.last!
        precondition(next.requestID != request.requestID && next.revision > request.revision, "New session was blocked by the previous request timeout")
        result = GBFeatureConfigurationResult(requestID: next.requestID, revision: next.revision, enabledFeatureIds: next.enabledFeatureIds)
        model.handleFeatureConfigurationResult(companionID: "route", deviceID: phone, envelope: GBEnvelope(sessionID: "session-b"), result: result)
        precondition(model.companionClients["route"]!.video.starts == 1 && model.companionClients["route"]!.audio.starts == 0, "Fresh acknowledged session must start only selected media exactly once")
        let oldStarts = model.companionClients["route"]!.video.starts
        model.handleFeatureConfigurationResult(companionID: "route", deviceID: phone, envelope: GBEnvelope(sessionID: "session-b"), result: result)
        precondition(model.companionClients["route"]!.video.starts == oldStarts, "Repeated acknowledgement reopened channels")
        let obsoleteChannel = UUID(), currentChannel = UUID()
        model.featureMediaChannelTokens[phone] = [.audio: currentChannel]
        model.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: obsoleteChannel, companionID: "route", generation: 1, channel: .audio, state: .disconnected)
        model.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: currentChannel, companionID: "route", generation: 2, channel: .audio, state: .disconnected)
        precondition(model.mediaStateCallbacks == 0, "An obsolete channel/generation callback retired the replacement")
        model.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: currentChannel, companionID: "route", generation: 1, channel: .audio, state: .connected)
        precondition(model.mediaStateCallbacks == 1, "The exact current channel callback was lost")
        // A socket timeout after authenticated Hello must not enter parent-session recovery.
        let isolated = AppModel(root.appendingPathComponent("isolated.json"))
        try isolated.clientSetup.saveSelection(deviceID: phone, features: [.screen, .audio, .files, .camera])
        isolated.clientSetup.markLegacy(deviceID: phone)
        isolated.startConfiguredCompanionMedia(deviceID: phone)
        let before = isolated.companionClients["route"]!
        let failedToken = UUID()
        isolated.featureMediaChannelTokens[phone, default: [:]][.audio] = failedToken
        isolated.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: failedToken,
            companionID: "route", generation: 1, channel: .audio, state: .transportInterrupted("socket timeout"))
        precondition(isolated.mediaStateCallbacks == 0 && isolated.recoveryCount == 0,
            "An authenticated auxiliary network timeout entered whole-session recovery")
        precondition(isolated.companionStates["route"] == .connected && before.audio.cancellations == 1,
            "Auxiliary interruption did not retire only its own socket")
        precondition(before.control.cancellations == 0 && before.events.cancellations == 0
            && before.video.cancellations == 0 && before.camera.cancellations == 0 && before.files.cancellations == 0,
            "Auxiliary interruption cancelled healthy siblings")
        isolated.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: failedToken,
            companionID: "route", generation: 1, channel: .audio, state: .disconnected)
        precondition(isolated.mediaStateCallbacks == 0, "Old socket cancellation escaped its channel fence")
        for _ in 0..<100 {
            if isolated.companionClients["route"]!.audio !== before.audio { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(isolated.companionClients["route"]!.audio !== before.audio
            && isolated.companionClients["route"]!.audio.starts == 1,
            "Auxiliary channel was not replaced after bounded backoff")
        precondition(isolated.companionClients["route"]!.control === before.control
            && isolated.companionClients["route"]!.video === before.video
            && isolated.companionClients["route"]!.camera === before.camera
            && isolated.companionClients["route"]!.files === before.files,
            "Channel retry replaced healthy siblings")
        // Files retry retires transient readers but keeps resumable transfer state.
        let filesToken = UUID(), chunkToken = UUID()
        isolated.featureMediaChannelTokens[phone, default: [:]][.files] = filesToken
        isolated.pendingTransfers["transfer"] = Transfer(deviceID: phone)
        let reading: Task<Void, Never> = Task { try? await Task.sleep(for: .seconds(30)) }
        isolated.fileChunkTasks["transfer"] = reading; isolated.fileChunkTokens["transfer"] = chunkToken
        isolated.handleFeatureMediaState(deviceID: phone, feature: .files, channelToken: filesToken,
            companionID: "route", generation: 1, channel: .files, state: .transportInterrupted("EOF"))
        precondition(reading.isCancelled && isolated.fileChunkTasks["transfer"] == nil
            && isolated.fileChunkTokens["transfer"] == nil && isolated.pendingTransfers["transfer"] != nil,
            "Files retry retained a stale reader or destroyed durable resume state")
        // A policy update pending its phone ACK must fence every delayed reopen.
        try isolated.clientSetup.saveSelection(deviceID: phone, features: [.screen, .audio, .camera, .files])
        for _ in 0..<100 {
            if isolated.featureMediaRetryTasks[phone]?[.files] == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(isolated.companionClients["route"]!.files === before.files,
            "Files retry bypassed a pending feature policy acknowledgement")
        isolated.reconcileFeatureConfiguration(deviceID: phone)
        let filesPolicy = isolated.companionClients["route"]!.control.sent.last!
        isolated.handleFeatureConfigurationResult(companionID: "route", deviceID: phone, envelope: .init(),
            result: .init(requestID: filesPolicy.requestID, revision: filesPolicy.revision, enabledFeatureIds: filesPolicy.enabledFeatureIds))
        precondition(isolated.companionClients["route"]!.files !== before.files
            && isolated.companionClients["route"]!.files.starts == 1,
            "Exact policy ACK did not restart the deferred files channel")
        // Independent backoffs cannot be bypassed by another feature's ACK/retry.
        let audioBefore = isolated.companionClients["route"]!.audio, cameraBefore = isolated.companionClients["route"]!.camera
        let audioToken = UUID(), cameraToken = UUID()
        isolated.featureMediaChannelTokens[phone, default: [:]][.audio] = audioToken
        isolated.featureMediaChannelTokens[phone, default: [:]][.camera] = cameraToken
        isolated.featureMediaRetryAttempts[phone, default: [:]][.audio] = 3
        isolated.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: audioToken,
            companionID: "route", generation: 1, channel: .audio, state: .transportInterrupted("slow retry"))
        isolated.handleFeatureMediaState(deviceID: phone, feature: .camera, channelToken: cameraToken,
            companionID: "route", generation: 1, channel: .camera, state: .transportInterrupted("fast retry"))
        for _ in 0..<100 {
            if isolated.companionClients["route"]!.camera !== cameraBefore { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(isolated.companionClients["route"]!.camera !== cameraBefore
            && isolated.companionClients["route"]!.audio === audioBefore,
            "A fast sibling retry bypassed the audio backoff")
        isolated.setFeatureSelection(deviceID: phone, features: [.screen, .files, .camera])
        precondition(isolated.featureMediaRetryTasks[phone]?[.audio] == nil
            && isolated.featureMediaRetryTokens[phone]?[.audio] == nil,
            "Disabling a feature retained its delayed retry")
        isolated.resetFeatureConfigurationForSession(deviceID: phone)
        precondition(isolated.featureMediaRetryTasks[phone] == nil && isolated.featureMediaRetryAttempts[phone] == nil,
            "Session reset retained auxiliary retry work")
        let protocolToken = UUID()
        isolated.featureMediaChannelTokens[phone, default: [:]][.audio] = protocolToken
        isolated.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: protocolToken,
            companionID: "route", generation: 1, channel: .audio, state: .authenticationRejected("revoked"))
        isolated.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: protocolToken,
            companionID: "route", generation: 1, channel: .audio, state: .failed("bad frame"))
        precondition(isolated.mediaStateCallbacks == 2, "Authentication/protocol failure was downgraded to socket-only recovery")
        isolated.terminationAdmission.admitsWork = false
        isolated.handleFeatureMediaState(deviceID: phone, feature: .audio, channelToken: protocolToken,
            companionID: "route", generation: 1, channel: .audio, state: .transportInterrupted("shutdown"))
        precondition(isolated.featureMediaRetryTasks[phone] == nil, "Termination admitted a new auxiliary retry")
        let other = "device:" + UUID().uuidString.lowercased()
        let audio = AppModel(root.appendingPathComponent("audio.json"))
        try audio.clientSetup.saveSelection(deviceID: phone, features: [.screen, .audio, .clipboard])
        audio.primaryScreenDemand.viewers = [phone, other]
        let first = try audio.createActualEnhancedSession(device: .init(id: phone)), second = try audio.createActualEnhancedSession(device: .init(id: other))
        precondition(first.remoteAbsenceProof != nil && second.remoteAbsenceProof != nil,
            "actual capture constructor omitted its phone-specific retirement proof")
        try await first.remoteAbsenceProof!(17); try await second.remoteAbsenceProof!(23)
        precondition(audio.proofRequests.count == 2 && audio.proofRequests[0].0 == phone
            && audio.proofRequests[0].1 == "synthetic" && audio.proofRequests[0].2 == 17
            && audio.proofRequests[1].0 == other && audio.proofRequests[1].2 == 23,
            "actual capture constructor crossed phone/SCID retirement authority")
        audio.scrcpySessions = [phone: first, other: second]
        audio.setFeatureSelection(deviceID: phone, features: [.screen])
        precondition(audio.retiredPrimary == [phone] && audio.scrcpySessions[other] === second && audio.applicationWindowCoordinator?.closed.isEmpty == true, "Audio OFF must retire only the target primary capture owner")
        let replacement = try audio.createActualEnhancedSession(device: .init(id: phone)); audio.bindActualEnhancedPlayback(replacement, deviceID: phone)
        precondition(!replacement.audioCaptureEnabled && !replacement.playbackEnabled, "A screen reopen bypassed audio OFF at capture or playback binding")
        audio.scrcpySessions[phone] = replacement
        precondition(!audio.requestRemoteClipboard(deviceID: phone, command: .copy) && replacement.clipboardReads == 0, "Clipboard OFF read the phone clipboard")
        precondition(!audio.sendEnhancedClipboardCommandViaCompanion(deviceID: phone, operation: .cut) && audio.keyCount == 0, "Clipboard OFF injected a companion copy/cut command")
        audio.setFeatureSelection(deviceID: phone, features: [.screen, .audio])
        precondition(audio.retiredPrimary == [phone, phone], "Audio ON must also replace the prior audio-free capture owner")
        let enabled = try audio.createActualEnhancedSession(device: .init(id: phone)); audio.bindActualEnhancedPlayback(enabled, deviceID: phone)
        precondition(enabled.audioCaptureEnabled && enabled.playbackEnabled, "Audio ON did not restore capture and viewer demand")
        let legacy = AppModel(root.appendingPathComponent("legacy.json"))
        legacy.companionClients["route"]!.control.supportsFeatureConfiguration = false
        try legacy.clientSetup.saveSelection(deviceID: phone, features: [])
        legacy.featureStartedMediaSessions[phone] = "session-a"
        legacy.setFeatureSelection(deviceID: phone, features: [.screen])
        precondition(legacy.recoveryCount == 0 && legacy.companionClients["route"]!.video.starts == 1 && legacy.clientSetup.synchronization(deviceID: phone) == .localOnly, "Legacy peer must permit local re-enable without a fabricated phone ACK")
        print("PASS actual AppModel feature entry points: exact ACK before auxiliary restart with retained control/session, stale/duplicate rejection, fresh session reconciliation, selected media start, legacy local policy, target-only audio capture restart, playback rebinding and clipboard OFF")
    }
}
