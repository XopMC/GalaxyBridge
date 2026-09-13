import Foundation

@main
private enum MacNotificationAuthorizationPresentationSpec {
    static func main() {
        expect(
            MacNotificationAuthorizationPresentation.resolve(.unknown) == .hidden,
            "an authorization request starts automatically, so unknown must not flash an error card"
        )
        expect(
            MacNotificationAuthorizationPresentation.resolve(.requesting) == .requesting,
            "the UI must show that the native macOS permission request is in progress"
        )
        expect(
            MacNotificationAuthorizationPresentation.resolve(.authorized) == .hidden,
            "authorized notification delivery needs no setup card"
        )
        expect(
            MacNotificationAuthorizationPresentation.resolve(.denied) == .settingsRequired,
            "a denied permission must expose a direct settings action"
        )
        expect(
            MacNotificationAuthorizationPresentation.resolve(.failed) == .settingsRequired,
            "a failed native permission request must never be silently hidden"
        )
        expect(
            MacNotificationSettingsDestination.url.scheme == "x-apple.systempreferences",
            "the settings action must open the native macOS notification settings"
        )
        print("PASS native notification authorization presentation")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
