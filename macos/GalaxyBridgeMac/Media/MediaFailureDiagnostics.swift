#if !GALAXYBRIDGE_APP_STORE
import Foundation
import Network
import GalaxyBridgeEnhancedCore

/// Only finite reason tags and numeric status codes may enter public diagnostics.
/// Never interpolate a peer's result, exception description, endpoint or payload.
enum MediaFailureDiagnostics {
    static func reason(_ error: Error) -> String {
        if let failure = error as? NativeMediaFailure {
            switch failure {
            case .capacity: return "native_capacity"
            case .invalidSize: return "native_invalid_size"
            case let .nativeCleanup(status): return "native_cleanup_\(status)"
            case .cleanupIncomplete: return "native_cleanup_incomplete"
            case .codec: return "native_codec"
            }
        }
        if let failure = error as? ShellCapabilityBridgeFailure {
            switch failure {
            case .unavailable: return "shell_unavailable"
            case .invalidResult: return "shell_invalid_result"
            case .sessionChanged: return "shell_session_changed"
            case .timeout: return "shell_timeout"
            case .operationFailed: return "shell_operation_failed"
            case .capacity: return "shell_capacity"
            case .runtimeInUse: return "shell_runtime_in_use"
            }
        }
        if let failure = error as? NWError {
            switch failure {
            case let .posix(code): return "network_posix_\(code.rawValue)"
            case let .dns(code): return "network_dns_\(code)"
            case let .tls(code): return "network_tls_\(code)"
            default: return "network_other"
            }
        }
        if let failure = error as? ScrcpySessionError {
            switch failure {
            case .serverNotFound: return "scrcpy_server_missing"
            case .serverChecksumMismatch: return "scrcpy_server_integrity"
            case .invalidPreamble: return "scrcpy_invalid_preamble"
            }
        }
        if let failure = error as? ScrcpyReverseTunnelError {
            switch failure {
            case .listenerFailed: return "reverse_listener_failed"
            case .listenerTimeout: return "reverse_listener_timeout"
            case .connectionTimeout: return "reverse_connection_timeout"
            }
        }
        if error is ScrcpyControlSocketError { return "control_socket_closed" }
        if let failure = error as? ADBClientError {
            switch failure {
            case .executableNotFound: return "adb_missing"
            case .bundledExecutableNotFound: return "adb_bundle_missing"
            case let .commandFailed(code, _): return "adb_command_\(code)"
            }
        }
        if let failure = error as? QuicBackendError { return "quic_status_\(failure.status)" }
        if let failure = error as? ScrcpyDeviceMessageError {
            switch failure {
            case let .unknownType(code): return "device_message_type_\(code)"
            case .invalidClipboardLength: return "device_message_length"
            }
        }
        if error is CancellationError { return "cancelled" }
        let system = error as NSError
        switch system.domain {
        case NSPOSIXErrorDomain: return "posix_\(system.code)"
        case NSOSStatusErrorDomain: return "osstatus_\(system.code)"
        case NSCocoaErrorDomain: return "cocoa_\(system.code)"
        default: return "other"
        }
    }

    static func component(_ value: String) -> String {
        switch value {
        case "Native media": "native_media"
        case "H.264 fallback": "codec_fallback"
        case "Session preparation": "preparation"
        case "Clipboard input": "clipboard_input"
        case "Virtual display input": "display_input"
        case "QUIC transport": "quic_transport"
        case "Video socket": "video_socket"
        case "Audio socket": "audio_socket"
        case "Control socket": "control_socket"
        default: "other"
        }
    }

    static func stopResult(available: Bool, state: String, errorCode: String, streams: Int) -> String {
        let safeState: String
        switch state {
        case "stopped", "failed", "ready", "unknown", "panel_on", "panel_off", "panel_multi_on", "panel_multi_off", "panel_unknown":
            safeState = state
        default: safeState = "other"
        }
        let safeError: String
        switch errorCode {
        case "": safeError = "none"
        case "shell_operation_failed", "shell_request_failed", "shell_bridge_not_activated",
             "shell_boot_generation_changed", "shell_lease_unknown", "shell_request_busy",
             "shell_request_invalid", "shell_lease_limit_or_owner", "feature_disabled":
            safeError = errorCode
        default: safeError = "other"
        }
        return "available=\(available ? 1 : 0) state=\(safeState) error=\(safeError) streams=\(min(33, max(0, streams)))"
    }
}
#endif
