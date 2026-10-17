import Combine
import Foundation

enum CompanionConnectionState { case connected, disconnected }
struct Control { var connectivityCapabilities = CompanionConnectivityCapabilities() }
struct Connections { var control = Control() }
@MainActor final class AppModel: ObservableObject {
    var companionStates: [String: CompanionConnectionState] = [:]
    var companionClients: [String: Connections] = [:]
    @Published var nearbyPreparationTasks: [String: Task<Void, Never>] = [:]
    var captureRouteHandoffTasks: [String: Task<Void, Never>] = [:]
    var captureRouteTransitionDevices = Set<String>()
    var isNearbyPairingPresented = false
    var merges = 0
    func companionID(for deviceID: String) -> String? { companionClients[deviceID] != nil ? deviceID : nil }
    func canRevokePairing(deviceID: String) -> Bool { deviceID.hasPrefix("device:") }
    func mergeDevices() { merges += 1 }
    func pairingAcknowledged() { nearbyPairingCommitted() }
    // ACTUAL_PRESENTATION_METHODS
}
final class NearbyConnectionCoordinator {
    var requested = Set<String>()
    var autoTickets: [String: UUID] = [:]
    // ACTUAL_CONNECTION_INTENT
}

@main enum ConnectivityPresentationSpec {
    @MainActor static func main() {
        let model = AppModel(), id = "device:phone"
        precondition(model.canConnectNearby(deviceID: id), "An offline paired phone must remain connectable")
        precondition(!model.canConnectNearby(deviceID: "adb:unknown"), "Unpaired discovery must not gain direct-connect authority")
        precondition(model.internetSharingAvailabilityKey(deviceID: id) == "INTERNET_PHONE_OFFLINE")

        model.companionClients[id] = .init()
        model.companionStates[id] = .connected
        precondition(model.internetSharingAvailabilityKey(deviceID: id) == "INTERNET_WAITING")
        let old = CompanionConnectivityCapabilities(negotiated: true)
        model.companionClients[id]?.control.connectivityCapabilities = old
        precondition(!old.supportsShellBridge, "An old Helper must never receive optional shell requests")
        precondition(!model.canConnectNearby(deviceID: id) && model.nearbyConnectionHint(deviceID: id) == "NEARBY_HELPER_UPDATE_REQUIRED")
        precondition(model.internetSharingAvailabilityKey(deviceID: id) == "INTERNET_HELPER_UPDATE_REQUIRED")

        let missing = CompanionConnectivityCapabilities(negotiated: true, unavailableReasons: [
            "CAPABILITY_NEARBY_LINK": "nearby_permission_required", "CAPABILITY_INTERNET_GATEWAY": "native_gateway_unavailable",
            "CAPABILITY_PRIVILEGED_BRIDGE": "shell_bridge_not_activated"])
        model.companionClients[id]?.control.connectivityCapabilities = missing
        precondition(missing.supportsShellBridge, "A supported unactivated bridge must retain its authorized activation path")
        precondition(!model.canConnectNearby(deviceID: id) && model.nearbyConnectionHint(deviceID: id) == "NEARBY_PERMISSION_REQUIRED")
        precondition(model.internetSharingAvailabilityKey(deviceID: id) == "INTERNET_GATEWAY_UNAVAILABLE")
        let ready = CompanionConnectivityCapabilities(negotiated: true, nearbyLink: true, internetGateway: true, privilegedBridge: true)
        model.companionClients[id]?.control.connectivityCapabilities = ready
        precondition(ready.supportsShellBridge && model.canConnectNearby(deviceID: id))
        precondition(model.nearbyConnectionHint(deviceID: id) == nil && model.internetSharingAvailabilityKey(deviceID: id) == nil)
        model.companionStates[id] = .disconnected
        precondition(model.canConnectNearby(deviceID: id), "A disconnected stale capability snapshot must not block offline reconnection")

        let preparation = Task { @MainActor in }
        model.nearbyPreparationTasks[id] = preparation
        precondition(model.nearbyIsPreparing(deviceID: id) && model.nearbyIsPreparing(deviceID: "phone"))
        model.nearbyPreparationTasks.removeValue(forKey: id)
        precondition(!model.nearbyIsPreparing(deviceID: id))
        model.captureRouteHandoffTasks[id] = preparation
        precondition(model.nearbyIsPreparing(deviceID: id) && !model.nearbyIsPreparing(deviceID: "device:other"),
            "capture handoff must show only this phone as preparing")
        model.captureRouteHandoffTasks.removeValue(forKey: id)
        model.captureRouteTransitionDevices.insert(id)
        precondition(model.nearbyIsPreparing(deviceID: "phone"), "unconfirmed retirement must keep duplicate preparation disabled between retries")
        model.captureRouteTransitionDevices.remove(id)
        precondition(!model.nearbyIsPreparing(deviceID: id), "confirmed handoff left the phone permanently preparing")
        model.isNearbyPairingPresented = true; model.pairingAcknowledged()
        precondition(!model.isNearbyPairingPresented && model.merges == 1,
            "A committed pairing must dismiss its QR and publish the device; network creation remains a separate action")

        let nearby = NearbyConnectionCoordinator()
        precondition(!nearby.isConnectionRequested(deviceID: "phone"), "Passive discovery alone must not expose an active attempt")
        nearby.requested.insert("phone"); precondition(nearby.isConnectionRequested(deviceID: "phone"))
        nearby.requested.remove("phone"); nearby.autoTickets["phone"] = UUID()
        precondition(nearby.isConnectionRequested(deviceID: "phone"))
        print("PASS actual connectivity presentation/callback: offline, old Helper, permission/runtime guidance, pre-BLE preparation, explicit intent and committed-pairing dismissal")
    }
}
