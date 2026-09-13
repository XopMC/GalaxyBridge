import Foundation

private enum SpecFailure: Error, CustomStringConvertible {
    case missing(String)
    case leakedTechnicalCopy(language: String, key: String, value: String)

    var description: String {
        switch self {
        case let .missing(key):
            "missing localized string \(key)"
        case let .leakedTechnicalCopy(language, key, value):
            "technical copy leaked into \(language) \(key): \(String(reflecting: value))"
        }
    }
}

@main
private enum PrimaryCopyResourceSpec {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("expected English and Russian Localizable.strings paths")
        }
        let english = try strings(at: CommandLine.arguments[1])
        let russian = try strings(at: CommandLine.arguments[2])

        let primaryKeys = [
            "USB_ADB",
            "WIRELESS_ADB",
            "COMPANION_LAN",
            "NO_DEVICE_HINT",
            "CAPABILITIES",
            "FILES_SEND_HINT",
            "FILES_COMPANION_REQUIRED",
            "FILE_HASHING",
            "FILE_WAITING_RECEIVER",
            "FILE_SENDING_ADB",
            "FILE_COMPLETE_ADB",
            "FILE_CONNECTION_LOST",
            "CAMERA_SYSTEM_HINT",
            "READY_TO_STREAM",
            "ADB_AUTH_REQUIRED",
            "PHONE_CONNECTION_REQUIRED",
            "PHONE_CONNECTION_HINT",
            "SCREEN_PERMISSION_REQUIRED",
            "SCREEN_PERMISSION_HINT",
            "SCREEN_CAPTURE_UNAVAILABLE",
            "SCREEN_CAPTURE_UNAVAILABLE_HINT",
            "SCREEN_WAITING_FIRST_FRAME",
            "PAIRING_HINT",
            "FORGET_DEVICE_MESSAGE",
        ]
        let forbidden = try NSRegularExpression(
            pattern: #"\badb\b|companion|компань|\blan\b|\bsaf\b|camerax|sha-?256|p-?256|protobuf|protocol|протокол|storage access framework|fingerprint|отпечат|\btls\b|secure channel|encrypted channel|локальный канал|защищ[её]нн[^ ]* канал|\bkey\b|\bключ(?:а|и|ей|ом|у)?\b|зашифрованн|wireless debugging|беспроводн[^ ]* отладк"#,
            options: [.caseInsensitive]
        )

        for (language, table) in [("English", english), ("Russian", russian)] {
            for key in primaryKeys {
                guard let value = table[key] else { throw SpecFailure.missing(key) }
                let range = NSRange(value.startIndex..., in: value)
                if forbidden.firstMatch(in: value, range: range) != nil {
                    throw SpecFailure.leakedTechnicalCopy(language: language, key: key, value: value)
                }
            }
        }
        print("Primary macOS copy resource spec passed")
    }

    private static func strings(at path: String) throws -> [String: String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return propertyList as? [String: String] ?? [:]
    }
}
