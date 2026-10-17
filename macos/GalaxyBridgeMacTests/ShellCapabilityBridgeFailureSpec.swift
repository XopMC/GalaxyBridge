import Foundation

@main enum ShellCapabilityBridgeFailureSpec {
    static func main() {
        precondition(ShellCapabilityBridgeFailure.capacity.localizedDescription == String(localized: "APPLICATION_WINDOW_LIMIT"))
        for failure in [ShellCapabilityBridgeFailure.unavailable, .invalidResult, .sessionChanged, .timeout, .operationFailed] {
            precondition(failure.localizedDescription == String(localized: "ERROR_SCREEN_CONNECTION"))
            precondition(!failure.localizedDescription.contains("ShellCapabilityBridgeFailure"))
        }
        print("PASS shell failure recovery uses localized connection/window guidance without implementation error names")
    }
}
