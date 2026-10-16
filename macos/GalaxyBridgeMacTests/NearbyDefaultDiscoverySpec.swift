import Foundation

let CBCentralManagerScanOptionAllowDuplicatesKey = "duplicates"
@MainActor final class CBCentralManager {
    enum State { case poweredOn }
    let state = State.poweredOn
    var scans = 0
    var allowsDuplicates = false
    init(delegate: NearbyDefaultDiscoveryFixture, queue: DispatchQueue) {}
    func scanForPeripherals(withServices services: [UUID], options: [String: Bool]) {
        precondition(services.count == 1)
        scans += 1; allowsDuplicates = options[CBCentralManagerScanOptionAllowDuplicatesKey] == true
    }
}
@MainActor final class NearbyDefaultDiscoveryFixture {
    struct Peer { let deviceID: String }
    enum Status { case discovering, connected }
    static let service = UUID()
    var discoveryWanted = false
    var central: CBCentralManager?
    var discoveryMaintenance: Task<Void, Never>?
    var statuses: [String: Status] = [:]
    var autoTickets: [String: UUID] = [:]
    var automaticTargets = Set<String>()
    var disconnected: [String] = []
    func disconnect(deviceID: String) { disconnected.append(deviceID); automaticTargets.remove(deviceID) }
    // ACTUAL_AUTOMATIC_CANCELLATION
    func peers() -> [Peer] { [Peer(deviceID: "trusted")] }
    func refreshDiscovery() {}
    func pumpDiscoveryProbe() {}
    // ACTUAL_DISCOVERY_START
}
@main enum NearbyDefaultDiscoverySpec {
    @MainActor static func main() {
        let coordinator = NearbyDefaultDiscoveryFixture()
        coordinator.startDiscovery()
        precondition(coordinator.discoveryWanted && coordinator.central?.scans == 1)
        precondition(coordinator.central?.allowsDuplicates == true, "last-seen TTL requires fresh advertisements")
        precondition(coordinator.statuses["trusted"] == .discovering)
        let original = coordinator.central
        coordinator.startDiscovery()
        precondition(coordinator.central === original, "repeated startup must reuse its Bluetooth owner")
        coordinator.autoTickets["queued"] = UUID()
        coordinator.cancelAutomaticConnection(deviceID: "queued")
        precondition(coordinator.autoTickets["queued"] == nil && coordinator.disconnected.isEmpty,
            "Turning auto off cancels a pending association check without touching a manual connection")
        coordinator.automaticTargets = ["pending", "connected", "other"]
        coordinator.statuses["pending"] = .discovering
        coordinator.statuses["connected"] = .connected
        coordinator.cancelAutomaticConnection(deviceID: "pending")
        precondition(coordinator.disconnected == ["pending"] && coordinator.automaticTargets.contains("other"))
        coordinator.cancelAutomaticConnection(deviceID: "connected")
        coordinator.cancelAutomaticConnection(deviceID: "manual")
        precondition(coordinator.disconnected == ["pending"], "Auto off preserves established and explicit manual sessions")
        coordinator.discoveryMaintenance?.cancel()
        print("PASS actual default discovery entry point uses scan-only boundary without Wi-Fi, trust or network dependencies")
    }
}
