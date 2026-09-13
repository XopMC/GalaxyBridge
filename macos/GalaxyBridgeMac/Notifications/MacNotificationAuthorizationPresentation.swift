import Foundation

enum MacNotificationAuthorizationPresentation: Equatable, Sendable {
    case hidden
    case requesting
    case settingsRequired

    static func resolve(_ state: MacNotificationAuthorizationState) -> Self {
        switch state {
        case .unknown, .authorized:
            .hidden
        case .requesting:
            .requesting
        case .denied, .failed:
            .settingsRequired
        }
    }
}

enum MacNotificationSettingsDestination {
    static let url = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!
}
