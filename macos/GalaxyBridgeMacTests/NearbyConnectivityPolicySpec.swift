import Foundation

@main struct NearbyConnectivityPolicySpec {
    static func main() throws {
        func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
        let a = InternetPeerKey(deviceID: "phone-a", generation: 1)
        let b = InternetPeerKey(deviceID: "phone-b", generation: 1)
        var pool = InternetGatewayPool(capacity: 2, flowCapacity: 4)
        try pool.update(.init(peer: a, leaseID: "lease-a", upstream: .wifi, healthy: true))
        try pool.update(.init(peer: b, leaseID: "lease-b", upstream: .cellular, healthy: true))
        expect(pool.select(flowID: "one", policy: .automatic)?.peer == a, "automatic prefers validated phone Wi-Fi")
        let x = pool.select(flowID: "two", policy: .balanced)!
        let y = pool.select(flowID: "three", policy: .balanced)!
        expect(x.peer != y.peer, "two gateways serve independent flows concurrently")
        expect(pool.select(flowID: "two", policy: .fixed(b)) == x, "existing flows never migrate behind the caller")
        let failed = pool.remove(peer: a, leaseID: "foreign")
        expect(failed.isEmpty && pool.gateways.count == 2, "foreign lease cannot remove a gateway")
        let affected = pool.remove(peer: x.peer, leaseID: x.leaseID)
        expect(affected.contains("two"), "withdraw reports existing failed flows for closure")
        expect(pool.select(flowID: "two", policy: .balanced)?.peer != x.peer, "new admission can use remaining gateway")
        let replacement = InternetPeerKey(deviceID: "phone-a", generation: 2)
        if pool.gateways[a] != nil { _ = pool.remove(peer: a, leaseID: "lease-a") }
        try pool.update(.init(peer: replacement, leaseID: "fresh", upstream: .cellular, healthy: true))
        expect(pool.select(flowID: "unavailable-fixed", policy: .fixed(a)) == nil, "old pairing generation never aliases new peer")
        expect(DirectConnectivityPolicy.canCreateNetwork(hasUpstreamWiFi: true, concurrency: .unknown) == false, "unknown concurrency preserves phone Wi-Fi")
        expect(DirectConnectivityPolicy.canCreateNetwork(hasUpstreamWiFi: true, concurrency: .verified) == true, "verified simultaneous mode admitted")
        expect(DirectConnectivityPolicy.canCreateNetwork(hasUpstreamWiFi: false, concurrency: .unknown) == true, "offline phone may create direct group")
        expect(DirectConnectivityPolicy.route(existingHealthy: .lan, usb: true, lan: true, direct: true) == .lan, "do not flap a healthy route")
        expect(DirectConnectivityPolicy.route(existingHealthy: nil, usb: false, lan: false, direct: true) == .direct, "direct is usable without internet")
        var group = DirectGroupOwnership()
        let lease = UUID()
        expect(group.acquire(owner: a, leaseID: lease), "first group owns one radio")
        expect(!group.acquire(owner: b, leaseID: UUID()), "second independent group rejected on one Mac radio")
        expect(!group.release(owner: b, leaseID: lease), "other phone cannot destroy owner group")
        expect(group.release(owner: a, leaseID: lease), "exact owner may retire group")
        print("PASS nearby route, Wi-Fi preservation, two gateways, flow affinity and pairing-generation ownership")
    }
}
