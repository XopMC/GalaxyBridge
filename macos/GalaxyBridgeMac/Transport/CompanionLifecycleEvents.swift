import Foundation

enum CompanionLifecycleEvents {
    private static let pairingStoredName = Notification.Name(
        "com.xopmc.GalaxyBridge.companion-pairing-stored"
    )

    static func pairingStored(
        _ peer: PairedPeer,
        notificationCenter: NotificationCenter = .default
    ) {
        // A promotion occurrence is distinct even when the peer/key material is identical.
        notificationCenter.post(name: pairingStoredName, object: peer,
                                userInfo: ["cachePromotionOccurrence": UUID()])
    }

    static func pairingStoredPublisher(in notificationCenter: NotificationCenter = .default) -> NotificationCenter.Publisher {
        notificationCenter.publisher(for: pairingStoredName)
    }
}
