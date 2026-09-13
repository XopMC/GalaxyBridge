import Foundation

/// Exact consumer tokens survive verified device identity changes. Retirement
/// permits keep a replacement capture behind every previous owner's cleanup.
struct PrimaryScreenDemandRegistry {
    enum Consumer { case viewer, recording }
    private struct Lease { var deviceID: String; let consumer: Consumer }
    private var leases: [UUID: Lease] = [:]
    private var retiring: [UUID: String] = [:]

    mutating func acquire(deviceID: String, consumer: Consumer, id: UUID = UUID()) -> UUID {
        precondition(leases[id] == nil)
        leases[id] = Lease(deviceID: deviceID, consumer: consumer)
        return id
    }
    @discardableResult mutating func release(_ id: UUID) -> String? {
        leases.removeValue(forKey: id)?.deviceID
    }
    func deviceID(for lease: UUID) -> String? { leases[lease]?.deviceID }
    func hasDemand(_ deviceID: String) -> Bool {
        leases.values.contains { $0.deviceID == deviceID }
    }
    func hasViewer(_ deviceID: String) -> Bool {
        leases.values.contains { $0.deviceID == deviceID && $0.consumer == .viewer }
    }
    func canStart(_ deviceID: String) -> Bool {
        hasDemand(deviceID) && !retiring.values.contains(deviceID)
    }
    mutating func beginRetirement(_ deviceID: String) -> UUID {
        let id = UUID(); retiring[id] = deviceID; return id
    }
    /// An old completion can only remove its exact permit, including after a
    /// merge with another retiring alias. It cannot clear the replacement.
    mutating func finishRetirement(_ id: UUID) -> String? {
        retiring.removeValue(forKey: id)
    }
    mutating func revoke(_ deviceID: String) {
        leases = leases.filter { $0.value.deviceID != deviceID }
    }
    mutating func removeAllDemand() { leases.removeAll() }
    mutating func migrate(from oldID: String, to newID: String) {
        for id in Array(leases.keys) where leases[id]?.deviceID == oldID {
            leases[id]?.deviceID = newID
        }
        for id in Array(retiring.keys) where retiring[id] == oldID { retiring[id] = newID }
    }
}
