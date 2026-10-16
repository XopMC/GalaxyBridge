import Foundation

@main
enum NotificationActionEntryPointSpec {
    @MainActor static func main() throws {
        let featureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("gb-notification-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: featureRoot) }
        let policy = AppModel(featureStorageURL: featureRoot.appendingPathComponent("choices.json"))
        let first = "device:" + UUID().uuidString.lowercased(), second = "device:" + UUID().uuidString.lowercased()
        try policy.clientSetup.saveSelection(deviceID: first, features: Set(ClientSetupFeature.shippingFeatures).subtracting([.notifications]))
        policy.control = CompanionTLSClient()
        precondition(!policy.canSendNotificationAction(deviceID: first))
        precondition(!policy.performNotificationAction(deviceID: first, notificationID: "off", actionID: "0", reply: "must not retain"))
        precondition(policy.notificationActions.entries.isEmpty && policy.notificationActions.pending.isEmpty && policy.control?.sent.isEmpty == true,
            "Notifications OFF must reject native reply storage and transport before either admission")
        precondition(policy.canSendNotificationAction(deviceID: second))
        precondition(policy.performNotificationAction(deviceID: second, notificationID: "on", actionID: "0", reply: "second phone retained"))
        precondition(policy.notificationActionEntry(deviceID: second, notificationID: "on", actionID: "0").draft == "second phone retained")
        precondition(policy.notificationActions.pending.count == 1 && policy.control?.sent.count == 1,
            "Another phone's notification policy must remain independent")
        let model = AppModel()
        let text = "Synthetic native reply — ответ42"
        // Native Notification Center never called setNotificationReply first.
        precondition(!model.performNotificationAction(deviceID: "phone", notificationID: "synthetic", actionID: "0", reply: text))
        precondition(model.notificationActionEntry(deviceID: "phone", notificationID: "synthetic", actionID: "0").draft == text,
            "Native-style reply must be captured before the missing-connection guard")
        precondition(model.notifications(for: "phone").count == 1, "Native input with no live row still needs an accessible editor")
        let metadata = AppModel()
        precondition(!metadata.performNotificationAction(deviceID: "phone", notificationID: "metadata", actionID: "0",
            reply: text, composeID: "native-metadata", replyPackageName: "synthetic.qa", replyAppLabel: "Synthetic QA"))
        let retained = metadata.notifications(for: "phone").first!
        precondition(retained.appLabel == "Synthetic QA" && retained.packageName == "synthetic.qa")
        precondition(retained.actions.first?.id == "0" && retained.actions.first?.acceptsText == true)

        model.control = CompanionTLSClient()
        model.companionRecoverySupervisor.generation = nil
        precondition(!model.performNotificationAction(deviceID: "phone", notificationID: "synthetic", actionID: "0",
            reply: "generation unavailable", composeID: "native-no-generation", replyPackageName: "synthetic.qa", replyAppLabel: "Synthetic QA"))
        precondition(model.notificationActionEntry(deviceID: "phone", notificationID: "synthetic", actionID: "0", composeID: "native-no-generation").draft == "generation unavailable")
        precondition(model.control?.sent.isEmpty == true)

        model.companionRecoverySupervisor.generation = 4
        model.setNotificationReply("A", deviceID: "phone", notificationID: "synthetic", actionID: "0")
        precondition(model.performNotificationAction(deviceID: "phone", notificationID: "synthetic", actionID: "0", reply: "A"))
        let inAppRequest = model.notificationActions.pending.values.first!
        model.setNotificationReply("B", deviceID: "phone", notificationID: "synthetic", actionID: "0")
        model.setNotificationReply("A", deviceID: "phone", notificationID: "synthetic", actionID: "0")
        // A separate native response must survive the existing wire action's busy guard.
        precondition(!model.performNotificationAction(deviceID: "phone", notificationID: "synthetic", actionID: "0",
            reply: text, composeID: "native-independent"))
        precondition(model.notificationActionEntry(deviceID: "phone", notificationID: "synthetic", actionID: "0").draft == "A")
        precondition(model.notificationActionEntry(deviceID: "phone", notificationID: "synthetic", actionID: "0", composeID: "native-independent").draft == text)
        precondition(model.notificationActions.pending.count == 1 && model.control?.sent.count == 1)
        precondition(model.notificationActions.resolve(requestID: inAppRequest.requestID, notificationID: "synthetic", actionID: "0",
            companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(model.notificationActionEntry(deviceID: "phone", notificationID: "synthetic", actionID: "0").draft == "A", "The in-app ABA draft survives its original acknowledgement")

        precondition(model.performNotificationAction(deviceID: "phone", notificationID: "synthetic", actionID: "0",
            reply: text, composeID: "native-independent"))
        let nativeRequest = model.notificationActions.pending.values.first!
        precondition(nativeRequest.identity.composeID == "native-independent")
        precondition(model.notificationActions.resolve(requestID: nativeRequest.requestID, notificationID: "synthetic", actionID: "0",
            companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(model.notificationActionEntry(deviceID: "phone", notificationID: "synthetic", actionID: "0", composeID: "native-independent").draft.isEmpty)
        precondition(model.notificationActionEntry(deviceID: "phone", notificationID: "synthetic", actionID: "0").draft == "A", "Native acceptance cannot clear the independent in-app draft")

        let full = AppModel()
        for index in 0..<512 {
            full.setNotificationReply("preserved", deviceID: "phone", notificationID: "row-\(index)", actionID: "0")
        }
        precondition(!full.performNotificationAction(deviceID: "phone", notificationID: "overflow", actionID: "0", reply: text, composeID: "native-overflow"))
        precondition(full.notificationActions.entries.count == 512 && full.notificationActions.pending.isEmpty)
        precondition(full.notificationActions.entries.values.allSatisfy { $0.draft == "preserved" }, "Full admission cannot evict unsent input")
        print("PASS actual notification submission: real per-phone feature policy blocks disabled draft storage/send, independent second phone, offline/generationless native input, visible retained editor, independent native/in-app ABA drafts, busy admission, native acceptance isolation, bounded capacity")
    }
}
