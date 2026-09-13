import Combine
import Foundation

@MainActor
final class CompanionConnectionBootstrap {
    private var pairingStoredSubscription: AnyCancellable?
    private var recentlyPairedPeers: [String: PairedPeer] = [:]

    init(
        notificationCenter: NotificationCenter = .default,
        onPairingStored: @escaping @MainActor (PairedPeer) -> Void
    ) {
        pairingStoredSubscription = CompanionLifecycleEvents
            .pairingStoredPublisher(in: notificationCenter)
            .compactMap { $0.object as? PairedPeer }
            .sink { [weak self] peer in
                Task { @MainActor in
                    guard let self else { return }
                    self.recentlyPairedPeers[peer.deviceID] = peer
                    onPairingStored(peer)
                }
            }
    }

    func peers(merging persistedPeers: [PairedPeer]) -> [PairedPeer] {
        var peersByID = Dictionary(uniqueKeysWithValues: persistedPeers.map { ($0.deviceID, $0) })
        recentlyPairedPeers.forEach { peersByID[$0.key] = $0.value }
        return Array(peersByID.values)
    }

    func forget(deviceID: String) {
        recentlyPairedPeers.removeValue(forKey: deviceID)
    }
}
