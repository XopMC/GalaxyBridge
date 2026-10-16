/// Tracks authoritative phone notification snapshots independently for each device.
/// Call from the same actor that consumes the ordered events stream.
struct NotificationSnapshotReconciliation {
    private var pendingByDevice: [String: Set<String>] = [:]
    private var authoritativeByDevice: [String: Set<String>] = [:]

    mutating func begin(deviceID: String) {
        pendingByDevice[deviceID] = []
    }

    mutating func observe(deviceID: String, notificationID: String, removed: Bool) {
        if var pending = pendingByDevice[deviceID] {
            if removed { pending.remove(notificationID) } else { pending.insert(notificationID) }
            pendingByDevice[deviceID] = pending
        } else if var active = authoritativeByDevice[deviceID] {
            if removed { active.remove(notificationID) } else { active.insert(notificationID) }
            authoritativeByDevice[deviceID] = active
        }
    }

    /// Returns IDs to delete only after a matching complete snapshot. Include
    /// visible, native, and known cached IDs; the restoration fence also excludes
    /// stale disk-only rows arriving from an asynchronous cache read later.
    mutating func complete(deviceID: String, knownIDs: Set<String>) -> Set<String>? {
        guard let active = pendingByDevice.removeValue(forKey: deviceID) else { return nil }
        let previous = authoritativeByDevice[deviceID, default: []]
        authoritativeByDevice[deviceID] = active
        return knownIDs.union(previous).subtracting(active)
    }

    func shouldRestore(deviceID: String, notificationID: String) -> Bool {
        if pendingByDevice[deviceID] != nil { return true }
        return authoritativeByDevice[deviceID]?.contains(notificationID) ?? true
    }

    func activeIDs(deviceID: String) -> Set<String>? { authoritativeByDevice[deviceID] }

    mutating func abort(deviceID: String) {
        pendingByDevice.removeValue(forKey: deviceID)
    }

    mutating func forget(deviceID: String) {
        pendingByDevice.removeValue(forKey: deviceID)
        authoritativeByDevice.removeValue(forKey: deviceID)
    }
}
