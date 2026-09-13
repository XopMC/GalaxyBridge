import Foundation

@main
enum CompanionRemoteErrorTextSpec {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = root.appendingPathComponent("macos/GalaxyBridgeMac/Resources")
        let expected = [
            "sms_notification_actions_only": "SMS_NOTIFICATION_REPLY_HINT",
            "unsupported_payload": "REQUEST_NOT_SUPPORTED",
            "pairing_required": "COMPANION_PAIRING_REQUIRED",
            "session_authentication_failed": "COMPANION_AUTHENTICATION_FAILED",
        ]
        let unknown = ["", "future_error", "request details: synthetic-private-value", "PAIRING_REQUIRED"]
        for (code, key) in expected {
            precondition(CompanionRemoteErrorText.localizationKey(for: code) == key, code)
        }
        for code in unknown {
            precondition(CompanionRemoteErrorText.localizationKey(for: code) == "CAPABILITY_REASON_GENERIC")
        }

        let languages = ["en", "ru", "de", "fr", "es", "pt", "ar", "zh-Hans", "zh-Hant", "ja", "ko"]
        var localizedValues: [String: [String: String]] = [:]
        for language in languages {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"))
            let strings = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            for key in Set(expected.values).union(["CAPABILITY_REASON_GENERIC"]) {
                let value = strings[key] ?? ""
                precondition(!value.isEmpty && value != key, "Missing \(language): \(key)")
                precondition(!value.contains("synthetic-private-value"))
            }
            localizedValues[language] = strings
        }
        for language in languages where language != "en" {
            for key in Set(expected.values).union(["CAPABILITY_REASON_GENERIC"]) {
                precondition(localizedValues[language]?[key] != localizedValues["en"]?[key], "Untranslated \(language): \(key)")
            }
        }
        // Keep this table tied to the two actual Android ErrorEvent producers.
        let payloadPolicy = try String(contentsOf: root.appendingPathComponent(
            "android/app/src/main/java/com/xopmc/galaxybridge/transport/CompanionControlPayloadPolicy.kt"), encoding: .utf8)
        let rejection = try String(contentsOf: root.appendingPathComponent(
            "android/app/src/main/java/com/xopmc/galaxybridge/transport/SessionAuthenticationRejectionResponse.kt"), encoding: .utf8)
        for code in expected.keys {
            precondition((payloadPolicy + rejection).contains("\"\(code)\""), "Removed producer code: \(code)")
        }
        print("PASS Companion remote errors: four known codes, unknown/empty fallback, eleven translated catalogs")
    }
}
