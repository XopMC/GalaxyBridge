import Foundation

enum UserFacingText {
    // The Direct app stages its catalogs in Contents/Resources.  Referencing
    // Bundle.module makes SwiftPM search beside the app bundle on newer macOS
    // releases, which traps while opening the pairing sheet.
    private static let resolver = UserFacingTextResolver(bundle: .main)

    static func callStateName(rawValue: Int) -> String {
        resolver.callStateName(rawValue: rawValue)
    }

    static func capabilityName(for code: String) -> String {
        switch code {
        case "CAPABILITY_NEARBY_LINK": String(localized: "NEARBY_CONNECTION")
        case "CAPABILITY_INTERNET_GATEWAY": String(localized: "INTERNET_SHARING")
        case "CAPABILITY_PRIVILEGED_BRIDGE": String(localized: "NEARBY_CONNECTION")
        default: resolver.capabilityName(for: code)
        }
    }

    static func unavailableReason(for code: String) -> String {
        if code == "feature_disabled" { return String(localized: "FEATURE_DISABLED") }
#if GALAXYBRIDGE_APP_STORE
        return resolver.unavailableReason(for: code)
#else
        return resolver.unavailableReason(for: code, usesDirectScreenConnection: true)
#endif
    }

    static func connectionStatus(isReady: Bool, usesPhoneApp: Bool) -> String {
        resolver.connectionStatus(isReady: isReady, usesPhoneApp: usesPhoneApp)
    }

    static func displayName(id: UInt32, width: UInt32?, height: UInt32?) -> String {
        resolver.displayName(id: id, width: width, height: height)
    }

    static func localized(_ key: String) -> String {
        resolver.localized(key)
    }

    static func formatted(_ key: String, _ arguments: CVarArg...) -> String {
        let format = resolver.localized(key)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
