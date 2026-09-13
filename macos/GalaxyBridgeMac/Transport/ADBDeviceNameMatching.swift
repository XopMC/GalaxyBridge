import Foundation

enum ADBDeviceNameMatching {
    static func matches(model: String, companionName: String) -> Bool {
        // Android's ADB model metadata uses underscores where Build.MODEL
        // reported through Companion may use hyphens or spaces. This is only
        // candidate discovery; signed nonce verification still grants identity.
        let modelKey = model.lowercased().filter { $0.isLetter || $0.isNumber }
        let companionKey = companionName.lowercased().filter { $0.isLetter || $0.isNumber }
        return modelKey.count >= 3 && companionKey.contains(modelKey)
    }
}
