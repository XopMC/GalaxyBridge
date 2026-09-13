import Combine
import Foundation

enum ClientSetupFeature: String, CaseIterable, Codable, Identifiable, Sendable {
    case screen, applications, audio, clipboard, files, notifications, sms, calls, camera, recording
    var id: String { rawValue }
    // Admit a test only when a real operation can return its exact attempt ID.
    // These features stay selectable; their missing verification is not success.
    var supportsLiveVerification: Bool {
        switch self {
        case .sms, .calls, .camera: false
        default: true
        }
    }
    var titleKey: String {
        switch self {
        case .screen: "CAPABILITY_NAME_SCREEN_CAPTURE"
        case .applications: "APPLICATIONS"
        case .audio: "CAPABILITY_NAME_AUDIO_FORWARDING"
        case .clipboard: "CLIENT_SETUP_CLIPBOARD"
        case .files: "CAPABILITY_NAME_FILES"
        case .notifications: "CAPABILITY_NAME_NOTIFICATIONS"
        case .sms: "CAPABILITY_NAME_SMS"
        case .calls: "CAPABILITY_NAME_CALLS"
        case .camera: "CAPABILITY_NAME_CAMERA_STREAM"
        case .recording: "CAPABILITY_NAME_RECORDING"
        }
    }
    var symbol: String {
        switch self {
        case .screen: "iphone"
        case .applications: "square.grid.2x2"
        case .audio: "speaker.wave.2"
        case .clipboard: "document.on.clipboard"
        case .files: "folder"
        case .notifications: "bell"
        case .sms: "message"
        case .calls: "phone"
        case .camera: "camera"
        case .recording: "record.circle"
        }
    }
}

enum ClientSetupVerification: Equatable { case unavailable, notTested, checking, verified }
enum ClientSetupError: Error { case unverifiedDevice, emptySelection, unreadableStorage }

/// Choices persist only for a cryptographically verified logical device ID.
/// Live proof is intentionally ephemeral and never inferred from capabilities,
/// permissions, connection state or a remembered choice.
@MainActor final class ClientSetupModel: ObservableObject {
    private struct Storage: Codable {
        var version = 1
        var choices: [String: Set<ClientSetupFeature>]
    }
    private struct Key: Hashable { let deviceID: String; let feature: ClientSetupFeature }
    @Published private var choices: [String: Set<ClientSetupFeature>] = [:]
    @Published private var attempts: [Key: UUID] = [:]
    @Published private var verified: Set<Key> = []
    private let storageURL: URL
    private var storageUnreadable = false

    nonisolated static func defaultStorageURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let product = bundleIdentifier == "com.xopmc.GalaxyBridge.internal" ? "GalaxyBridgeInternal" : "GalaxyBridge"
        return homeDirectory.appendingPathComponent("Library/Application Support/\(product)/ClientFeatureChoices/v1.json")
    }

    init(storageURL: URL = ClientSetupModel.defaultStorageURL()) {
        self.storageURL = storageURL
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let stored = try JSONDecoder().decode(Storage.self, from: Data(contentsOf: storageURL))
            guard stored.version == 1, stored.choices.keys.allSatisfy(Self.isVerifiedDeviceID),
                  stored.choices.values.allSatisfy({ !$0.isEmpty }) else { throw ClientSetupError.unreadableStorage }
            choices = stored.choices
        } catch { storageUnreadable = true }
    }

    static func isVerifiedDeviceID(_ deviceID: String) -> Bool {
        guard deviceID.hasPrefix("device:") else { return false }
        let suffix = String(deviceID.dropFirst(7))
        return UUID(uuidString: suffix) != nil && suffix == suffix.lowercased()
    }
    func selection(deviceID: String) -> Set<ClientSetupFeature> { choices[deviceID] ?? [] }

    func saveSelection(deviceID: String, features: Set<ClientSetupFeature>) throws {
        guard Self.isVerifiedDeviceID(deviceID) else { throw ClientSetupError.unverifiedDevice }
        guard !features.isEmpty else { throw ClientSetupError.emptySelection }
        var updated = choices
        updated[deviceID] = features
        try persist(updated)
        choices = updated
        attempts = attempts.filter { $0.key.deviceID != deviceID || features.contains($0.key.feature) }
        verified = verified.filter { $0.deviceID != deviceID || features.contains($0.feature) }
    }
    private func persist(_ updated: [String: Set<ClientSetupFeature>]) throws {
        guard !storageUnreadable else { throw ClientSetupError.unreadableStorage }
        let parent = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bytes = try JSONEncoder().encode(Storage(choices: updated))
        try bytes.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    @discardableResult func beginVerification(deviceID: String, feature: ClientSetupFeature) -> UUID? {
        guard feature.supportsLiveVerification, Self.isVerifiedDeviceID(deviceID),
              selection(deviceID: deviceID).contains(feature) else { return nil }
        let key = Key(deviceID: deviceID, feature: feature), attempt = UUID()
        verified.remove(key)
        attempts[key] = attempt
        return attempt
    }
    func currentAttemptID(deviceID: String, feature: ClientSetupFeature) -> UUID? {
        attempts[Key(deviceID: deviceID, feature: feature)]
    }
    func cancelVerification(deviceID: String, feature: ClientSetupFeature, attemptID: UUID) {
        let key = Key(deviceID: deviceID, feature: feature)
        if attempts[key] == attemptID { attempts.removeValue(forKey: key) }
    }
    /// The producer must capture this token when the user-requested operation
    /// begins and return it only after the physical result/commit it observes.
    @discardableResult func recordEvidence(deviceID: String, feature: ClientSetupFeature, attemptID: UUID) -> Bool {
        let key = Key(deviceID: deviceID, feature: feature)
        guard feature.supportsLiveVerification,
              selection(deviceID: deviceID).contains(feature), attempts[key] == attemptID else { return false }
        attempts.removeValue(forKey: key)
        verified.insert(key)
        return true
    }
    func verification(deviceID: String, feature: ClientSetupFeature) -> ClientSetupVerification {
        guard feature.supportsLiveVerification else { return .unavailable }
        let key = Key(deviceID: deviceID, feature: feature)
        if verified.contains(key) { return .verified }
        return attempts[key] == nil ? .notTested : .checking
    }
    func allSelectedVerified(deviceID: String) -> Bool {
        let selected = selection(deviceID: deviceID)
        return !selected.isEmpty && selected.allSatisfy { verification(deviceID: deviceID, feature: $0) == .verified }
    }
    func invalidate(deviceID: String) {
        attempts = attempts.filter { $0.key.deviceID != deviceID }
        verified = verified.filter { $0.deviceID != deviceID }
    }
    func invalidateAll() { attempts.removeAll(); verified.removeAll() }
    func forget(deviceID: String) throws {
        // Live proof is revoked even when durable preference removal fails.
        // A disk error must never preserve an accepted verification attempt.
        invalidate(deviceID: deviceID)
        var updated = choices
        updated.removeValue(forKey: deviceID)
        try persist(updated)
        choices = updated
    }
}
