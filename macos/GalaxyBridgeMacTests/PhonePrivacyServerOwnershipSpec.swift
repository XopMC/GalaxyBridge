import Foundation

@main
private enum PhonePrivacyServerOwnershipSpec {
    static func main() throws {
        func expect(_ value: @autoclosure () throws -> Bool, _ reason: String) throws {
            if try !value() { throw NSError(domain: reason, code: 1) }
        }
        let first = PhonePrivacyServerOwnership(), second = PhonePrivacyServerOwnership()
        try expect(first.remoteJarPath != second.remoteJarPath, "each cleanup child owns a distinct JAR")
        let arguments = ["shell", "CLASSPATH=/data/local/tmp/scrcpy-server.jar", "cleanup=true", "video=false", "audio=false", "power_on=false"]
        let owned = try first.serverArguments(replacingSharedClasspath: arguments)
        try expect(owned[1] == "CLASSPATH=\(first.remoteJarPath)", "cleanup must unlink only its own JAR")
        try expect(!owned.contains("CLASSPATH=/data/local/tmp/scrcpy-server.jar"), "shared server remains untouched")
        let finalOffArguments = arguments.map { $0 == "cleanup=true" ? "cleanup=false" : $0 }
        let finalOff = try first.serverArguments(replacingSharedClasspath: finalOffArguments, cleanupEnabled: false)
        try expect(finalOff.contains("cleanup=false") && !finalOff.contains("cleanup=true"), "final OFF restoration must have no child that can undo OFF")
        do {
            _ = try first.serverArguments(replacingSharedClasspath: finalOffArguments)
            throw NSError(domain: "ordinary privacy owner requires crash cleanup", code: 1)
        } catch is PhonePrivacyServerOwnership.OwnershipError {}
        try expect(PhonePrivacyServerOwnership.cleanupChildren("PID PPID ARGS\n42 10 app_process / com.genymobile.scrcpy.CleanUp 0\n43 11 app_process / com.genymobile.scrcpy.CleanUp 0\n44 10 unrelated", parentPID: 10) == [42], "only exact direct cleanup child")
        let wrapperAndServer = """
        PID PPID ARGS
        101 100 sh -c CLASSPATH=/data/local/tmp/galaxybridge-privacy-test.jar app_process / com.genymobile.scrcpy.Server 4.1 scid=1234abcd cleanup=true
        102 101 app_process / com.genymobile.scrcpy.Server 4.1 scid=1234abcd cleanup=true
        103 102 app_process / com.genymobile.scrcpy.CleanUp 0 -1 false false -1 -1
        104 999 app_process / com.genymobile.scrcpy.CleanUp 0 -1 false false -1 -1
        """
        try expect(PhonePrivacyServerOwnership.cleanupChildren(wrapperAndServer, parentPIDs: [101, 102, 102]) == [103], "shell wrapper and real server may both match the same SCID")
        try expect(PhonePrivacyServerOwnership.forwardState("", serial: "usb", port: 12345, socketName: "scrcpy_1234abcd") == .absent, "not-found forward is settled only with absence proof")
        try expect(PhonePrivacyServerOwnership.forwardState("usb tcp:12345 localabstract:scrcpy_1234abcd", serial: "usb", port: 12345, socketName: "scrcpy_1234abcd") == .owned, "owned forward matches route and exact private endpoint")
        try expect(PhonePrivacyServerOwnership.forwardState("other-phone tcp:12345 localabstract:scrcpy_1234abcd", serial: "usb", port: 12345, socketName: "scrcpy_1234abcd") == .unrelated, "same port on another route must not be removed")
        try expect(PhonePrivacyServerOwnership.forwardState("usb tcp:12345 localabstract:unrelated", serial: "usb", port: 12345, socketName: "scrcpy_1234abcd") == .unrelated, "reused port with another endpoint must not be removed")
        try expect(PhonePrivacyServerOwnership.requiresRouteSettlement(current: "wifi", requested: "wifi", controlReady: false), "same route retries previously failed retirement")
        try expect(!PhonePrivacyServerOwnership.requiresRouteSettlement(current: "wifi", requested: "wifi", controlReady: true), "ready unchanged route keeps current owner")
        let stat = "42 (Cleanup process) S " + Array(repeating: "0", count: 18).joined(separator: " ") + " 12345 0"
        let identity = PhonePrivacyCleanupIdentity(pid: 42, startTime: 12345)
        try expect(PhonePrivacyCleanupIdentity.parseStat(stat) == identity, "stat parser handles spaces in comm")
        let running = PhonePrivacyCleanupProbe.parse("OWNED\napp_process / com.genymobile.scrcpy.CleanUp 0\n\(stat)\n")
        try expect(try running.settled(expected: identity) == false, "living exact child blocks next owner")
        try expect(try PhonePrivacyCleanupProbe.gone.settled(expected: identity), "gone child is settled")
        try expect(try running.settled(expected: .init(pid: 42, startTime: 999)), "reused PID is settled without killing")
        do {
            _ = try PhonePrivacyCleanupProbe.unavailable.settled(expected: identity)
            throw NSError(domain: "unreadable proc must fail closed", code: 1)
        } catch is PhonePrivacyCleanupProbe.ProbeError {}
        print("PhonePrivacyServerOwnershipSpec passed")
    }
}
