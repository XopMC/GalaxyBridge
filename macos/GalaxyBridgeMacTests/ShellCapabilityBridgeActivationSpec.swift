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
        let intent = "Broadcasting: Intent { act=com.xopmc.galaxybridge.ACTIVATE_SHELL_BRIDGE flg=0x400000 cmp=com.xopmc.galaxybridge/.transport.shell.ShellBridgeActivationReceiver (has extras) }\n"
        precondition(ShellCapabilityBridgeActivationReceipt.parse(intent + ready, generation: generation)?.available == true,
            "The real am broadcast Intent banner must not be parsed as receipt JSON")
        precondition(ShellCapabilityBridgeActivationReceipt.parse(ready.replacingOccurrences(of: "result=0", with: "result=3"), generation: generation) == nil,
            "A valid JSON payload cannot turn a failed broadcast into successful activation")
        precondition(ShellCapabilityBridgeActivationReceipt.parse("noise { arbitrary data }\n" + ready, generation: generation)?.available == true)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(intent + ready + ready, generation: generation) == nil)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(ready, generation: UUID().uuidString.lowercased()) == nil,
            "a stale broker generation cannot satisfy this activation")
        precondition(ShellCapabilityBridgeActivationReceipt.parse("Broadcast completed: result=3", generation: generation) == nil)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(String(repeating: "x", count: 65_537) + ready, generation: generation) == nil)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(ready + ready, generation: generation) == nil)
        let prepared = ready.replacingOccurrences(of: "true", with: "false").replacingOccurrences(of: "ready", with: "prepared")
        precondition(ShellCapabilityBridgeActivationReceipt.parse(prepared, generation: generation)?.state == "prepared")
        let busy = prepared.replacingOccurrences(of: "prepared", with: "busy")
            .replacingOccurrences(of: "\"error_code\":\"\"", with: "\"error_code\":\"shell_runtime_in_use\"")
        precondition(ShellCapabilityBridgeActivationReceipt.parse(busy, generation: generation)?.isBusyPreparation == true)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(prepared, generation: generation)?.isBusyPreparation == false)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(busy.replacingOccurrences(of: "false", with: "true"), generation: generation)?.isBusyPreparation == false)
        precondition(ShellCapabilityBridgeActivationReceipt.parse(busy, generation: UUID().uuidString.lowercased()) == nil)
        print("PASS actual activation receipt bounds, generation fencing, prepared versus available and ambiguous output rejection")
    }
}
