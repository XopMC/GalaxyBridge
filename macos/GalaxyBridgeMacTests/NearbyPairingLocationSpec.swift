import Foundation

enum FixtureLocationAuthorization { case notDetermined, denied, restricted, authorizedAlways }
@MainActor final class CLLocationManager {
    var authorizationStatus = FixtureLocationAuthorization.notDetermined
    var requests = 0
    func requestWhenInUseAuthorization() { requests += 1 }
}
@MainActor final class NearbyPairingLocationFixture {
    struct PublicKey { let x963Representation = Data(repeating: 4, count: 65) }
    struct PrivateKey { let publicKey = PublicKey() }
    struct Identity { func privateKey() throws -> PrivateKey { PrivateKey() } }
    let identity = Identity()
    let location = CLLocationManager()
    var locationPermissionHintKey: String?
    var offerCandidateID: UUID?
    var offerRetryBudget = NearbyPairingRetryBudget()
    var tried: [String: Set<UUID>] = [:]
    var discoverySuggestions: [NearbyDiscoverySuggestion] = []
    var offer: NearbyOfflineOffer?
    var nearbyPairingURI: String?
    var offerExpiry: Task<Void, Never>?
    var scans = 0
    func cancelOffer() { offerExpiry?.cancel(); offerExpiry = nil; offer = nil; nearbyPairingURI = nil }
    func refreshDiscovery() {}
    func hostID() -> String { "69830b65-6352-4b3a-8a21-70bcda45787e" }
    func startDiscovery() { scans += 1 }
    func pump() {}
    func simulatePermissionChange() { /* SIMULATE_CALLBACK */ }
    // ACTUAL_PERMISSION_HELPERS
    // ACTUAL_BEGIN_PAIRING
    // ACTUAL_END_PAIRING
}
@main enum NearbyPairingLocationSpec {
    @MainActor static func main() {
        let first = NearbyPairingLocationFixture()
        first.beginOfflinePairing()
        precondition(first.location.requests == 1, "Explicit first offline Add must request Location once")
        precondition(first.offer != nil && first.nearbyPairingURI != nil)
        precondition(first.locationPermissionHintKey == nil)
        first.location.authorizationStatus = .denied
        first.simulatePermissionChange()
        precondition(first.locationPermissionHintKey == "NEARBY_LOCATION_PERMISSION_HINT")
        first.location.authorizationStatus = .authorizedAlways
        first.simulatePermissionChange()
        precondition(first.locationPermissionHintKey == nil)
        first.endOfflinePairing()
        precondition(first.offer == nil && first.location.requests == 1)
        for status in [FixtureLocationAuthorization.denied, .restricted, .authorizedAlways] {
            let existing = NearbyPairingLocationFixture()
            existing.location.authorizationStatus = status
            existing.beginOfflinePairing()
            existing.beginOfflinePairing()
            precondition(existing.location.requests == 0, "Known permission state must never re-prompt")
            precondition(existing.offer != nil, "Location denial cannot be a pairing/trust failure")
            precondition((existing.locationPermissionHintKey != nil) == (status == .denied || status == .restricted))
            existing.endOfflinePairing()
        }
        print("PASS actual offline Add: first permission request, denial hint, grant clearing, silent known states and cancellation; no connection/Wi-Fi dependency")
    }
}
