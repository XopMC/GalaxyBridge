/// Physical devices and independent app windows have separate admission
/// budgets. A background Companion connection is not an app-window capture.
enum SessionCapacityPolicy {
    static let maximumPhysicalDeviceSessions = 5
    static let maximumApplicationWindowSessions = 5

    static func canStartPhysicalDevice(
        _ deviceID: String,
        activeLogicalDeviceIDs: Set<String>
    ) -> Bool {
        activeLogicalDeviceIDs.contains(deviceID)
            || activeLogicalDeviceIDs.count < maximumPhysicalDeviceSessions
    }
}
