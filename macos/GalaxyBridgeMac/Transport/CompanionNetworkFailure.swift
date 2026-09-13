import Foundation
import Network

/// Report a privacy denial only when Network.framework identifies it. ENETDOWN
/// and a waiting connection alone also occur during ordinary network changes.
enum CompanionNetworkFailure {
    static func message(unsatisfiedReason: NWPath.UnsatisfiedReason?) -> String {
        String(localized: unsatisfiedReason == .localNetworkDenied
            ? "LOCAL_NETWORK_ACCESS_REQUIRED"
            : "NETWORK_PATH_UNAVAILABLE")
    }
}
