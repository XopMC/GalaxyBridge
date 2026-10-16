import Foundation

@main enum NearbyDiscoverySpec {
    static func main() {
        let phone = UUID(), other = UUID()
        precondition(NearbyDiscoveryMetadata.decode(Data("GBD1\nSamsung SM-S928B".utf8)) == "Samsung SM-S928B")
        for value in ["GBD2\nPhone", "GBD1\n", "GBD1\nMy\nPhone", "GBD1\n\u{202E}Phone", "GBD1\n" + String(repeating: "A", count: 65)] {
            precondition(NearbyDiscoveryMetadata.decode(Data(value.utf8)) == nil)
        }
        var catalog = NearbyDiscoveryCatalog()
        catalog.observe(phone, at: 100)
        precondition(catalog.suggestions == [.init(id: phone, model: nil)])
        precondition(catalog.nextProbe(at: 100) == phone)
        precondition(catalog.nextProbe(at: 101) == nil, "metadata connections are serialized")
        catalog.finishProbe(phone, metadata: Data("GBD1\nSamsung SM-S928B".utf8))
        precondition(catalog.suggestions.first?.model == "Samsung SM-S928B")
        precondition(catalog.nextProbe(at: 129) == nil, "a peripheral is probed at most once per 30 seconds")
        catalog.observe(other, at: 129)
        precondition(catalog.nextProbe(at: 129) == other)
        catalog.finishProbe(other, metadata: nil)
        catalog.observe(phone, at: 129)
        catalog.markTrusted(phone)
        precondition(!catalog.suggestions.contains { $0.id == phone })
        catalog.observe(phone, at: 130)
        precondition(!catalog.suggestions.contains { $0.id == phone }, "advertisements cannot undo verified suppression")
        catalog.expire(at: 159)
        precondition(catalog.suggestions.isEmpty, "absence expires a suggestion at the TTL boundary")
        catalog.expire(at: 160)
        precondition(catalog.identifiers.isEmpty)
        var bounded = NearbyDiscoveryCatalog()
        for time in 0..<100 { bounded.observe(UUID(), at: Double(time) / 100) }
        precondition(bounded.identifiers.count == 16 && bounded.suggestions.count == 8)
        bounded.removeAll()
        precondition(bounded.identifiers.isEmpty && bounded.suggestions.isEmpty)
        var retry = NearbyPairingRetryBudget()
        precondition(retry.permit(at: 0))
        precondition(!retry.permit(at: 4.99), "a QR not scanned yet must not cause a tight handshake loop")
        precondition(retry.permit(at: 5))
        for attempt in 2..<24 { precondition(retry.permit(at: Double(attempt * 5))) }
        precondition(!retry.permit(at: 120) && !retry.permit(at: 1_000), "retry remains bounded even if expiry is delayed")
        let localFingerprint = Data(repeating: 0x12, count: 32)
        let sameHost = Data(("GBD2\nSamsung SM-S928B\n" + String(repeating: "12", count: 32)).utf8)
        precondition(NearbyDiscoveryMetadata.decode(sameHost) == "Samsung SM-S928B")
        var hidden = NearbyDiscoveryCatalog()
        hidden.observe(phone, at: 0)
        precondition(hidden.nextProbe(at: 0) == phone)
        hidden.finishProbe(phone, metadata: sameHost, localHostFingerprint: localFingerprint)
        precondition(hidden.suggestions.isEmpty, "a public matching host hint may suppress only its own suggestion")
        hidden.observe(other, at: 2)
        precondition(hidden.suggestions.map(\.id) == [other], "a spoofed same-host hint cannot suppress other phones")
        precondition(hidden.nextProbe(at: 2) == other)
        hidden.finishProbe(other, metadata: sameHost, localHostFingerprint: Data(repeating: 0x34, count: 32))
        precondition(hidden.suggestions == [.init(id: other, model: "Samsung SM-S928B")], "other-host phones remain untrusted")
        hidden.observe(phone, at: 29)
        precondition(hidden.nextProbe(at: 30) == phone, "a suppression hint does not confer trust or stop read-only refresh")
        hidden.finishProbe(phone, metadata: Data("GBD1\nSamsung SM-S928B".utf8), localHostFingerprint: localFingerprint)
        precondition(hidden.suggestions.contains { $0.id == phone }, "an unpaired phone becomes an untrusted suggestion again")
        for invalid in ["GBD2\nPhone\n", "GBD2\nPhone\n" + String(repeating: "GG", count: 32), "GBD2\nPhone\n" + String(repeating: "00", count: 33)] {
            precondition(NearbyDiscoveryMetadata.decode(Data(invalid.utf8)) == nil)
        }
        print("PASS untrusted metadata validation, bounded discovery/probe rate, trust suppression and disappearance TTL")
    }
}
