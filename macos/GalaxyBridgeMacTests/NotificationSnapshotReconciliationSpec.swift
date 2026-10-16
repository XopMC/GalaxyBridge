import Foundation

@main
enum NotificationSnapshotReconciliationSpec {
    static func main() {
        var state = NotificationSnapshotReconciliation()
        // A lost tombstone during transport failure must be repaired by a full replay.
        state.begin(deviceID: "phone")
        state.observe(deviceID: "phone", notificationID: "kept", removed: false)
        let removed = state.complete(deviceID: "phone", knownIDs: ["kept", "lost-removal"])
        precondition(removed == ["lost-removal"])
        precondition(state.shouldRestore(deviceID: "phone", notificationID: "kept"))
        precondition(!state.shouldRestore(deviceID: "phone", notificationID: "disk-only-stale"), "Late cache restoration must obey the completed snapshot")

        // Partial replay is not authoritative. Preserve both existing rows until a complete end marker.
        state.begin(deviceID: "phone")
        state.observe(deviceID: "phone", notificationID: "partial", removed: false)
        state.abort(deviceID: "phone")
        precondition(state.shouldRestore(deviceID: "phone", notificationID: "kept"))
        precondition(state.complete(deviceID: "phone", knownIDs: ["kept"]) == nil)

        // An empty, complete snapshot clears all previously known rows.
        state.begin(deviceID: "phone")
        precondition(state.complete(deviceID: "phone", knownIDs: ["kept", "partial"]) == ["kept", "partial"])
        precondition(!state.shouldRestore(deviceID: "phone", notificationID: "kept"))

        // Live notifications after replay participate in restoration; live removals stay removed.
        state.observe(deviceID: "phone", notificationID: "new-live", removed: false)
        precondition(state.shouldRestore(deviceID: "phone", notificationID: "new-live"))
        state.observe(deviceID: "phone", notificationID: "new-live", removed: true)
        precondition(!state.shouldRestore(deviceID: "phone", notificationID: "new-live"))

        // A retry replaces an unfinished snapshot, and device state remains isolated.
        state.begin(deviceID: "phone")
        state.observe(deviceID: "phone", notificationID: "discarded-attempt", removed: false)
        state.begin(deviceID: "phone")
        state.observe(deviceID: "phone", notificationID: "retry", removed: false)
        state.begin(deviceID: "other")
        state.observe(deviceID: "other", notificationID: "independent", removed: false)
        precondition(state.complete(deviceID: "phone", knownIDs: ["discarded-attempt"]) == ["discarded-attempt"])
        precondition(state.complete(deviceID: "other", knownIDs: ["independent"]) == [])
        precondition(state.shouldRestore(deviceID: "other", notificationID: "independent"))
        state.forget(deviceID: "phone")
        precondition(state.shouldRestore(deviceID: "phone", notificationID: "old-server-cache"), "Older servers without boundaries retain legacy cache restoration")
        print("PASS notification snapshots: lost removal, partial/empty replay, cache restore fence, live updates, retries, device isolation")
    }
}
