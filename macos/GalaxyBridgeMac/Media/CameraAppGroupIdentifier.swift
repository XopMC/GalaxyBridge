import Foundation

enum CameraAppGroupIdentifier {
    static let infoDictionaryKey = "GalaxyBridgeAppGroupIdentifier"

    static func resolve(configuredValue: String?) -> String? {
        guard let value = configuredValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("$(")
        else { return nil }
        return value
    }

    static func from(bundle: Bundle = .main) -> String? {
        resolve(configuredValue: bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String)
    }
}
