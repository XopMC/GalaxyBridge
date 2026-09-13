import Foundation

public enum ScreenStreamPlaceholder: Equatable, Sendable {
    case deviceUnavailable
    case mediaProjectionConsentRequired
    case capabilityUnavailable(String)
    case protectedContent
    case waitingForFirstFrame
    case physicalDeviceActive
    case mediaUnavailable
}

public enum ScreenStreamPlaceholderResolver {
    public static func resolve(
        deviceReady: Bool,
        hasFrame: Bool,
        screenCapabilityUnavailableReason: String?,
        protectedContentSuspected: Bool = false,
        physicalDeviceActive: Bool = false,
        mediaUnavailable: Bool = false
    ) -> ScreenStreamPlaceholder? {
        guard deviceReady else { return .deviceUnavailable }
        if physicalDeviceActive { return .physicalDeviceActive }
        if let reason = screenCapabilityUnavailableReason {
            if reason == "media_projection_consent_required" {
                return .mediaProjectionConsentRequired
            }
            return .capabilityUnavailable(reason)
        }
        if protectedContentSuspected { return .protectedContent }
        if mediaUnavailable { return .mediaUnavailable }
        return hasFrame ? nil : .waitingForFirstFrame
    }
}

/// Decides whether transport health must cover the last decoded frame.
///
/// A QUIC loss episode is an expected, short-lived state while fragments are
/// reordered or an IDR is requested. The last compatible decoded frame remains
/// valid during that interval and must not be replaced by a black placeholder.
/// Only a disabled stream or a frame from another display generation is
/// unavailable to present. An exhausted recovery is not proof that the last
/// compatible frame became invalid: Android may stop producing frames while
/// the display is static, so replacing that frame with a black placeholder
/// would manufacture an outage until the next unrelated screen update.
public enum ScreenStreamMediaAvailabilityPolicy {
    public static func isUnavailable(
        healthState: UInt32,
        healthReason _: UInt32,
        healthEpoch: UInt32,
        healthConfiguration: UInt32,
        frameEpoch: UInt32?,
        frameConfiguration: UInt32?
    ) -> Bool {
        guard frameEpoch == healthEpoch,
              frameConfiguration == healthConfiguration
        else { return true }

        // Recovery states, including an exhausted bounded attempt, retain the
        // last compatible frame. A later independent frame repairs the decode
        // chain; a truly stopped stream is published as disabled (4).
        return healthState == 4
    }
}
