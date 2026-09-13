/// Maps stable protocol error codes to locally owned, translated copy.
/// Remote `safe_message` is intentionally not an input: it may use another
/// language or contain details that should not be displayed or logged.
enum CompanionRemoteErrorText {
    static func localizationKey(for code: String) -> String {
        switch code {
        case "sms_notification_actions_only":
            "SMS_NOTIFICATION_REPLY_HINT"
        case "unsupported_payload":
            "REQUEST_NOT_SUPPORTED"
        case "pairing_required":
            "COMPANION_PAIRING_REQUIRED"
        case "session_authentication_failed":
            "COMPANION_AUTHENTICATION_FAILED"
        default:
            "CAPABILITY_REASON_GENERIC"
        }
    }
}
