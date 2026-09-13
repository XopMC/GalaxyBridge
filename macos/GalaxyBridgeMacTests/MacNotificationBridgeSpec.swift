import Foundation
import UserNotifications

@main
enum MacNotificationBridgeSpec {
    static func main() throws {
        try expect(
            !MacNotificationReplayPolicy.shouldPublishNative(isInitialSnapshot: true, removed: false),
            "the initial Android snapshot restores in-app history without flooding Notification Center"
        )
        try expect(
            MacNotificationReplayPolicy.shouldPublishNative(isInitialSnapshot: false, removed: false),
            "a newly posted Android notification reaches Notification Center"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("galaxybridge-notification-spec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let center = RecordingNotificationCenter()
        let bridge = MacNotificationBridge(
            center: center,
            iconStore: MacNotificationIconAttachmentStore(directoryURL: directory)
        )
        let authorizationStates = AuthorizationStateRecorder()
        bridge.authorizationStateHandler = { authorizationStates.append($0) }
        bridge.requestAuthorization()
        try expectEqual(center.authorizationRequests, 1, "authorization is requested through the native center")
        try expectEqual(authorizationStates.values, [.requesting], "authorization starts in an actionable requesting state")
        center.resolveAuthorization(granted: true)
        try expectEqual(
            authorizationStates.values,
            [.requesting, .authorized],
            "granted macOS notification permission is surfaced"
        )

        let deniedCenter = RecordingNotificationCenter()
        let deniedBridge = MacNotificationBridge(
            center: deniedCenter,
            iconStore: MacNotificationIconAttachmentStore(directoryURL: directory)
        )
        let deniedStates = AuthorizationStateRecorder()
        deniedBridge.authorizationStateHandler = { deniedStates.append($0) }
        deniedBridge.requestAuthorization()
        deniedCenter.resolveAuthorization(granted: false)
        try expectEqual(
            deniedStates.values,
            [.requesting, .denied],
            "a denied macOS notification permission is surfaced instead of silently dropping banners"
        )
        let icon = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let attachmentStore = MacNotificationIconAttachmentStore(directoryURL: directory)
        let firstIconAttachment = try require(
            attachmentStore.attachment(for: icon, requestIdentifier: "request-one"),
            "first independently staged source icon"
        )
        let secondIconAttachment = try require(
            attachmentStore.attachment(for: icon, requestIdentifier: "request-two"),
            "second independently staged source icon"
        )
        try expect(
            firstIconAttachment.url != secondIconAttachment.url,
            "two notification requests using the same Android app icon must not share a consumable staging file"
        )
        try expect(
            FileManager.default.fileExists(atPath: firstIconAttachment.url.path)
                && FileManager.default.fileExists(atPath: secondIconAttachment.url.path),
            "both per-request icon staging files remain readable until the notification center consumes them"
        )
        let row = BridgeNotificationRow(
            id: "notification-1",
            packageName: "com.example.messages",
            appLabel: "Messages",
            title: "New message",
            body: "Private body",
            postedAt: Date(timeIntervalSince1970: 1_000),
            actions: [
                .init(id: "reply", title: "Reply", acceptsText: true),
                .init(id: "mark", title: "Mark read", acceptsText: false),
                .init(id: "mute", title: "Mute", acceptsText: false),
                .init(id: "ignored", title: "Ignored", acceptsText: false),
            ],
            appIconPNG: icon
        )

        let requestingCenter = RecordingNotificationCenter()
        let requestingBridge = MacNotificationBridge(
            center: requestingCenter,
            iconStore: MacNotificationIconAttachmentStore(directoryURL: directory)
        )
        requestingBridge.requestAuthorization()
        try expectEqual(
            requestingBridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: row,
                mutedPackages: []
            ),
            .deferred,
            "notifications arriving while authorization is unresolved are deferred"
        )
        try expectEqual(
            requestingCenter.requests.count,
            0,
            "unresolved authorization never submits a notification that macOS may silently discard"
        )
        let updatedPendingRow = BridgeNotificationRow(
            id: row.id,
            packageName: row.packageName,
            appLabel: row.appLabel,
            title: row.title,
            body: "Updated while permission was open",
            postedAt: row.postedAt,
            actions: row.actions,
            appIconPNG: row.appIconPNG
        )
        try expectEqual(
            requestingBridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: updatedPendingRow,
                mutedPackages: []
            ),
            .deferred,
            "a newer snapshot replaces the deferred value for the same Android notification"
        )
        requestingCenter.resolveAuthorization(granted: true)
        try expectEqual(
            requestingCenter.requests.count,
            1,
            "granting authorization drains the deferred notification exactly once"
        )
        try expectEqual(
            requestingCenter.requests.first?.content.body,
            updatedPendingRow.body,
            "deferred delivery uses the newest notification value"
        )
        try expectEqual(
            requestingBridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: updatedPendingRow,
                mutedPackages: []
            ),
            .deduplicated,
            "a drained notification records its fingerprint only after authorized delivery"
        )

