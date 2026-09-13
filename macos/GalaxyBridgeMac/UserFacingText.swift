import Foundation

enum UserFacingText {
    private static let resolver = UserFacingTextResolver(bundle: .module)

    static func callStateName(rawValue: Int) -> String {
        resolver.callStateName(rawValue: rawValue)
    }

    static func capabilityName(for code: String) -> String {
        resolver.capabilityName(for: code)
    }

    static func unavailableReason(for code: String) -> String {
        resolver.unavailableReason(for: code)
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
