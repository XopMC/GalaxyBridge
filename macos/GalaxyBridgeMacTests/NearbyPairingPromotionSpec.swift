import Combine
import CryptoKit
import Foundation
import Security

enum IdentityStoreError: Error { case keychain(OSStatus) }
enum StagingSpecError: Error { case injected }
// ACTUAL_MEMORY_BACKEND
struct PairingAcknowledgement {
    var committed = true
    var hostID: String
    var deviceID: String
    var sessionID: String
    var transcriptSignature: Data
}
enum PairingPresentation { case idle }
@MainActor final class NearbyPairingPromotionFixture {
    final class Session {
        struct Peripheral { let identifier = UUID() }
        let peripheral = Peripheral()
        let deviceID: String?
        var commitTranscript: Data?
        var commitSignature: Data?
        var peer: PairedPeer?
        init(deviceID: String) { self.deviceID = deviceID }
    }
    let peerStore: PairedPeerStore
    var offer: NearbyOfflineOffer?
    var nearbyPairingURI: String?
    var offerExpiry: Task<Void, Never>?
    var dismissals = 0
    var retirements = 0
    var verifiedPeerIDs: [String] = []
    var discoveryCatalog = NearbyDiscoveryCatalog()
    var offerRetry: Task<Void, Never>?
    var offerCandidateID: UUID?
    var eventAlreadyPublished: () -> Bool = { false }
    init(store: PairedPeerStore, offer: NearbyOfflineOffer) { peerStore = store; self.offer = offer; nearbyPairingURI = offer.uri }
    func onPairingCommitted() {
        precondition(eventAlreadyPublished(), "Trust epoch must change synchronously before dismissal or model reconciliation")
        dismissals += 1
    }
    func update(_ session: Session, _ presentation: PairingPresentation) {}
    func retire(_ session: Session, sendRelease: Bool) { precondition(!sendRelease); retirements += 1 }
    func pump() {}
    func refreshDiscovery() {}
    func onVerifiedPairing(_ deviceID: String) {
        precondition(eventAlreadyPublished() && retirements == 1, "automatic route resolution follows durable trust and retirement")
        verifiedPeerIDs.append(deviceID)
    }
    func receiveAcknowledgement(_ ack: PairingAcknowledgement, _ session: Session, _ offer: NearbyOfflineOffer) throws {
        // ACTUAL_OFFER_ADMISSION
        // ACTUAL_ACKNOWLEDGEMENT_BRANCH
    }
}

@main enum NearbyPairingPromotionSpec {
    @MainActor static func main() throws {
        let backend = MemoryPairedPeerBackend()
        let store = PairedPeerStore(backend: backend, servicePrefix: "test.nearby-promotion")
        let macKey = P256.Signing.PrivateKey(), phoneKey = P256.Signing.PrivateKey()
        let offer = try NearbyOfflineOffer(hostID: UUID().uuidString.lowercased(), identity: macKey.publicKey.x963Representation)
        let peer = PairedPeer(deviceID: "phone", displayName: "phone", identityPublicKey: phoneKey.publicKey.x963Representation,
            tlsCertificateSHA256: Data(repeating: 0x22, count: 32), pairedAt: Date(timeIntervalSince1970: 100))
        let transcript = Data("validated commit transcript".utf8), commitSignature = Data("validated commit signature".utf8)
        try store.stage(StagedPairingTrust(peer: peer, hostID: offer.hostID, sessionID: offer.sessionID,
            commitTranscript: transcript, commitSignature: commitSignature, expiresAt: offer.expiresAt))
        let coordinator = NearbyPairingPromotionFixture(store: store, offer: offer)
        let session = NearbyPairingPromotionFixture.Session(deviceID: peer.deviceID)
        session.commitTranscript = transcript; session.commitSignature = commitSignature
        var promoted: [PairedPeer] = [], occurrences: [UUID] = []
        let observation = CompanionLifecycleEvents.pairingStoredPublisher().sink { event in
            guard let promotedPeer = event.object as? PairedPeer,
                  let occurrence = event.userInfo?["cachePromotionOccurrence"] as? UUID else { preconditionFailure("Missing promotion event identity") }
            precondition((try? store.peers()) == [peer], "Promotion must be durable before the synchronous trust fence")
            promoted.append(promotedPeer); occurrences.append(occurrence)
        }
        coordinator.eventAlreadyPublished = { promoted == [peer] && occurrences.count == 1 }
        let acknowledgementTranscript = PairingTranscript.makeCommitAcknowledgement(commitTranscript: transcript, commitSignature: commitSignature)
        let valid = PairingAcknowledgement(hostID: offer.hostID, deviceID: peer.deviceID, sessionID: offer.sessionID,
            transcriptSignature: try phoneKey.signature(for: acknowledgementTranscript).derRepresentation)

        var rejected = valid; rejected.committed = false
        do { try coordinator.receiveAcknowledgement(rejected, session, offer); preconditionFailure("Rejected Ack was accepted") }
        catch NearbyTransportFailure.authentication {}
        var wrongIdentity = valid
        wrongIdentity.transcriptSignature = try macKey.signature(for: acknowledgementTranscript).derRepresentation
        do { try coordinator.receiveAcknowledgement(wrongIdentity, session, offer); preconditionFailure("Invalid signed Ack was accepted") }
        catch NearbyTransportFailure.authentication {}
        precondition(promoted.isEmpty && coordinator.dismissals == 0 && coordinator.verifiedPeerIDs.isEmpty && (try? store.peers()) == [])

        backend.failNextWrite = true
        do { try coordinator.receiveAcknowledgement(valid, session, offer); preconditionFailure("Failed promotion was accepted") }
        catch StagingSpecError.injected {}
        precondition(promoted.isEmpty && coordinator.dismissals == 0 && session.peer == nil,
            "A failed trust write must not emit an event or dismiss pairing")

        try coordinator.receiveAcknowledgement(valid, session, offer)
        precondition(promoted == [peer] && occurrences.count == 1 && session.peer == peer)
        precondition(coordinator.dismissals == 1 && coordinator.retirements == 1 && coordinator.nearbyPairingURI == nil)
        precondition(coordinator.verifiedPeerIDs == [peer.deviceID])
        do { try coordinator.receiveAcknowledgement(valid, session, offer); preconditionFailure("A retired offer was replayed") }
        catch NearbyTransportFailure.invalidOffer {}
        precondition(promoted.count == 1 && coordinator.dismissals == 1 && coordinator.retirements == 1,
            "Duplicate receipts must not emit another trust epoch or dismissal")
        observation.cancel()
        print("PASS actual nearby pairing Ack: signed admission, durable promotion, synchronous per-peer epoch event exactly once, dismissal and duplicate rejection")
    }
}