        let pendingDeniedCenter = RecordingNotificationCenter()
        let pendingDeniedBridge = MacNotificationBridge(
            center: pendingDeniedCenter,
            iconStore: MacNotificationIconAttachmentStore(directoryURL: directory)
        )
        pendingDeniedBridge.requestAuthorization()
        try expectEqual(
            pendingDeniedBridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: row,
                mutedPackages: []
            ),
            .deferred,
            "a notification is deferred while a denial is still unresolved"
        )
        pendingDeniedCenter.resolveAuthorization(granted: false)
        try expectEqual(
            pendingDeniedCenter.requests.count,
            0,
            "denial clears deferred delivery without submitting a native request"
        )
        pendingDeniedBridge.requestAuthorization()
        pendingDeniedCenter.resolveAuthorization(granted: true)
        try expectEqual(
            pendingDeniedCenter.requests.count,
            0,
            "a later grant cannot resurrect notifications discarded by an earlier denial"
        )
        try expectEqual(
            deniedBridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: row,
                mutedPackages: []
            ),
            .permissionDenied,
            "delivery reports denied permission instead of pretending that a banner was published"
        )
        try expectEqual(deniedCenter.requests.count, 0, "denied delivery never submits a doomed native request")
        deniedCenter.currentAuthorizationState = .authorized
        deniedBridge.refreshAuthorizationStatus()
        try expectEqual(
            deniedStates.values,
            [.requesting, .denied, .authorized],
            "returning from System Settings refreshes a newly granted permission without relaunching the app"
        )
        try expectEqual(
            deniedBridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: row,
                mutedPackages: []
            ),
            .enqueued,
            "a permission refresh enables a real native submission attempt"
        )

        try expectEqual(
            bridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: row,
                mutedPackages: []
            ),
            .enqueued,
            "an allowed Android notification is enqueued with the system center"
        )
        try expectEqual(center.requests.count, 1, "one native notification request is added")
        let request = try require(center.requests.first, "native request")
        try expectEqual(request.content.title, "New message", "Android title reaches the native banner")
        try expectEqual(request.content.subtitle, "Messages • Galaxy S24 Ultra", "source app and Galaxy device badge are visible")
        try expectEqual(request.content.body, "Private body", "Android body reaches the native banner")
        try expect(!request.content.threadIdentifier.contains("device-private-id"), "thread IDs do not expose raw device identifiers")
        try expectEqual(request.content.attachments.count, 1, "valid source app icon is attached")
        let firstAttachmentURL = try require(request.content.attachments.first?.url, "source app attachment URL")
        try expect(FileManager.default.fileExists(atPath: firstAttachmentURL.path), "attachment remains readable when submitted")
        try expect(center.installedDelegate === bridge, "the real notification delegate is installed")

        let category = try require(
            center.categories.first(where: { $0.identifier == request.content.categoryIdentifier }),
            "registered category"
        )
        try expectEqual(category.actions.count, 4, "three Android actions plus dismiss are registered")
        try expect(category.actions[0] is UNTextInputNotificationAction, "inline reply uses native text input")
        try expectEqual(category.actions[0].identifier, "action:reply", "reply action identifier")
        try expectEqual(category.actions[1].identifier, "action:mark", "regular action identifier")
        try expectEqual(category.actions[3].identifier, MacNotificationResponseRouting.dismissActionID, "dismiss action identifier")

        try expectEqual(
            bridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: row,
                mutedPackages: []
            ),
            .deduplicated,
            "replayed LAN snapshot does not create a duplicate banner"
        )
        try expectEqual(center.requests.count, 1, "dedupe does not call the native center again")

        try expectEqual(
            bridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: row,
                mutedPackages: [row.packageName]
            ),
            .filtered,
            "per-app mute suppresses native delivery"
        )
        try expectEqual(center.requests.count, 1, "filtered app never reaches native delivery")
        try expectEqual(center.removedDelivered.last, [request.identifier], "muting removes an already delivered banner")

        let invalidIconRow = BridgeNotificationRow(
            id: "notification-2",
            packageName: "com.example.mail",
            appLabel: "Mail",
            title: "Mail",
            body: "Body",
            postedAt: Date(timeIntervalSince1970: 2_000),
            actions: [],
            appIconPNG: Data("not-a-png".utf8)
        )
        try expectEqual(
            bridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: invalidIconRow,
                mutedPackages: []
            ),
            .enqueued,
            "invalid icon falls back to a text notification"
        )
        try expectEqual(center.requests.last?.content.attachments.count, 0, "unsafe icon is never attached")

        // UNUserNotificationCenter may move/copy an attachment into its own store. Losing the
        // staging file must not prevent the next notification from attaching the same app icon.
        if let stagedFiles = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for stagedFile in stagedFiles { try? FileManager.default.removeItem(at: stagedFile) }
        }
        let restagedIconRow = BridgeNotificationRow(
            id: "notification-3",
            packageName: row.packageName,
            appLabel: row.appLabel,
            title: "Another message",
            body: "Another body",
            postedAt: Date(timeIntervalSince1970: 3_000),
            actions: [],
            appIconPNG: icon
        )
        try expectEqual(
            bridge.publish(
                deviceID: "device-private-id",
                deviceName: "Galaxy S24 Ultra",
                notification: restagedIconRow,
                mutedPackages: []
            ),
            .enqueued,
            "a source icon is safely restaged after the notification system consumes its previous file"
        )
        try expectEqual(center.requests.last?.content.attachments.count, 1, "restaged source icon remains attached")

        let userInfo: [AnyHashable: Any] = [
            "deviceID": "device-private-id",
            "notificationID": "notification-1",
            "packageName": "com.example.messages",
            "appLabel": "Messages",
        ]
        try expectEqual(
            MacNotificationResponseRouting.resolve(
                actionIdentifier: "action:reply",
                reply: "Thanks",
                userInfo: userInfo
            ),
            MacNotificationResponse(
                deviceID: "device-private-id",
                notificationID: "notification-1",
                actionID: "reply",
                reply: "Thanks",
                dismiss: false
            ),
            "inline reply routes back to the originating Android action"
        )
        try expectEqual(
            MacNotificationResponseRouting.resolve(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                reply: nil,
                userInfo: userInfo
            ),
            MacNotificationResponse(
                deviceID: "device-private-id",
                notificationID: "notification-1",
                actionID: "",
                reply: nil,
                dismiss: true
            ),
            "system dismiss routes back to Android"
        )
        try expectEqual(
            MacNotificationResponseRouting.resolve(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                reply: nil,
                userInfo: userInfo
            ),
            MacNotificationResponse(
                deviceID: "device-private-id",
                notificationID: "notification-1",
                actionID: "",
                reply: nil,
                dismiss: false,
                opensApplication: true,
                packageName: "com.example.messages",
                appLabel: "Messages"
            ),
            "opening a native banner routes to the corresponding Android app window"
        )
        try expect(
            MacNotificationResponseRouting.resolve(
                actionIdentifier: "action:reply",
                reply: "secret",
                userInfo: [:]
            ) == nil,
            "responses without trusted routing metadata are ignored"
        )

        try verifyAcceptedCompletion(directory: directory, row: row)
        try verifyFailedSubmissionCanRetry(directory: directory, row: row)
        try verifyDuplicatePendingSubmission(directory: directory, row: row)
        try verifyLatestReplacementWins(directory: directory, row: row)
        try verifyIntentReversions(directory: directory, row: row)
        try verifyAcceptedStateSurvivesFailedReplacement(directory: directory, row: row)
        try verifyRemovalAndFilterInvalidatePendingCompletion(directory: directory, row: row)
        try verifyOldCompletionCannotClearReplacement(directory: directory, row: row)
        try verifyDevicesHaveIndependentSubmissionState(directory: directory, row: row)
        try verifyAcceptanceReceiptsRequireActualSubmission(directory: directory, row: row)
        try verifyDeferredAcceptanceReceipts(directory: directory, row: row)

        print("PASS Mac notifications surface native submission completion with serialized dedupe, replacement, removal, filters, and retry")
    }

    private static func verifyAcceptedCompletion(directory: URL, row: BridgeNotificationRow) throws {
        let (center, bridge, outcomes) = authorizedControlledBridge(directory: directory)
        try expectEqual(
            bridge.publish(deviceID: "accepted-device", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .enqueued,
            "submission is only enqueued before the native completion"
        )
        try expectEqual(outcomes.values, [], "enqueue does not claim native acceptance")
        center.completeSubmission(at: 0)
        try expectEqual(outcomes.values, [.accepted], "a successful native completion is surfaced as accepted")
        try expectEqual(
            bridge.publish(deviceID: "accepted-device", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .deduplicated,
            "an accepted fingerprint deduplicates a later replay"
        )
    }

    private static func verifyFailedSubmissionCanRetry(directory: URL, row: BridgeNotificationRow) throws {
        let (center, bridge, outcomes) = authorizedControlledBridge(directory: directory)
        try expectEqual(
            bridge.publish(deviceID: "retry-device", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .enqueued,
            "the first retry fixture is enqueued"
        )
        center.completeSubmission(
            at: 0,
            error: NSError(
                domain: NSCocoaErrorDomain,
                code: 4_097,
                userInfo: [NSLocalizedDescriptionKey: "Private body must never escape"]
            )
        )
        try expectEqual(
            outcomes.values,
            [.failed(.init(category: .cocoa, domain: NSCocoaErrorDomain, code: 4_097))],
            "native failure exposes bounded category, domain, and code only"
        )
        guard case let .failed(failure) = outcomes.values.first else {
            throw SpecFailure(message: "missing structured native submission failure")
        }
        try expectEqual(
            failure.diagnosticDetail,
            "macOS error 4097 (NSCocoaErrorDomain)",
            "submission failure has content-free human-readable diagnostic text"
        )
        try expectEqual(
            bridge.publish(deviceID: "retry-device", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .enqueued,
            "a failed fingerprint is eligible for an explicit retry"
        )
        try expectEqual(center.requests.count, 2, "failure does not suppress the retry request")
        center.completeSubmission(at: 1)
        try expectEqual(outcomes.values.last, .accepted, "the explicit retry may be accepted")
    }

    private static func verifyDuplicatePendingSubmission(directory: URL, row: BridgeNotificationRow) throws {
        let (center, bridge, _) = authorizedControlledBridge(directory: directory)
        try expectEqual(
            bridge.publish(deviceID: "pending-device", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .enqueued,
            "the pending fixture is enqueued"
        )
        try expectEqual(
            bridge.publish(deviceID: "pending-device", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .deduplicated,
            "an identical in-flight publication is deduplicated"
        )
        try expectEqual(center.requests.count, 1, "pending dedupe never reaches the native client twice")
    }

    private static func verifyLatestReplacementWins(directory: URL, row: BridgeNotificationRow) throws {
        let (center, bridge, _) = authorizedControlledBridge(directory: directory)
        let second = replacing(row, body: "second body")
        let latest = replacing(row, body: "latest body")
        try expectEqual(
            bridge.publish(deviceID: "replace-device", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .enqueued,
            "the original replacement fixture is enqueued"
        )
        try expectEqual(
            bridge.publish(deviceID: "replace-device", deviceName: "Galaxy", notification: second, mutedPackages: []),
            .enqueued,
            "a replacement is retained while the original is in flight"
        )
        try expectEqual(
            bridge.publish(deviceID: "replace-device", deviceName: "Galaxy", notification: latest, mutedPackages: []),
            .enqueued,
            "the latest desired replacement supersedes the older replacement"
        )
        try expectEqual(center.requests.count, 1, "replacements do not create a concurrent callback queue")
        center.completeSubmission(at: 0)
        try expectEqual(center.requests.count, 2, "completion submits exactly one retained replacement")
        try expectEqual(center.requests[1].content.body, "latest body", "only the latest desired content is submitted")
        center.completeSubmission(at: 1)
        try expectEqual(
            bridge.publish(deviceID: "replace-device", deviceName: "Galaxy", notification: latest, mutedPackages: []),
            .deduplicated,
            "only the accepted latest replacement becomes the fingerprint"
        )
    }

    private static func verifyIntentReversions(directory: URL, row: BridgeNotificationRow) throws {
        let (pendingCenter, pendingBridge, _) = authorizedControlledBridge(directory: directory)
        let pendingReplacement = replacing(row, body: "pending replacement")
        _ = pendingBridge.publish(
            deviceID: "pending-reversion-device",
            deviceName: "Galaxy",
            notification: row,
            mutedPackages: []
        )
        _ = pendingBridge.publish(
            deviceID: "pending-reversion-device",
            deviceName: "Galaxy",
            notification: pendingReplacement,
            mutedPackages: []
        )
        try expectEqual(
            pendingBridge.publish(
                deviceID: "pending-reversion-device",
                deviceName: "Galaxy",
                notification: row,
                mutedPackages: []
            ),
            .deduplicated,
            "reverting to the in-flight content cancels an older desired replacement"
        )
        pendingCenter.completeSubmission(at: 0)
        try expectEqual(
            pendingCenter.requests.count,
            1,
            "an obsolete desired replacement is not replayed after accepting the reverted content"
        )

        let (acceptedCenter, acceptedBridge, _) = authorizedControlledBridge(directory: directory)
        acceptedCenter.completeSubmissionsSynchronously = true
        _ = acceptedBridge.publish(
            deviceID: "accepted-reversion-device",
            deviceName: "Galaxy",
            notification: row,
            mutedPackages: []
        )
        acceptedCenter.completeSubmissionsSynchronously = false
        let acceptedReplacement = replacing(row, body: "accepted replacement")
        _ = acceptedBridge.publish(
            deviceID: "accepted-reversion-device",
            deviceName: "Galaxy",
            notification: acceptedReplacement,
            mutedPackages: []
        )
        try expectEqual(
            acceptedBridge.publish(
                deviceID: "accepted-reversion-device",
                deviceName: "Galaxy",
                notification: row,
                mutedPackages: []
            ),
            .enqueued,
            "reverting to accepted content while its replacement is in flight records the latest intent"
        )
        acceptedCenter.completeSubmission(at: 1)
        try expectEqual(acceptedCenter.requests.count, 3, "accepted-content reversion submits after the replacement settles")
        try expectEqual(acceptedCenter.requests[2].content.body, row.body, "accepted-content reversion restores the latest body")
    }

    private static func verifyAcceptedStateSurvivesFailedReplacement(
        directory: URL,
        row: BridgeNotificationRow
    ) throws {
        let (center, bridge, outcomes) = authorizedControlledBridge(directory: directory)
        let replacement = BridgeNotificationRow(
            id: row.id,
            packageName: row.packageName,
            appLabel: row.appLabel,
            title: row.title,
            body: "replacement that fails",
            postedAt: row.postedAt,
            actions: [.init(id: "archive", title: "Archive", acceptsText: false)],
            appIconPNG: row.appIconPNG
        )
        _ = bridge.publish(deviceID: "restore-device", deviceName: "Galaxy", notification: row, mutedPackages: [])
        _ = bridge.publish(
            deviceID: "restore-device",
            deviceName: "Galaxy",
            notification: replacement,
            mutedPackages: []
        )
        center.completeSubmission(at: 0)
        center.completeSubmission(at: 1, error: NSError(domain: NSCocoaErrorDomain, code: 4_097))
        try expectEqual(
            outcomes.values,
            [.accepted, .failed(.init(category: .cocoa, domain: NSCocoaErrorDomain, code: 4_097))],
            "each settled current submission reports its real native outcome"
        )
        try expectEqual(center.installedRequests.count, 1, "a failed replacement leaves the accepted request installed")
        try expectEqual(
            center.installedRequests.values.first?.content.body,
            row.body,
            "the accepted body remains installed after replacement failure"
        )
        let restoredCategory = try require(
            center.categories.first,
            "accepted category restored after replacement failure"
        )
        try expectEqual(
            restoredCategory.actions.first?.identifier,
            "action:reply",
            "replacement failure restores the accepted action category"
        )
        try expectEqual(
            bridge.publish(deviceID: "restore-device", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .deduplicated,
            "the successful current completion commits its fingerprint before the replacement runs"
        )
    }

    private static func verifyRemovalAndFilterInvalidatePendingCompletion(
        directory: URL,
        row: BridgeNotificationRow
    ) throws {
        let (removedCenter, removedBridge, removedOutcomes) = authorizedControlledBridge(directory: directory)
        _ = removedBridge.publish(
            deviceID: "removed-device",
            deviceName: "Galaxy",
            notification: row,
            mutedPackages: []
        )
        removedBridge.remove(deviceID: "removed-device", notificationID: row.id)
        let removedReplacement = replacing(row, body: "republished after removal")
        try expectEqual(
            removedBridge.publish(
                deviceID: "removed-device",
                deviceName: "Galaxy",
                notification: removedReplacement,
                mutedPackages: []
            ),
            .enqueued,
            "republish after removal records the latest desired content"
        )
        try expectEqual(removedCenter.requests.count, 1, "republish waits for the removed native add to settle")
        removedCenter.completeSubmission(at: 0)
        try expectEqual(removedOutcomes.values, [], "a removed stale completion cannot report acceptance")
        try expectEqual(removedCenter.installedRequests.count, 0, "completion-time installation is correctively removed")
        try expectEqual(removedCenter.requests.count, 2, "latest desired content submits after corrective removal")
        removedCenter.completeSubmission(at: 1)
        let removedIdentifier = removedCenter.requests[1].identifier
        try expectEqual(
            removedCenter.installedRequests[removedIdentifier]?.content.body,
            removedReplacement.body,
            "the republished content installs only after the removed add settles"
        )
        removedCenter.completeSubmission(at: 0, error: NSError(domain: NSCocoaErrorDomain, code: 77))
        try expectEqual(
            removedCenter.installedRequests[removedIdentifier]?.content.body,
            removedReplacement.body,
            "a repeated old callback cannot remove or overwrite the accepted republish"
        )

        let (filteredCenter, filteredBridge, filteredOutcomes) = authorizedControlledBridge(directory: directory)
        _ = filteredBridge.publish(
            deviceID: "filtered-device",
            deviceName: "Galaxy",
            notification: row,
            mutedPackages: []
        )
        try expectEqual(
            filteredBridge.publish(
                deviceID: "filtered-device",
                deviceName: "Galaxy",
                notification: row,
                mutedPackages: [row.packageName]
            ),
            .filtered,
            "filtering removes an in-flight publication"
        )
        let unfilteredReplacement = replacing(row, body: "unfiltered latest")
        try expectEqual(
            filteredBridge.publish(
                deviceID: "filtered-device",
                deviceName: "Galaxy",
                notification: unfilteredReplacement,
                mutedPackages: []
            ),
            .enqueued,
            "unfiltering records one latest desired publication behind the tombstone"
        )
        try expectEqual(filteredCenter.requests.count, 1, "filter-unfilter does not create concurrent native adds")
        filteredCenter.completeSubmission(at: 0)
        try expectEqual(filteredOutcomes.values, [], "a filtered stale completion cannot report acceptance")
        try expectEqual(filteredCenter.installedRequests.count, 0, "filtered completion-time install is removed")
        try expectEqual(filteredCenter.requests.count, 2, "unfiltered latest publication submits after cleanup")
        filteredCenter.completeSubmission(at: 1)
        try expectEqual(
            filteredCenter.installedRequests.values.first?.content.body,
            unfilteredReplacement.body,
            "only unfiltered latest content remains installed"
        )
    }

    private static func verifyOldCompletionCannotClearReplacement(directory: URL, row: BridgeNotificationRow) throws {
        let (center, bridge, outcomes) = authorizedControlledBridge(directory: directory)
        let replacement = replacing(row, body: "replacement body")
        _ = bridge.publish(deviceID: "stale-device", deviceName: "Galaxy", notification: row, mutedPackages: [])
        _ = bridge.publish(
            deviceID: "stale-device",
            deviceName: "Galaxy",
            notification: replacement,
            mutedPackages: []
        )
        center.completeSubmission(at: 0)
        center.completeSubmission(at: 1)
        center.completeSubmission(at: 0, error: NSError(domain: NSCocoaErrorDomain, code: 77))
        try expectEqual(outcomes.values, [.accepted, .accepted], "a repeated old completion is ignored")
        try expectEqual(
            bridge.publish(
                deviceID: "stale-device",
                deviceName: "Galaxy",
                notification: replacement,
                mutedPackages: []
            ),
            .deduplicated,
            "an old completion cannot clear newer accepted metadata"
        )
    }

    private static func verifyDevicesHaveIndependentSubmissionState(directory: URL, row: BridgeNotificationRow) throws {
        let (center, bridge, _) = authorizedControlledBridge(directory: directory)
        _ = bridge.publish(deviceID: "device-one", deviceName: "Galaxy", notification: row, mutedPackages: [])
        _ = bridge.publish(deviceID: "device-two", deviceName: "Galaxy", notification: row, mutedPackages: [])
        try expectEqual(center.requests.count, 2, "the same Android notification ID is independent per device")
        center.completeSubmission(at: 1)
        center.completeSubmission(at: 0, error: NSError(domain: NSPOSIXErrorDomain, code: 5))
        try expectEqual(
            bridge.publish(deviceID: "device-two", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .deduplicated,
            "acceptance on one device remains deduplicated"
        )
        try expectEqual(
            bridge.publish(deviceID: "device-one", deviceName: "Galaxy", notification: row, mutedPackages: []),
            .enqueued,
            "failure on another device remains independently retryable"
        )
    }

    private static func verifyAcceptanceReceiptsRequireActualSubmission(directory: URL, row: BridgeNotificationRow) throws {
        let (center, bridge, _) = authorizedControlledBridge(directory: directory)
        let receipts = AcceptanceReceiptRecorder()
        try expectEqual(bridge.publish(deviceID: "receipt-device", deviceName: "Galaxy", notification: row,
                                       mutedPackages: [], onAccepted: { receipts.append("first") }), .enqueued,
                        "receipt-bearing publication is only enqueued before native completion")
        try expectEqual(receipts.values, [], "enqueue and granted permission cannot deliver live evidence")
        try expectEqual(bridge.publish(deviceID: "receipt-device", deviceName: "Galaxy", notification: row,
                                       mutedPackages: [], onAccepted: { receipts.append("duplicate-in-flight") }), .deduplicated,
                        "an in-flight duplicate cannot acquire another receipt")
        center.completeSubmission(at: 0)
        try expectEqual(receipts.values, ["first"], "only the actual accepted publication delivers its captured receipt")
        center.completeSubmission(at: 0)
        try expectEqual(receipts.values, ["first"], "a repeated native callback cannot deliver twice")
        _ = bridge.publish(deviceID: "receipt-device", deviceName: "Galaxy", notification: row,
                           mutedPackages: [], onAccepted: { receipts.append("duplicate-accepted") })
        try expectEqual(receipts.values, ["first"], "deduplication against history cannot verify a new attempt")

        let failed = replacing(row, body: "fails native acceptance")
        _ = bridge.publish(deviceID: "receipt-device", deviceName: "Galaxy", notification: failed,
                           mutedPackages: [], onAccepted: { receipts.append("failed") })
        center.completeSubmission(at: 1, error: NSError(domain: NSPOSIXErrorDomain, code: 5))
        center.completeSubmission(at: 1)
        try expectEqual(receipts.values, ["first"], "failure and its repeated callback cannot become a receipt")

        let removed = replacing(row, body: "removed while native add is pending")
        _ = bridge.publish(deviceID: "receipt-device", deviceName: "Galaxy", notification: removed,
                           mutedPackages: [], onAccepted: { receipts.append("removed") })
        bridge.remove(deviceID: "receipt-device", notificationID: row.id)
        center.completeSubmission(at: 2)
        try expectEqual(receipts.values, ["first"], "a removed publication cannot acknowledge a later native success")

        _ = bridge.publish(deviceID: "receipt-device", deviceName: "Galaxy", notification: row,
                           mutedPackages: [], onAccepted: { receipts.append("filtered-in-flight") })
        _ = bridge.publish(deviceID: "receipt-device", deviceName: "Galaxy", notification: row,
                           mutedPackages: [row.packageName], onAccepted: { receipts.append("filtered") })
        center.completeSubmission(at: 3)
        try expectEqual(receipts.values, ["first"], "a filter/removal never supplies native acceptance evidence")

        // Synchronous system completion is also a real acceptance, but the
        // callback must run after the bridge releases its internal lock.
        center.completeSubmissionsSynchronously = true
        _ = bridge.publish(deviceID: "synchronous-receipt", deviceName: "Galaxy", notification: row,
                           mutedPackages: [], onAccepted: {
                               _ = bridge.authorizationState
                               receipts.append("synchronous")
                           })
        try expectEqual(receipts.values, ["first", "synchronous"], "synchronous native acceptance releases exactly one callback without lock reentrancy")
    }

    private static func verifyDeferredAcceptanceReceipts(directory: URL, row: BridgeNotificationRow) throws {
        let center = RecordingNotificationCenter(completesSubmissionsSynchronously: false)
        let bridge = MacNotificationBridge(center: center, iconStore: MacNotificationIconAttachmentStore(directoryURL: directory))
        let receipts = AcceptanceReceiptRecorder()
        bridge.requestAuthorization()
        _ = bridge.publish(deviceID: "deferred-receipt", deviceName: "Galaxy", notification: row,
                           mutedPackages: [], onAccepted: { receipts.append("superseded") })
        _ = bridge.publish(deviceID: "deferred-receipt", deviceName: "Galaxy", notification: replacing(row, body: "latest deferred"),
                           mutedPackages: [], onAccepted: { receipts.append("latest") })
        try expectEqual(receipts.values, [], "deferral cannot verify a feature")
        center.resolveAuthorization(granted: true)
        try expectEqual(center.requests.count, 1, "grant submits only the latest deferred value")
        try expectEqual(receipts.values, [], "authorization grant alone cannot verify native notification delivery")
        center.completeSubmission(at: 0)
        try expectEqual(receipts.values, ["latest"], "deferred submission preserves only its latest exact acceptance receipt")

        bridge.requestAuthorization()
        _ = bridge.publish(deviceID: "denied-receipt", deviceName: "Galaxy", notification: row,
                           mutedPackages: [], onAccepted: { receipts.append("denied") })
        center.resolveAuthorization(granted: false)
        bridge.requestAuthorization()
        center.resolveAuthorization(granted: true)
        try expectEqual(center.requests.count, 1, "denied deferred notification is not resurrected by later permission")
        try expectEqual(receipts.values, ["latest"], "denial and later grant produce no receipt")
    }

    private static func authorizedControlledBridge(
        directory: URL
    ) -> (RecordingNotificationCenter, MacNotificationBridge, SubmissionResultRecorder) {
        let center = RecordingNotificationCenter(completesSubmissionsSynchronously: false)
        let bridge = MacNotificationBridge(
            center: center,
            iconStore: MacNotificationIconAttachmentStore(directoryURL: directory)
        )
        let outcomes = SubmissionResultRecorder()
        bridge.submissionResultHandler = { outcomes.append($0) }
        bridge.requestAuthorization()
        center.resolveAuthorization(granted: true)
        return (center, bridge, outcomes)
    }

    private static func replacing(_ row: BridgeNotificationRow, body: String) -> BridgeNotificationRow {
        BridgeNotificationRow(
            id: row.id,
            packageName: row.packageName,
            appLabel: row.appLabel,
            title: row.title,
            body: body,
            postedAt: row.postedAt,
            actions: row.actions,
            appIconPNG: row.appIconPNG
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message: message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else {
            throw SpecFailure(message: "\(message): expected \(expected), got \(actual)")
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SpecFailure(message: "missing \(message)") }
        return value
    }
}

private final class AcceptanceReceiptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class RecordingNotificationCenter: MacNotificationCenterClient, @unchecked Sendable {
    weak var installedDelegate: (any UNUserNotificationCenterDelegate)?
    var authorizationRequests = 0
    var categories = Set<UNNotificationCategory>()
    var requests: [UNNotificationRequest] = []
    var removedPending: [[String]] = []
    var removedDelivered: [[String]] = []
    var installedRequests: [String: UNNotificationRequest] = [:]
    private var authorizationCompletions: [@Sendable (Bool, Error?) -> Void] = []
    private var submissionCompletions: [@Sendable (Error?) -> Void] = []
    private var completedSubmissionIndices = Set<Int>()
    var currentAuthorizationState: MacNotificationAuthorizationState = .unknown
    var completeSubmissionsSynchronously: Bool

    init(completesSubmissionsSynchronously: Bool = true) {
        completeSubmissionsSynchronously = completesSubmissionsSynchronously
    }

    func install(delegate: any UNUserNotificationCenterDelegate) {
        installedDelegate = delegate
    }

    func requestAuthorization(completion: @escaping @Sendable (Bool, Error?) -> Void) {
        authorizationRequests += 1
        authorizationCompletions.append(completion)
    }

    func resolveAuthorization(granted: Bool, error: Error? = nil) {
        authorizationCompletions.removeFirst()(granted, error)
    }

    func getAuthorizationState(
        completion: @escaping @Sendable (MacNotificationAuthorizationState) -> Void
    ) {
        completion(currentAuthorizationState)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func add(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void) {
        requests.append(request)
        submissionCompletions.append(completion)
        if completeSubmissionsSynchronously {
            installedRequests[request.identifier] = request
            completedSubmissionIndices.insert(submissionCompletions.count - 1)
            completion(nil)
        }
    }

    func getDeliveredNotifications(completion: @escaping @Sendable ([UNNotification]) -> Void) {
        completion([])
    }

    func completeSubmission(at index: Int, error: Error? = nil) {
        if error == nil, completedSubmissionIndices.insert(index).inserted {
            let request = requests[index]
            installedRequests[request.identifier] = request
        }
        submissionCompletions[index](error)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPending.append(identifiers)
        for identifier in identifiers { installedRequests.removeValue(forKey: identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(identifiers)
        for identifier in identifiers { installedRequests.removeValue(forKey: identifier) }
    }
}

private final class SubmissionResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MacNotificationSubmissionResult] = []

    var values: [MacNotificationSubmissionResult] {
        lock.withLock { storage }
    }

    func append(_ result: MacNotificationSubmissionResult) {
        lock.withLock { storage.append(result) }
    }
}

private final class AuthorizationStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MacNotificationAuthorizationState] = []

    var values: [MacNotificationAuthorizationState] {
        lock.withLock { storage }
    }

    func append(_ state: MacNotificationAuthorizationState) {
        lock.withLock { storage.append(state) }
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
