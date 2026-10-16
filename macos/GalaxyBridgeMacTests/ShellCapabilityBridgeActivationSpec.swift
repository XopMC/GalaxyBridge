import Foundation

@main enum ShellCapabilityBridgeActivationSpec {
    static func main() {
        precondition(ShellCapabilityBridgeActivationTarget.resolve(bundleIdentifier: "com.xopmc.GalaxyBridge")?.packageName == "com.xopmc.galaxybridge")
        precondition(ShellCapabilityBridgeActivationTarget.resolve(bundleIdentifier: "com.xopmc.GalaxyBridge.internal")?.runtimeMode == "internal")
        precondition(ShellCapabilityBridgeActivationTarget.resolve(bundleIdentifier: "other.app") == nil)
        precondition(ShellCapabilityBridgeActivationTarget.resolve(bundleIdentifier: nil) == nil)
        let generation = UUID().uuidString.lowercased()
        let ready = "Broadcast completed: result=0, data=\"{\"available\":true,\"boot_generation\":\"\(generation)\",\"state\":\"ready\",\"error_code\":\"\"}\"\n"
        precondition(ShellCapabilityBridgeActivationReceipt.parse(ready, generation: generation)?.available == true)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(ready, generation: UUID().uuidString.lowercased()) == nil,
            "a stale broker generation cannot satisfy this activation")
        precondition(ShellCapabilityBridgeActivationReceipt.parse("Broadcast completed: result=3", generation: generation) == nil)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(String(repeating: "x", count: 65_537) + ready, generation: generation) == nil)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(ready + ready, generation: generation) == nil)
        let prepared = ready.replacingOccurrences(of: "true", with: "false").replacingOccurrences(of: "ready", with: "prepared")
        precondition(ShellCapabilityBridgeActivationReceipt.parse(prepared, generation: generation)?.state == "prepared")
        print("PASS actual activation receipt bounds, generation fencing, prepared versus available and ambiguous output rejection")
    }
}
