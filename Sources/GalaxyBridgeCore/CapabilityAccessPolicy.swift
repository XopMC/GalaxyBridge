import Foundation

public enum CapabilityAccess: Equatable, Sendable {
    case available
    case notificationActionsOnly
    case unavailable(String)
    case unknown
}

public enum CapabilityAccessResolver {
    public static func resolve(
        capabilityCode: String,
        availableCapabilities: Set<String>,
        unavailableReasons: [String: String]
    ) -> CapabilityAccess {
        if availableCapabilities.contains(capabilityCode) { return .available }
        guard let reason = unavailableReasons[capabilityCode] else { return .unknown }
        if reason == "notification_actions_only" { return .notificationActionsOnly }
        return .unavailable(reason)
    }
}

public enum SMSDeliveryPolicy {
    public static func allowsDirectSend(for access: CapabilityAccess) -> Bool {
        access == .available
    }
}

public enum SMSPanelMode: Equatable, Sendable {
    case directComposer
    case notificationReplies
    case unavailable
}

public enum SMSPanelPresentationPolicy {
    public static func mode(for access: CapabilityAccess) -> SMSPanelMode {
        switch access {
        case .available: .directComposer
        case .notificationActionsOnly: .notificationReplies
        case .unavailable, .unknown: .unavailable
        }
    }
}
