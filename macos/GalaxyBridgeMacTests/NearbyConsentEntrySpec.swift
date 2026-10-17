import Foundation
@MainActor final class ConsentEntryFixture {
    final class Coordinator {
        var qrCalls = 0
        var choices = 0
        var candidates: [UUID] = []
        func beginOfflinePairing(candidateID: UUID?) { qrCalls += 1 }
        func showPairingChoices() { choices += 1 }
        func beginConsentPairing(candidateID:UUID) { candidates.append(candidateID) }
        var nearbyPairingURI: String? { nil }
    }
    let nearbyConnection = Coordinator()
    var isNearbyPairingPresented = false
    // ACTUAL_ENTRY
}
@main enum NearbyConsentEntrySpec {
    @MainActor static func main() {
        let m=ConsentEntryFixture(), id=UUID()
        m.beginNearbyPairing(candidateID:id)
        precondition(m.isNearbyPairingPresented && m.nearbyConnection.candidates == [id])
        precondition(m.nearbyConnection.qrCalls == 0 && m.nearbyConnection.choices == 0)
        m.isNearbyPairingPresented=false
        m.beginNearbyPairing(candidateID:nil)
        precondition(m.isNearbyPairingPresented && m.nearbyConnection.choices == 1)
        precondition(m.nearbyConnection.qrCalls == 0)
        print("PASS actual discovered Add and direct Add choose consent without QR")
    }
}
