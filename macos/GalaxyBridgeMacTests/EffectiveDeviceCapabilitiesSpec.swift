import Foundation

@main
private enum EffectiveDeviceCapabilitiesSpec {
    static func main() {
        let reasons = [
            "CAPABILITY_SCREEN_CAPTURE": "media_projection_consent_required",
            "CAPABILITY_INPUT_INJECTION": "accessibility_service_disabled",
            "CAPABILITY_AUDIO_FORWARDING": "record_audio_permission_required",
            "CAPABILITY_FILES": "storage_folder_not_selected",
            "CAPABILITY_RECORDING": "media_projection_consent_required",
            "CAPABILITY_VIRTUAL_DISPLAY": "enhanced_adb_required",
            "CAPABILITY_PHYSICAL_SCREEN_OFF": "enhanced_adb_required",
            "CAPABILITY_NOTIFICATIONS": "notification_access_disabled",
            "CAPABILITY_SMS": "notification_actions_only",
            "CAPABILITY_CALLS": "default_dialer_role_required",
            "CAPABILITY_CAMERA_STREAM": "camera_permission_required",
        ]
        let companion: Set<String> = ["CAPABILITY_CLIPBOARD_READ", "CAPABILITY_CLIPBOARD_WRITE"]
        let enhanced = EffectiveDeviceCapabilities.resolve(
            companionAvailable: companion, companionUnavailable: reasons, hasEnhancedTransport: true
        )
        let permissionOnly: Set<String> = ["CAPABILITY_NOTIFICATIONS", "CAPABILITY_SMS", "CAPABILITY_CALLS", "CAPABILITY_CAMERA_STREAM"]
        let expectedEnhanced = Set(reasons.keys).subtracting(permissionOnly)
        precondition(enhanced.available == companion.union(expectedEnhanced), "All implemented enhanced routes must be represented")
        for code in expectedEnhanced {
            precondition(enhanced.available.contains(code), "Enhanced route must advertise \(code)")
            precondition(enhanced.unavailableReasons[code] == nil, "LAN limitation must not override \(code)")
        }
        for code in ["CAPABILITY_NOTIFICATIONS", "CAPABILITY_SMS", "CAPABILITY_CALLS", "CAPABILITY_CAMERA_STREAM"] {
            precondition(!enhanced.available.contains(code), "ADB must not grant companion permissions: \(code)")
            precondition(enhanced.unavailableReasons[code] == reasons[code])
        }
        precondition(enhanced.available.isSuperset(of: companion))

        let fallback = EffectiveDeviceCapabilities.resolve(
            companionAvailable: companion, companionUnavailable: reasons, hasEnhancedTransport: false
        )
        precondition(fallback.available == companion, "Disconnect must remove enhanced capabilities")
        precondition(fallback.unavailableReasons == reasons, "Fallback must restore actual Android requirements")
        let current = EffectiveDeviceCapabilities.resolve(
            companionAvailable: ["CAPABILITY_NOTIFICATIONS"], companionUnavailable: reasons, hasEnhancedTransport: false
        )
        precondition(current.unavailableReasons["CAPABILITY_NOTIFICATIONS"] == nil,
                     "An available capability cannot simultaneously require setup")
        print("PASS effective capabilities merge live transports without granting unrelated permissions")
    }
}
