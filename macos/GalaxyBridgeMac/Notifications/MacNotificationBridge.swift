import CryptoKit
import Foundation
import UserNotifications

enum MacNotificationReplayPolicy {
    static func shouldPublishNative(isInitialSnapshot: Bool, removed: Bool) -> Bool {
        !isInitialSnapshot && !removed
    }
}

struct MacNotificationResponse: Equatable, Sendable {
    let deviceID: String
    let notificationID: String
    let actionID: String
    let reply: String?
    let dismiss: Bool
    let opensApplication: Bool
    let packageName: String?
    let appLabel: String?

    init(
        deviceID: String,
        notificationID: String,
        actionID: String,
        reply: String?,
        dismiss: Bool,
        opensApplication: Bool = false,
        packageName: String? = nil,
        appLabel: String? = nil
    ) {
        self.deviceID = deviceID
        self.notificationID = notificationID
        self.actionID = actionID
        self.reply = reply
        self.dismiss = dismiss
        self.opensApplication = opensApplication
        self.packageName = packageName
        self.appLabel = appLabel
    }
}

enum MacNotificationPublishResult: Equatable {
    case enqueued
    case deferred
    case deduplicated
    case filtered
    case permissionDenied
}

enum MacNotificationSubmissionErrorCategory: Equatable, Sendable {
    case userNotifications
    case cocoa
    case posix
    case other
}

struct MacNotificationSubmissionFailure: Equatable, Sendable {
    let category: MacNotificationSubmissionErrorCategory
    let domain: String
    let code: Int

    var diagnosticDetail: String {
        let source = switch category {
        case .userNotifications: "Notification Center"
        case .cocoa: "macOS"
        case .posix: "System"
        case .other: "Notification service"
        }
        return "\(source) error \(code) (\(domain))"
    }

    fileprivate init(error: Error) {
        let error = error as NSError
        switch error.domain {
        case UNErrorDomain:
            self.init(category: .userNotifications, domain: UNErrorDomain, code: error.code)
        case NSCocoaErrorDomain:
            self.init(category: .cocoa, domain: NSCocoaErrorDomain, code: error.code)
        case NSPOSIXErrorDomain:
            self.init(category: .posix, domain: NSPOSIXErrorDomain, code: error.code)
        default:
            self.init(category: .other, domain: "other", code: error.code)
        }
    }

    init(category: MacNotificationSubmissionErrorCategory, domain: String, code: Int) {
        self.category = category
        self.domain = domain
        self.code = code
    }
}

enum MacNotificationSubmissionResult: Equatable, Sendable {
    case accepted
    case failed(MacNotificationSubmissionFailure)
}

enum MacNotificationAuthorizationState: Equatable, Sendable {
    case unknown
    case requesting
    case authorized
    case denied
    case failed
}

protocol MacNotificationCenterClient: AnyObject, Sendable {
    func install(delegate: any UNUserNotificationCenterDelegate)
    func requestAuthorization(completion: @escaping @Sendable (Bool, Error?) -> Void)
    func getAuthorizationState(
        completion: @escaping @Sendable (MacNotificationAuthorizationState) -> Void
    )
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void)
    func getDeliveredNotifications(completion: @escaping @Sendable ([UNNotification]) -> Void)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

