import Foundation
import Darwin

@main struct ScrcpyADBOwnerLifetimeSpec {
    static func main() throws {
        let arguments = ["shell", "CLASSPATH=/data/local/tmp/own.jar", "app_process", "/", "com.genymobile.scrcpy.Server", "4.1", "scid=00000012"]
        let leased = try ScrcpyADBOwnerLifetime.launchArguments(arguments)
        precondition(leased == ["shell", "-T", "CLASSPATH=/data/local/tmp/own.jar", "app_process", "/", "'com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain'", "scrcpy", "--owner-lease", "4.1", "scid=00000012"])
        // adb shell joins argv before Android /system/bin/sh parses it.
        // A literal nested Java class must survive that actual shell boundary.
        let shell = Process(), output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.environment = ["ChildMain": "unexpected_expansion"]
        shell.arguments = ["-c", "printf '%s' " + leased[5]]
        shell.standardOutput = output
        try shell.run(); shell.waitUntilExit()
        precondition(shell.terminationStatus == 0)
        precondition(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain", "nested Java class expanded by adb remote shell")
        let agent = try ScrcpyADBOwnerLifetime.launchArguments(["shell", "CLASSPATH=/data/local/tmp/own.jar", "app_process", "/", "com.genymobile.scrcpy.ClipboardAgent", "galaxybridge_clipboard_0123456789abcdef"])
        precondition(agent == ["shell", "-T", "CLASSPATH=/data/local/tmp/own.jar", "app_process", "/", "'com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain'", "clipboard", "--owner-lease", "galaxybridge_clipboard_0123456789abcdef"], "raw clipboard agent lacks the same owner lease")
        precondition(ADBScrcpyServerProcessParser.processIDs("PID ARGS\n42 app_process / com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain scrcpy --owner-lease 4.1 scid=00000012\n43 app_process / com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain scrcpy --owner-lease 4.1 scid=00000013\n", scid: 18) == [42])
        do { _ = try ScrcpyADBOwnerLifetime.launchArguments(["shell", "echo", "com.genymobile.scrcpy.Server"]); preconditionFailure("malformed launch admitted") } catch {}
        let owner = try ScrcpyADBOwnerLifetime()
        owner.start()
        var descriptor = pollfd(fd: owner.pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        precondition(poll(&descriptor, 1, 1500) == 1, "initial heartbeat absent")
        var byte: UInt8 = 0
        precondition(Darwin.read(descriptor.fd, &byte, 1) == 1 && byte == 126)
        descriptor.revents = 0
        precondition(poll(&descriptor, 1, 1500) == 1, "healthy idle owner did not renew")
        precondition(Darwin.read(descriptor.fd, &byte, 1) == 1 && byte == 126)
        owner.stop(); owner.stop()
        precondition(Darwin.read(descriptor.fd, &byte, 1) == 0, "retirement did not close exact owner stdin")
        let broken = try ScrcpyADBOwnerLifetime(); try broken.pipe.fileHandleForReading.close(); broken.start()
        Thread.sleep(forTimeInterval: 0.05); broken.stop()
        print("PASS raw launch, exact SCID cleanup, initial/idle heartbeat, idempotent retirement and broken-pipe safety")
    }
}
