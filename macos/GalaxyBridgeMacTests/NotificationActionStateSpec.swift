import Foundation

@main
enum NotificationActionStateSpec {
    static func main() {
        let key = NotificationActionIdentity(deviceID: "phone", notificationID: "synthetic", actionID: "0")
        let text = "Galaxy Bridge QA — ответ42"
        var state = NotificationActionState()
        state.setDraft(text, for: key)
        let request = "69830b65-6352-4b3a-8a21-70bcda45787e"
        precondition(state.begin(identity: key, companionID: "route", generation: 4, requestID: request, draft: text, supportsResults: true) != nil)
        precondition(state.entry(key).draft == text, "Enqueue must retain draft")
        precondition(state.begin(identity: key, companionID: "route", generation: 4, requestID: "double", draft: text, supportsResults: true) == nil)
        precondition(!state.resolve(requestID: request, notificationID: "synthetic", actionID: "0", companionID: "route", generation: 3, accepted: true, errorCode: ""))
        precondition(!state.resolve(requestID: request, notificationID: "wrong", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(!state.resolve(requestID: request, notificationID: "synthetic", actionID: "wrong", companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(!state.resolve(requestID: request, notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: "contradictory"))
        precondition(!state.resolve(requestID: request, notificationID: "synthetic", actionID: "0", companionID: "other", generation: 4, accepted: true, errorCode: ""))
        precondition(state.resolve(requestID: request, notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(state.entry(key).draft.isEmpty && state.entry(key).phase == .accepted)
        precondition(!state.resolve(requestID: request, notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: ""))

        func begin(_ id: String) {
            precondition(state.begin(identity: key, companionID: "route", generation: 4, requestID: id, draft: text, supportsResults: true) != nil)
        }
        begin("error")
        precondition(state.resolve(requestID: "error", notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: false, errorCode: "pending_intent_canceled"))
        precondition(state.entry(key).draft == text && state.entry(key).phase == .failed)
        begin("timeout")
        precondition(state.fail(requestID: "timeout", unknown: true))
        precondition(state.entry(key).draft == text && state.entry(key).phase == .unknown)
        precondition(!state.resolve(requestID: "timeout", notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: ""), "Late result cannot erase unknown-outcome draft")
        begin("edit")
        state.setDraft("newer draft", for: key)
        precondition(state.resolve(requestID: "edit", notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(state.entry(key).draft == "newer draft")
        begin("edit-return")
        state.setDraft("intermediate draft", for: key)
        state.setDraft(text, for: key)
        precondition(state.resolve(requestID: "edit-return", notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(state.entry(key).draft == text, "A→B→A is a new draft even when its text matches the submitted draft")
        let revision = state.entry(key).draftRevision
        begin("same-value-binding")
        state.setDraft(text, for: key)
        precondition(state.entry(key).draftRevision == revision, "A redundant SwiftUI binding write is not an edit")
        precondition(state.resolve(requestID: "same-value-binding", notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(state.entry(key).draft.isEmpty, "An unchanged submitted revision should still clear")
        begin("disconnect")
        precondition(state.disconnect(companionID: "route", generation: 3).isEmpty)
        precondition(state.disconnect(companionID: "route", generation: 4) == ["disconnect"])
        precondition(state.pending.isEmpty && state.entry(key).draft == text)
        precondition(state.begin(identity: key, companionID: "route", generation: 5, requestID: "legacy", draft: text, supportsResults: false) != nil)
        precondition(state.pending.isEmpty && state.entry(key).phase == .legacy && state.entry(key).draft == text)
        state.forget(deviceID: "phone")
        precondition(state.entries.isEmpty && state.pending.isEmpty)

        // Real removals/snapshot reconciliation retire empty completed state immediately.
        begin("removed-pending")
        state.observe(deviceID: "phone", notificationID: "synthetic", removed: true, now: 100)
        precondition(state.entry(key).phase == .pending && state.pending.count == 1)
        precondition(state.resolve(requestID: "removed-pending", notificationID: "synthetic", actionID: "0", companionID: "route", generation: 4, accepted: true, errorCode: ""))
        precondition(state.entries[key] == nil)
        state.setDraft(text, for: key)
        state.reconcile(deviceID: "phone", activeNotificationIDs: [], now: 200)
        precondition(state.entry(key).draft == text, "Removed unsent draft stays recoverable briefly")
        state.expireOrphans(now: 200 + NotificationActionState.orphanRetention)
        precondition(state.entries.isEmpty)
        state.setDraft(text, for: key)
        state.reconcile(deviceID: "phone", activeNotificationIDs: [], now: 300)
        state.observe(deviceID: "phone", notificationID: "synthetic", removed: false, now: 301)
        state.expireOrphans(now: 5_000)
        precondition(state.entry(key).draft == text, "A restored live draft never expires due to disconnect")
        begin("forgotten-pending")
        state.forget(deviceID: "phone")
        precondition(state.entries.isEmpty && state.pending.isEmpty && state.nextOrphanDeadline == nil)

        // Pending work has a hard bound; retire the matching generation to release it.
        for index in 0..<33 {
            let identity = NotificationActionIdentity(deviceID: "many", notificationID: "\(index)", actionID: "0")
            let result = state.begin(identity: identity, companionID: "route", generation: 9,
                requestID: "request-\(index)", draft: text, supportsResults: true)
            precondition((result != nil) == (index < 32))
        }
        precondition(state.pending.count == 32)
        precondition(state.disconnect(companionID: "route", generation: 9).count == 32)
        precondition(state.pending.isEmpty)
        print("PASS notification action drafts: accepted/error/timeout/disconnect/legacy, generation fences, double click, duplicate/late result, newer edit")
    }
}
