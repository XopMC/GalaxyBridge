import Foundation

/// Companion reports only its own permissions. Those are not device-wide
/// limitations when an authorized USB/Wireless ADB route provides the feature.
struct EffectiveDeviceCapabilities {
    let available: Set<String>
    let unavailableReasons: [String: String]

    // These operations have an enhanced implementation; ADB does not grant
    // notification access, a telephony role, or Companion camera permission.
    static let enhancedCapabilities: Set<String> = [
        "CAPABILITY_SCREEN_CAPTURE", "CAPABILITY_INPUT_INJECTION",
        "CAPABILITY_AUDIO_FORWARDING", "CAPABILITY_FILES",
        "CAPABILITY_RECORDING", "CAPABILITY_VIRTUAL_DISPLAY",
        "CAPABILITY_PHYSICAL_SCREEN_OFF",
    ]

    static func resolve(
        companionAvailable: Set<String>,
        companionUnavailable: [String: String],
        hasEnhancedTransport: Bool
    ) -> Self {
        let available = companionAvailable.union(hasEnhancedTransport ? enhancedCapabilities : [])
        return Self(
            available: available,
            unavailableReasons: companionUnavailable.filter { !available.contains($0.key) }
        )
    }
}
