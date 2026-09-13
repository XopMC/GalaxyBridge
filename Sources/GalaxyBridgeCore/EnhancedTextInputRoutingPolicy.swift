import Foundation

public enum EnhancedTextInputRoute: Equatable, Sendable {
    case companionAccessibility
    case scrcpy
}

public enum EnhancedTextInputRoutingPolicy {
    public static func route(
        companionConnected: Bool,
        companionCapabilitiesKnown: Bool,
        companionAdvertisesInput: Bool,
        companionInputUnavailableReason: String?
    ) -> EnhancedTextInputRoute {
        guard companionConnected,
              companionCapabilitiesKnown,
              companionAdvertisesInput,
              companionInputUnavailableReason == nil
        else { return .scrcpy }
        return .companionAccessibility
    }
}
