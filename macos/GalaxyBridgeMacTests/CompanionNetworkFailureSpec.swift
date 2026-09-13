import Foundation
import Network

@main
enum CompanionNetworkFailureSpec {
    static func main() {
        precondition(CompanionNetworkFailure.message(unsatisfiedReason: .localNetworkDenied)
            == String(localized: "LOCAL_NETWORK_ACCESS_REQUIRED"))
        for reason: NWPath.UnsatisfiedReason? in [nil, .notAvailable, .wifiDenied, .cellularDenied] {
            precondition(CompanionNetworkFailure.message(unsatisfiedReason: reason)
                == String(localized: "NETWORK_PATH_UNAVAILABLE"))
        }
        print("PASS local network privacy denial is distinguished from unavailable paths")
    }
}
