import Combine
import Foundation
import Network

@main
private enum BonjourSnapshotPublicationSpec {
    @MainActor static func main() {
        let discovery = BonjourDiscovery()
        var observed: [[String]] = []
        let observation = discovery.companionsDidChange.prepend(()).sink {
            // Match AppModel's synchronous sink: it reads the discovery object,
            // rather than using the publisher's incoming willSet value.
            observed.append(discovery.companions.map(\.id))
        }
        let companion = DiscoveredCompanion(id: "phone", name: "Galaxy",
            endpointDescription: "fixture",
            endpoint: .service(name: "Galaxy", type: "_galaxybridge._tcp", domain: "local.", interface: nil),
            identity: BonjourCompanionIdentity(deviceID: nil, publicKeyFingerprint: nil, protocolMajor: nil))
        discovery.applySnapshot([companion])
        discovery.applySnapshot([])
        precondition(observed == [[], ["phone"], []], "snapshot observers read stale discoveries: \(observed)")
        withExtendedLifetime(observation) {}
        print("PASS Bonjour initial merge and committed addition/removal snapshots are observed synchronously")
    }
}