private final class SystemMacNotificationCenterClient: MacNotificationCenterClient, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func install(delegate: any UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    func requestAuthorization(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        center.requestAuthorization(options: [.alert, .sound], completionHandler: completion)
    }

    func getAuthorizationState(
        completion: @escaping @Sendable (MacNotificationAuthorizationState) -> Void
    ) {
        center.getNotificationSettings { settings in
            let state: MacNotificationAuthorizationState
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                state = .authorized
            case .denied:
                state = .denied
            case .notDetermined:
                state = .unknown
            @unknown default:
                state = .failed
            }
            completion(state)
        }
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    func add(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void) {
        center.add(request, withCompletionHandler: completion)
    }

    func getDeliveredNotifications(completion: @escaping @Sendable ([UNNotification]) -> Void) {
        center.getDeliveredNotifications(completionHandler: completion)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

private final class SubmissionCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var addReturned = false
    private var synchronousCompletion: Error??

    func shouldDeliverAfterReturn(_ error: Error?) -> Bool {
        lock.withLock {
            guard addReturned else {
                synchronousCompletion = .some(error)
                return false
            }
            return true
        }
    }

    func markAddReturned() -> Error?? {
        lock.withLock {
            addReturned = true
            return synchronousCompletion
        }
    }
}

struct MacNotificationIconAttachmentStore: Sendable {
    static let maximumPNGBytes = 512 * 1_024
    static let maximumPixelDimension: UInt32 = 1_024

    let directoryURL: URL

    init(directoryURL: URL = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    func attachment(for pngData: Data?, requestIdentifier: String) -> UNNotificationAttachment? {
        guard let pngData, Self.isSafePNG(pngData) else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let digest = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
            let requestDigest = SHA256.hash(data: Data(requestIdentifier.utf8))
                .prefix(12)
                .map { String(format: "%02x", $0) }
                .joined()
            let iconURL = directoryURL
                .appendingPathComponent("\(requestDigest)-\(digest)", isDirectory: false)
                .appendingPathExtension("png")
            if !FileManager.default.fileExists(atPath: iconURL.path) {
                try pngData.write(to: iconURL, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: iconURL.path)
            }
            prune(keeping: iconURL)
            return try UNNotificationAttachment(
                identifier: "galaxybridge.android-app-icon.\(requestDigest)",
                url: iconURL
            )
        } catch {
            return nil
        }
    }

    static func isSafePNG(_ data: Data) -> Bool {
        guard data.count >= 24, data.count <= maximumPNGBytes else { return false }
        let bytes = [UInt8](data.prefix(24))
        guard Array(bytes[0 ..< 8]) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
              Array(bytes[12 ..< 16]) == [0x49, 0x48, 0x44, 0x52]
        else { return false }
        let width = UInt32(bytes[16]) << 24 | UInt32(bytes[17]) << 16 | UInt32(bytes[18]) << 8 | UInt32(bytes[19])
        let height = UInt32(bytes[20]) << 24 | UInt32(bytes[21]) << 16 | UInt32(bytes[22]) << 8 | UInt32(bytes[23])
        return width > 0 && height > 0 && width <= maximumPixelDimension && height <= maximumPixelDimension
    }

    private func prune(keeping currentURL: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let expiration = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for file in files where file != currentURL {
            let modificationDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modificationDate, modificationDate < expiration {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.xopmc.GalaxyBridge", isDirectory: true)
            .appendingPathComponent("NotificationIcons", isDirectory: true)
    }
}

enum MacNotificationResponseRouting {
    static let dismissActionID = "galaxybridge.dismiss"

    static func resolve(
        actionIdentifier: String,
        reply: String?,
        userInfo: [AnyHashable: Any]
    ) -> MacNotificationResponse? {
        guard let deviceID = userInfo["deviceID"] as? String,
              !deviceID.isEmpty,
              let notificationID = userInfo["notificationID"] as? String,
              !notificationID.isEmpty
        else { return nil }

        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            guard let packageName = userInfo["packageName"] as? String,
                  !packageName.isEmpty,
                  let appLabel = userInfo["appLabel"] as? String,
                  !appLabel.isEmpty
            else { return nil }
            return .init(
                deviceID: deviceID,
                notificationID: notificationID,
                actionID: "",
                reply: nil,
                dismiss: false,
                opensApplication: true,
                packageName: packageName,
                appLabel: appLabel
            )
        }

        if actionIdentifier == dismissActionID || actionIdentifier == UNNotificationDismissActionIdentifier {
            return .init(
                deviceID: deviceID,
                notificationID: notificationID,
                actionID: "",
                reply: nil,
                dismiss: true
            )
        }
        let prefix = "action:"
        guard actionIdentifier.hasPrefix(prefix) else { return nil }
        let actionID = String(actionIdentifier.dropFirst(prefix.count))
        guard !actionID.isEmpty else { return nil }
        return .init(
            deviceID: deviceID,
            notificationID: notificationID,
            actionID: actionID,
            reply: reply,
            dismiss: false
        )
    }
}

final class MacNotificationBridge: NSObject, @unchecked Sendable {
    var responseHandler: (@Sendable (MacNotificationResponse) -> Void)?
    var authorizationStateHandler: (@Sendable (MacNotificationAuthorizationState) -> Void)?
    var submissionResultHandler: (@Sendable (MacNotificationSubmissionResult) -> Void)?
    private let center: any MacNotificationCenterClient
    private let iconStore: MacNotificationIconAttachmentStore
    private let lock = NSLock()
    private var categories: [String: UNNotificationCategory] = [:]
    private var metadata: [String: Metadata] = [:]
    private var pending: [String: PendingPublication] = [:]
    private var inFlight: [String: InFlightPublication] = [:]
    private var nextSubmissionGeneration: UInt64 = 0
    private var storedAuthorizationState: MacNotificationAuthorizationState = .unknown
    private let qaDiagnosticsEnabled: Bool
    private let qaDiagnosticSink: @Sendable (String) -> Void
    private let qaDeliveryAuditDelay: TimeInterval

    private struct Metadata {
        let deviceID: String
        let packageName: String
        let fingerprint: Data
        let category: UNNotificationCategory
    }

    private struct PendingPublication {
        let deviceID: String
        let deviceName: String
        let notification: BridgeNotificationRow
        let mutedPackages: Set<String>
        let onAccepted: (@Sendable () -> Void)?
    }

    private struct PreparedPublication {
        let deviceID: String
        let packageName: String
        let fingerprint: Data
        let category: UNNotificationCategory
        let request: UNNotificationRequest
        let hasIconAttachment: Bool
        let onAccepted: (@Sendable () -> Void)?
    }

    private struct InFlightPublication {
        let generation: UInt64
        let current: PreparedPublication
        var desired: PreparedPublication?
        var disposition: InFlightDisposition
    }

    private enum InFlightDisposition: Equatable {
        case active
        case removalPending
    }

    init(
        center: any MacNotificationCenterClient = SystemMacNotificationCenterClient(),
        iconStore: MacNotificationIconAttachmentStore = .init(),
        qaDiagnosticsEnabled: Bool = Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && ProcessInfo.processInfo.arguments.contains("--qa-notification-diagnostics"),
        qaDeliveryAuditDelay: TimeInterval = 1,
        qaDiagnosticSink: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.center = center
        self.iconStore = iconStore
        self.qaDiagnosticsEnabled = qaDiagnosticsEnabled
        self.qaDeliveryAuditDelay = qaDeliveryAuditDelay
        self.qaDiagnosticSink = qaDiagnosticSink
        super.init()
        center.install(delegate: self)
    }

    var authorizationState: MacNotificationAuthorizationState {
        lock.withLock { storedAuthorizationState }
    }

    func requestAuthorization() {
        transitionAuthorization(to: .requesting)
        center.requestAuthorization { [weak self] granted, error in
            self?.transitionAuthorization(to: error == nil ? (granted ? .authorized : .denied) : .failed)
        }
    }

    func refreshAuthorizationStatus() {
        center.getAuthorizationState { [weak self] state in
            self?.transitionAuthorization(to: state)
        }
    }

    @discardableResult
    func publish(
        deviceID: String,
        deviceName: String,
        notification: BridgeNotificationRow,
        mutedPackages: Set<String>,
        onAccepted: (@Sendable () -> Void)? = nil
    ) -> MacNotificationPublishResult {
        if mutedPackages.contains(notification.packageName) {
            remove(deviceID: deviceID, notificationID: notification.id)
            return .filtered
        }

        let identifier = Self.identifier(deviceID: deviceID, notificationID: notification.id)
        lock.lock()
        switch storedAuthorizationState {
        case .unknown, .requesting:
            pending[identifier] = PendingPublication(
                deviceID: deviceID,
                deviceName: deviceName,
                notification: notification,
                mutedPackages: mutedPackages,
                onAccepted: onAccepted
            )
            lock.unlock()
            return .deferred
        case .denied, .failed:
            pending.removeValue(forKey: identifier)
            lock.unlock()
            return .permissionDenied
        case .authorized:
            break
        }

        let fingerprint = Self.fingerprint(deviceName: deviceName, notification: notification)
        let publication = preparePublication(
            identifier: identifier,
            deviceID: deviceID,
            deviceName: deviceName,
            notification: notification,
            fingerprint: fingerprint,
            onAccepted: onAccepted
        )

        if var existing = inFlight[identifier] {
            if existing.desired?.fingerprint == fingerprint {
                lock.unlock()
                return .deduplicated
            }
            if existing.disposition == .active, existing.current.fingerprint == fingerprint {
                existing.desired = nil
                inFlight[identifier] = existing
                lock.unlock()
                return .deduplicated
            }
            existing.desired = publication
            inFlight[identifier] = existing
            lock.unlock()
            return .enqueued
        }
        if metadata[identifier]?.fingerprint == fingerprint {
            lock.unlock()
            return .deduplicated
        }
        let generation = makeSubmissionGenerationLocked()
        inFlight[identifier] = InFlightPublication(
            generation: generation,
            current: publication,
            desired: nil,
            disposition: .active
        )
        lock.unlock()
        submit(identifier: identifier, generation: generation, publication: publication)
        return .enqueued
    }

    private func preparePublication(
        identifier: String,
        deviceID: String,
        deviceName: String,
        notification: BridgeNotificationRow,
        fingerprint: Data,
        onAccepted: (@Sendable () -> Void)?
    ) -> PreparedPublication {
        let categoryID = "galaxybridge.\(identifier)"
        let actions = notification.actions.prefix(3).map { action -> UNNotificationAction in
            let identifier = "action:\(action.id)"
            if action.acceptsText {
                return UNTextInputNotificationAction(
                    identifier: identifier,
                    title: action.title,
                    options: [],
                    textInputButtonTitle: String(localized: "SEND"),
                    textInputPlaceholder: String(localized: "REPLY")
                )
            }
            return UNNotificationAction(identifier: identifier, title: action.title, options: [])
        } + [
            UNNotificationAction(
                identifier: MacNotificationResponseRouting.dismissActionID,
                title: String(localized: "DISMISS_NOTIFICATION"),
                options: [.destructive]
            ),
        ]
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        let content = UNMutableNotificationContent()
        content.title = notification.title.isEmpty ? notification.appLabel : notification.title
        content.subtitle = deviceName.isEmpty
            ? notification.appLabel
            : "\(notification.appLabel) • \(deviceName)"
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = categoryID
        content.threadIdentifier = Self.deviceThreadIdentifier(deviceID: deviceID)
        let attachment = iconStore.attachment(
            for: notification.appIconPNG,
            requestIdentifier: identifier
        )
        if let attachment {
            content.attachments = [attachment]
        }
        content.userInfo = [
            "deviceID": deviceID,
            "notificationID": notification.id,
            "packageName": notification.packageName,
            "appLabel": notification.appLabel,
        ]
        return PreparedPublication(
            deviceID: deviceID,
            packageName: notification.packageName,
            fingerprint: fingerprint,
            category: category,
            request: UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
            hasIconAttachment: attachment != nil,
            onAccepted: onAccepted
        )
    }

    private func submit(identifier: String, generation: UInt64, publication: PreparedPublication) {
        let completionGate = SubmissionCompletionGate()
        lock.lock()
        guard inFlight[identifier]?.generation == generation else {
            lock.unlock()
            return
        }
        categories[publication.category.identifier] = publication.category
        center.setNotificationCategories(Set(categories.values))
        center.add(publication.request) { [weak self, completionGate] error in
            guard completionGate.shouldDeliverAfterReturn(error) else { return }
            self?.completeSubmission(identifier: identifier, generation: generation, error: error)
        }
        let synchronousCompletion = completionGate.markAddReturned()
        lock.unlock()
        if let synchronousCompletion {
            completeSubmission(
                identifier: identifier,
                generation: generation,
                error: synchronousCompletion
            )
        }
    }

    private func completeSubmission(identifier: String, generation: UInt64, error: Error?) {
        var outcome: MacNotificationSubmissionResult?
        var nextSubmission: (UInt64, PreparedPublication)?
        let resultHandler: (@Sendable (MacNotificationSubmissionResult) -> Void)?

        lock.lock()
        guard let completed = inFlight[identifier], completed.generation == generation else {
            lock.unlock()
            return
        }
        if completed.disposition == .removalPending {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            categories.removeValue(forKey: completed.current.category.identifier)
            center.setNotificationCategories(Set(categories.values))
        } else if error == nil {
            metadata[identifier] = Metadata(
                deviceID: completed.current.deviceID,
                packageName: completed.current.packageName,
                fingerprint: completed.current.fingerprint,
                category: completed.current.category
            )
            outcome = .accepted
        } else if let error {
            outcome = .failed(.init(error: error))
        }

        if let desired = completed.desired {
            let nextGeneration = makeSubmissionGenerationLocked()
            inFlight[identifier] = InFlightPublication(
                generation: nextGeneration,
                current: desired,
                desired: nil,
                disposition: .active
            )
            nextSubmission = (nextGeneration, desired)
        } else {
            inFlight.removeValue(forKey: identifier)
            if let accepted = metadata[identifier] {
                categories[accepted.category.identifier] = accepted.category
            } else {
                categories.removeValue(forKey: completed.current.category.identifier)
            }
            center.setNotificationCategories(Set(categories.values))
        }
        resultHandler = submissionResultHandler
        lock.unlock()

        if let outcome { resultHandler?(outcome) }
        if outcome == .accepted { completed.current.onAccepted?() }
        if error == nil, completed.disposition == .active {
            auditNativeDelivery(publication: completed.current)
        }
        if let nextSubmission {
            submit(
                identifier: identifier,
                generation: nextSubmission.0,
                publication: nextSubmission.1
            )
        }
    }

    private func makeSubmissionGenerationLocked() -> UInt64 {
        nextSubmissionGeneration &+= 1
        return nextSubmissionGeneration
    }

    private func auditNativeDelivery(publication: PreparedPublication) {
        guard qaDiagnosticsEnabled else { return }
        let requestID = Self.qaRequestID(publication.request.identifier)
        qaDiagnosticSink(
            "GB_NOTIFICATION_QA submitted request=\(requestID) icon=\(publication.hasIconAttachment ? 1 : 0)"
        )
        let center = center
        let sink = qaDiagnosticSink
        let identifier = publication.request.identifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + qaDeliveryAuditDelay) {
            center.getDeliveredNotifications { notifications in
                let delivered = notifications.contains { $0.request.identifier == identifier }
                sink("GB_NOTIFICATION_QA delivered request=\(requestID) value=\(delivered ? 1 : 0)")
            }
        }
    }

    private static func qaRequestID(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func auditNativeRemoval(identifier: String) {
        guard qaDiagnosticsEnabled else { return }
        let requestID = Self.qaRequestID(identifier)
        qaDiagnosticSink("GB_NOTIFICATION_QA removal-requested request=\(requestID)")
        let center = center
        let sink = qaDiagnosticSink
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + qaDeliveryAuditDelay) {
            center.getDeliveredNotifications { notifications in
                let remainsDelivered = notifications.contains { $0.request.identifier == identifier }
                sink("GB_NOTIFICATION_QA removed request=\(requestID) value=\(remainsDelivered ? 0 : 1)")
            }
        }
    }

    func remove(deviceID: String, notificationID: String) {
        let identifier = Self.identifier(deviceID: deviceID, notificationID: notificationID)
        lock.lock()
        pending.removeValue(forKey: identifier)
        if var existing = inFlight[identifier] {
            existing.desired = nil
            existing.disposition = .removalPending
            inFlight[identifier] = existing
        }
        if let removed = metadata.removeValue(forKey: identifier) {
            categories.removeValue(forKey: removed.category.identifier)
        } else {
            categories.removeValue(forKey: "galaxybridge.\(identifier)")
        }
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.setNotificationCategories(Set(categories.values))
        lock.unlock()
        auditNativeRemoval(identifier: identifier)
    }

    func remove(deviceID: String, packageName: String) {
        lock.lock()
        let pendingIdentifiers = pending.compactMap { key, value in
            value.deviceID == deviceID && value.notification.packageName == packageName ? key : nil
        }
        for identifier in pendingIdentifiers { pending.removeValue(forKey: identifier) }
        let inFlightIdentifiers = inFlight.compactMap { key, value in
            value.current.deviceID == deviceID && value.current.packageName == packageName ? key : nil
        }
        for identifier in inFlightIdentifiers {
            guard var existing = inFlight[identifier] else { continue }
            existing.desired = nil
            existing.disposition = .removalPending
            inFlight[identifier] = existing
        }
        let identifiers = metadata.compactMap { key, value in
            value.deviceID == deviceID && value.packageName == packageName ? key : nil
        }
        for identifier in identifiers {
            if let removed = metadata.removeValue(forKey: identifier) {
                categories.removeValue(forKey: removed.category.identifier)
            }
        }
        let allIdentifiers = Array(Set(identifiers + inFlightIdentifiers))
        for identifier in inFlightIdentifiers where metadata[identifier] == nil {
            categories.removeValue(forKey: "galaxybridge.\(identifier)")
        }
        center.setNotificationCategories(Set(categories.values))
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: allIdentifiers)
        lock.unlock()
    }

    private static func identifier(deviceID: String, notificationID: String) -> String {
        Data("\(deviceID)\u{0}\(notificationID)".utf8).base64EncodedString()
    }

    private func transitionAuthorization(to state: MacNotificationAuthorizationState) {
        let transition = lock.withLock { () -> (
            (@Sendable (MacNotificationAuthorizationState) -> Void)?,
            [PendingPublication]
        ) in
            storedAuthorizationState = state
            let deferred: [PendingPublication]
            switch state {
            case .authorized:
                deferred = Array(pending.values)
                pending.removeAll()
            case .denied, .failed:
                pending.removeAll()
                deferred = []
            case .unknown, .requesting:
                deferred = []
            }
            return (authorizationStateHandler, deferred)
        }
        transition.0?(state)
        for publication in transition.1 {
            publish(
                deviceID: publication.deviceID,
                deviceName: publication.deviceName,
                notification: publication.notification,
                mutedPackages: publication.mutedPackages,
                onAccepted: publication.onAccepted
            )
        }
    }

    private static func deviceThreadIdentifier(deviceID: String) -> String {
        let digest = SHA256.hash(data: Data(deviceID.utf8)).prefix(12)
        return "galaxybridge.device." + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(deviceName: String, notification: BridgeNotificationRow) -> Data {
        var hasher = SHA256()
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        append(deviceName)
        append(notification.packageName)
        append(notification.appLabel)
        append(notification.title)
        append(notification.body)
        for action in notification.actions.prefix(3) {
            append(action.id)
            append(action.title)
            append(action.acceptsText ? "1" : "0")
        }
        if let icon = notification.appIconPNG { hasher.update(data: icon) }
        return Data(hasher.finalize())
    }
}

extension MacNotificationBridge: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        guard let routed = MacNotificationResponseRouting.resolve(
            actionIdentifier: response.actionIdentifier,
            reply: reply,
            userInfo: response.notification.request.content.userInfo
        ) else { return }
        responseHandler?(routed)
    }
}
