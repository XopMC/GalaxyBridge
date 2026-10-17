/// A negotiated snapshot distinguishes an older Helper from a supported feature
/// whose permission or runtime is unavailable. Absence before negotiation is not
/// evidence that the phone is incompatible.
struct CompanionConnectivityCapabilities: Equatable, Sendable {
    var negotiated = false
    var nearbyLink = false
    var internetGateway = false
    var privilegedBridge = false
    var captureRetirementProof = false
    var shellRuntimeIdentity = false
    var unavailableReasons: [String: String] = [:]

    var supportsShellBridge: Bool {
        negotiated && (privilegedBridge || unavailableReasons["CAPABILITY_PRIVILEGED_BRIDGE"] != nil)
    }
    var supportsCaptureRetirementProof: Bool { negotiated && captureRetirementProof }
    var supportsShellRuntimeIdentity: Bool { negotiated && shellRuntimeIdentity }
    var nearbyConnectionHint: String? {
        guard negotiated, !nearbyLink else { return nil }
        return unavailableReasons["CAPABILITY_NEARBY_LINK"] == "nearby_permission_required"
            ? "NEARBY_PERMISSION_REQUIRED" : "NEARBY_HELPER_UPDATE_REQUIRED"
    }
    var internetSharingAvailabilityKey: String? {
        guard negotiated else { return "INTERNET_WAITING" }
        guard !internetGateway else { return nil }
        return unavailableReasons["CAPABILITY_INTERNET_GATEWAY"] != nil
            ? "INTERNET_GATEWAY_UNAVAILABLE" : "INTERNET_HELPER_UPDATE_REQUIRED"
    }
}
