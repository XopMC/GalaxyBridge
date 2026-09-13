import Foundation

struct BridgeNotificationActionRow: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let acceptsText: Bool
}

struct BridgeNotificationRow: Identifiable, Hashable, Sendable {
    let id: String
    let packageName: String
    let appLabel: String
    let title: String
    let body: String
    let postedAt: Date
    let actions: [BridgeNotificationActionRow]
    let appIconPNG: Data?
}
