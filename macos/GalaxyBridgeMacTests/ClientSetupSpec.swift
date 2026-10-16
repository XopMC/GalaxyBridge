import Foundation

private enum FixtureError: Error { case failed(String) }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw FixtureError.failed(message) }
}
@main enum ClientSetupSpec {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-setup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("choices/v1.json")
        let first = "device:" + UUID().uuidString.lowercased(), second = "device:" + UUID().uuidString.lowercased()
        let internalPath = ClientSetupModel.defaultStorageURL(bundleIdentifier: "com.xopmc.GalaxyBridge.internal", homeDirectory: root)
        let publicPath = ClientSetupModel.defaultStorageURL(bundleIdentifier: "com.xopmc.GalaxyBridge", homeDirectory: root)
        try require(internalPath != publicPath && internalPath.path.contains("/GalaxyBridgeInternal/"), "Internal preferences share the customer profile")
        let legacyPath = root.appendingPathComponent("legacy-v1.json")
        let legacyChoices: [String: Any] = ["version": 1, "choices": [first: ["screen"], second: ["calls"]]]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacyChoices).write(to: legacyPath)
        let legacy = ClientSetupModel(storageURL: legacyPath)
        try require(legacy.selection(deviceID: first) == Set(ClientSetupFeature.shippingFeatures), "old verification checklist incorrectly disabled shipping features")
        try require(legacy.selection(deviceID: second) == Set(ClientSetupFeature.shippingFeatures + [.calls]), "old optional calls choice was lost")
        let internalModel = ClientSetupModel(storageURL: internalPath), publicModel = ClientSetupModel(storageURL: publicPath)
        try internalModel.saveSelection(deviceID: first, features: [.calls])
        try publicModel.saveSelection(deviceID: first, features: [.screen])
        try require(ClientSetupModel(storageURL: internalPath).selection(deviceID: first) == [.calls], "public choices overwrite Internal")
        try require(ClientSetupModel(storageURL: publicPath).selection(deviceID: first) == [.screen], "Internal choices overwrite public")
        try internalModel.forget(deviceID: first)
        try require(ClientSetupModel(storageURL: publicPath).selection(deviceID: first) == [.screen], "Internal forget removes customer choices")
        let model = ClientSetupModel(storageURL: path)
        try require(model.selection(deviceID: first) == Set(ClientSetupFeature.shippingFeatures), "new phone must have all shipping features available")
        for alias in ["usb:serial", "device:not-a-verified-identity", "wifi:192.168.1.2"] {
            do { try model.saveSelection(deviceID: alias, features: [.screen]); throw FixtureError.failed("alias accepted") }
            catch ClientSetupError.unverifiedDevice {}
        }
        try model.saveSelection(deviceID: first, features: [])
        try require(model.selection(deviceID: first).isEmpty, "all-off choice must persist")
        try require(ClientSetupModel(storageURL: path).selection(deviceID: first).isEmpty, "all-off choice lost on restart")
        try model.saveSelection(deviceID: first, features: [.screen, .files])
        try model.saveSelection(deviceID: second, features: [.notifications])
        try require(!model.allSelectedVerified(deviceID: first), "choices are not live evidence")
        try require(model.beginVerification(deviceID: first, feature: .camera) == nil, "unselected test admitted")
        let stale = model.beginVerification(deviceID: first, feature: .screen)!
        let active = model.beginVerification(deviceID: first, feature: .screen)!
        try require(!model.recordEvidence(deviceID: first, feature: .screen, attemptID: stale), "old attempt accepted")
        try require(!model.recordEvidence(deviceID: second, feature: .screen, attemptID: active), "cross-device evidence accepted")
        try require(model.recordEvidence(deviceID: first, feature: .screen, attemptID: active), "exact physical result rejected")
        try require(!model.allSelectedVerified(deviceID: first), "partial evidence marked complete")
        let file = model.beginVerification(deviceID: first, feature: .files)!
        model.cancelVerification(deviceID: first, feature: .files, attemptID: UUID())
        try require(model.currentAttemptID(deviceID: first, feature: .files) == file, "stale cancellation removed active attempt")
        try require(model.recordEvidence(deviceID: first, feature: .files, attemptID: file), "committed file result rejected")
        try require(model.allSelectedVerified(deviceID: first), "complete selected evidence not recognized")
        let relaunched = ClientSetupModel(storageURL: path)
        try require(relaunched.selection(deviceID: first) == [.screen, .files], "durable feature selection lost")
        try require(!relaunched.allSelectedVerified(deviceID: first), "live evidence persisted across app launch")
        model.invalidate(deviceID: first)
        try require(model.verification(deviceID: first, feature: .screen) == .notTested, "disconnect kept stale success")
        try require(!model.recordEvidence(deviceID: first, feature: .files, attemptID: file), "late disconnected result accepted")
        try require(model.selection(deviceID: second) == [.notifications], "disconnect changed another device")
        let notification = model.beginVerification(deviceID: second, feature: .notifications)!
        try model.saveSelection(deviceID: second, features: [.calls])
        try require(!model.recordEvidence(deviceID: second, feature: .notifications, attemptID: notification), "deselected result accepted")
        try require(!model.allSelectedVerified(deviceID: second), "unsupported evidence treated as done")
        for feature: ClientSetupFeature in [.sms, .calls, .camera] {
            try model.saveSelection(deviceID: second, features: [feature, .screen])
            try require(model.verification(deviceID: second, feature: feature) == .unavailable,
                        "missing result producer displayed a runnable test")
            try require(model.beginVerification(deviceID: second, feature: feature) == nil,
                        "missing result producer admitted an endless attempt")
            try require(!model.recordEvidence(deviceID: second, feature: feature, attemptID: UUID()),
                        "unsupported operation accepted fabricated evidence")
            let screen = model.beginVerification(deviceID: second, feature: .screen)!
            try require(model.recordEvidence(deviceID: second, feature: .screen, attemptID: screen), "supported neighbor blocked")
            try require(!model.allSelectedVerified(deviceID: second), "unavailable selection silently counted as complete")
            try require(ClientSetupModel(storageURL: path).selection(deviceID: second).contains(feature),
                        "unavailable choice silently removed")
        }
        try model.forget(deviceID: first)
        try require(ClientSetupModel(storageURL: path).selection(deviceID: first) == Set(ClientSetupFeature.shippingFeatures), "forget must restore defaults")
        let corrupt = root.appendingPathComponent("corrupt.json")
        try Data("broken-storage".utf8).write(to: corrupt)
        let corruptModel = ClientSetupModel(storageURL: corrupt)
        do { try corruptModel.saveSelection(deviceID: first, features: [.files]); throw FixtureError.failed("corrupt choices overwritten") }
        catch ClientSetupError.unreadableStorage {}
        try require(try String(contentsOf: corrupt, encoding: .utf8) == "broken-storage", "corrupt source destroyed")

        // A real failed atomic write must preserve in-memory selection. Forget
        // still invalidates ephemeral evidence when the disk cannot be changed.
        let obstructedPath = root.appendingPathComponent("obstructed/v1.json")
        let obstructed = ClientSetupModel(storageURL: obstructedPath)
        try obstructed.saveSelection(deviceID: first, features: [.screen])
        let accepted = obstructed.beginVerification(deviceID: first, feature: .screen)!
        try require(obstructed.recordEvidence(deviceID: first, feature: .screen, attemptID: accepted), "fixture live result missing")
        try FileManager.default.removeItem(at: obstructedPath)
        try FileManager.default.createDirectory(at: obstructedPath, withIntermediateDirectories: false)
        let sentinel = obstructedPath.appendingPathComponent("preserve")
        try Data("existing-data".utf8).write(to: sentinel)
        do { try obstructed.saveSelection(deviceID: first, features: [.camera]); fatalError("failed storage accepted new choices") }
        catch { }
        try require(obstructed.selection(deviceID: first) == [.screen], "failed save changed active selection")
        try require(obstructed.allSelectedVerified(deviceID: first), "failed save discarded unchanged valid proof")
        do { try obstructed.forget(deviceID: first); fatalError("failed storage accepted durable forget") }
        catch { }
        try require(!obstructed.allSelectedVerified(deviceID: first), "failed forget preserved live proof")
        try require(obstructed.selection(deviceID: first) == [.screen], "failed forget pretended preferences were removed")
        try require(try Data(contentsOf: sentinel) == Data("existing-data".utf8), "failed preference save destroyed destination")
        let optional = ClientSetupModel(storageURL: root.appendingPathComponent("optional.json"))
        try optional.preserveAvailableOptionalCalls(deviceID: first)
        try require(optional.selection(deviceID: first).contains(.calls), "existing authorized calls were disabled by default setup")
        try optional.saveSelection(deviceID: first, features: [.screen])
        try optional.preserveAvailableOptionalCalls(deviceID: first)
        try require(!optional.selection(deviceID: first).contains(.calls), "explicit calls off was overwritten")
        let sync = ClientSetupModel(storageURL: root.appendingPathComponent("sync.json"))
        try sync.saveSelection(deviceID: first, features: [.clipboard])
        let request = try sync.beginConfiguration(deviceID: first, sessionID: "session-a")
        try require(sync.synchronization(deviceID: first) == .pending, "request not pending")
        try require(!sync.receiveConfiguration(deviceID: second, sessionID: "session-a", requestID: request.requestID,
            revision: request.revision, enabledIDs: ["clipboard"], accepted: true), "cross-phone ack accepted")
        try require(!sync.receiveConfiguration(deviceID: first, sessionID: "session-old", requestID: request.requestID,
            revision: request.revision, enabledIDs: ["clipboard"], accepted: true), "stale-session ack accepted")
        try require(!sync.receiveConfiguration(deviceID: first, sessionID: "session-a", requestID: request.requestID,
            revision: request.revision, enabledIDs: ["camera"], accepted: true), "different policy acknowledged")
        try require(sync.receiveConfiguration(deviceID: first, sessionID: "session-a", requestID: request.requestID,
            revision: request.revision, enabledIDs: ["clipboard"], accepted: true), "exact persisted policy ack rejected")
        try require(sync.synchronization(deviceID: first) == .acknowledged, "ack status absent")
        sync.disconnectConfiguration(deviceID: first)
        try require(sync.synchronization(deviceID: first) == .pending, "disconnect kept phone acknowledgement")
        let next = try ClientSetupModel(storageURL: root.appendingPathComponent("sync.json")).beginConfiguration(deviceID: first, sessionID: "session-b")
        try require(next.revision > request.revision, "reconnect reused replayable revision")
        sync.markLegacy(deviceID: first)
        try require(sync.synchronization(deviceID: first) == .localOnly, "legacy peer has fabricated phone acknowledgement")
        print("Client setup passed: separate Internal/public storage, durable selection, exact attempt evidence, stale/cross-device rejection, disconnect/relaunch reset, unsupported pending, corrupt preservation and failed-write/forget semantics.")
    }
}
