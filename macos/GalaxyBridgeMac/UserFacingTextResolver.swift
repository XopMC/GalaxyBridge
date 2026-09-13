import Foundation

/// Converts identifiers exchanged by the bridge protocol into copy intended for people.
/// The raw identifier is deliberately never used as a fallback.
struct UserFacingTextResolver {
    private let bundle: Bundle

    init(bundle: Bundle) {
        self.bundle = bundle
    }

    func callStateName(rawValue: Int) -> String {
        let key: String = switch rawValue {
        case 1: "CALL_STATE_IDLE"
        case 2: "CALL_STATE_RINGING"
        case 3: "CALL_STATE_DIALING"
        case 4: "CALL_STATE_ACTIVE"
        case 5: "CALL_STATE_ENDED"
        default: "CALL_STATE_UNKNOWN"
        }
        return localized(key)
    }

    func capabilityName(for code: String) -> String {
        localized(Self.capabilityKeys[code] ?? "CAPABILITY_NAME_GENERIC")
    }

    func unavailableReason(for code: String) -> String {
        localized(Self.reasonKeys[code] ?? "CAPABILITY_REASON_GENERIC")
    }

    func connectionStatus(isReady: Bool, usesPhoneApp: Bool) -> String {
        if isReady { return localized("CONNECTION_CONNECTED") }
        return localized(usesPhoneApp ? "CONNECTION_WAITING_PHONE" : "CONNECTION_CONFIRM_PHONE")
    }

    func displayName(id: UInt32, width: UInt32?, height: UInt32?) -> String {
        guard let width, let height else { return formatted("DISPLAY_NAME", String(id)) }
        // Display identifiers and pixel dimensions keep their ungrouped notation.
        return formatted("DISPLAY_NAME_WITH_SIZE", String(id), String(width), String(height))
    }

    func localized(_ key: String) -> String {
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        return value == key ? bundle.localizedString(forKey: "UI_TEXT_GENERIC", value: "Galaxy Bridge", table: nil) : value
    }

    func formatted(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: Locale.current, arguments: arguments)
    }

    private static let capabilityKeys = [
        "CAPABILITY_UNSPECIFIED": "CAPABILITY_NAME_GENERIC",
        "CAPABILITY_SCREEN_CAPTURE": "CAPABILITY_NAME_SCREEN_CAPTURE",
        "CAPABILITY_INPUT_INJECTION": "CAPABILITY_NAME_INPUT_INJECTION",
        "CAPABILITY_AUDIO_FORWARDING": "CAPABILITY_NAME_AUDIO_FORWARDING",
        "CAPABILITY_CLIPBOARD_READ": "CAPABILITY_NAME_CLIPBOARD_READ",
        "CAPABILITY_CLIPBOARD_WRITE": "CAPABILITY_NAME_CLIPBOARD_WRITE",
        "CAPABILITY_FILES": "CAPABILITY_NAME_FILES",
        "CAPABILITY_NOTIFICATIONS": "CAPABILITY_NAME_NOTIFICATIONS",
        "CAPABILITY_SMS": "CAPABILITY_NAME_SMS",
        "CAPABILITY_CALLS": "CAPABILITY_NAME_CALLS",
        "CAPABILITY_CAMERA_STREAM": "CAPABILITY_NAME_CAMERA_STREAM",
        "CAPABILITY_VIRTUAL_DISPLAY": "CAPABILITY_NAME_VIRTUAL_DISPLAY",
        "CAPABILITY_RECORDING": "CAPABILITY_NAME_RECORDING",
        "CAPABILITY_PHYSICAL_SCREEN_OFF": "CAPABILITY_NAME_PHYSICAL_SCREEN_OFF",
    ]

    private static let reasonKeys = [
        "media_projection_consent_required": "CAPABILITY_REASON_SCREEN_PERMISSION",
        "screen_capture_not_running": "CAPABILITY_REASON_SCREEN_NOT_RUNNING",
        "accessibility_service_disabled": "CAPABILITY_REASON_ACCESSIBILITY",
        "notification_access_disabled": "CAPABILITY_REASON_NOTIFICATION_ACCESS",
        "storage_folder_not_selected": "CAPABILITY_REASON_STORAGE_FOLDER",
        "record_audio_permission_required": "CAPABILITY_REASON_AUDIO_PERMISSION",
        "media_projection_audio_not_running_or_blocked": "CAPABILITY_REASON_AUDIO_NOT_RUNNING",
        "notification_actions_only": "CAPABILITY_REASON_NOTIFICATION_ACTIONS_ONLY",
        "call_permissions_required": "CAPABILITY_REASON_CALL_PERMISSION",
        "default_dialer_role_required": "CAPABILITY_REASON_DIALER_ROLE",
        "camera_permission_required": "CAPABILITY_REASON_CAMERA_PERMISSION",
        "enhanced_adb_required": "CAPABILITY_REASON_CABLE_REQUIRED",
        "physical_screen_off_while_mirroring_requires_enhanced_adb": "CAPABILITY_REASON_PHYSICAL_SCREEN_OFF_REQUIRES_ENHANCED",
        "media_projection_stopped_when_device_locked": "CAPABILITY_REASON_PROJECTION_STOPPED_WHEN_LOCKED",
    ]
}
