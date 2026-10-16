#if !GALAXYBRIDGE_APP_STORE
import CryptoKit
import Foundation

enum ShellCapabilityBridgeActivation {
    /// Caller must have a verified ADB binding for this same paired phone.
    /// No endpoint, command, package or path is accepted from a remote peer.
    static func activate(adb: ADBClient, serial: String) async throws {
        guard let target = ShellCapabilityBridgeActivationTarget.resolve(bundleIdentifier: Bundle.main.bundleIdentifier) else {
            throw ShellCapabilityBridgeFailure.unavailable
        }
        let generation = UUID().uuidString.lowercased()
        // Kept in the receiver's socket_name extra for wire compatibility; this
        // is now only a one-use activation ticket ID, never a socket address.
        let activationID = "gb_shell_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let server = try ScrcpyServerLocator.locate()
        let checksum = Data(SHA256.hash(data: try Data(contentsOf: server))).map { String(format: "%02x", $0) }.joined()
        let remote = "/data/local/tmp/galaxybridge-shell-\(generation).jar"
        var launched: Process?
        var launchMayBeLive = false
        let receiver = "\(target.packageName)/com.xopmc.galaxybridge.transport.shell.ShellBridgeActivationReceiver"
        let broadcast = ["-s", serial, "shell", "am", "broadcast", "-a",
            "com.xopmc.galaxybridge.ACTIVATE_SHELL_BRIDGE", "-n", receiver]
        do {
            try await Task.detached(priority: .utility) {
                try adb.push(serial: serial, localURL: server, remotePath: remote)
            }.value
            try Task.checkCancellation()
            let prepared = try await Task.detached(priority: .utility) {
                try adb.run(arguments: broadcast + ["--es", "operation", "prepare", "--es", "socket_name", activationID,
                    "--es", "token", token, "--es", "boot_generation", generation], timeout: 5)
            }.value
            guard let receipt = ShellCapabilityBridgeActivationReceipt.parse(prepared, generation: generation),
                  !receipt.available, receipt.state == "prepared", receipt.errorCode.isEmpty else {
                throw ShellCapabilityBridgeFailure.operationFailed
            }
            try Task.checkCancellation()
            launchMayBeLive = true
            launched = try adb.launch(serial: serial, arguments: ["shell", "CLASSPATH=\(remote)", "app_process", "/",
                "'com.genymobile.scrcpy.ShellCapabilityBridge$Bootstrap'", activationID, token, generation, checksum, target.runtimeMode])
            let deadline = ContinuousClock.now + .seconds(10)
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ShellCapabilityBridgeFailure.timeout }
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let timeout = min(2, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
                guard timeout > 0 else { throw ShellCapabilityBridgeFailure.timeout }
                let status = try await Task.detached(priority: .utility) {
                    try adb.run(arguments: broadcast + ["--es", "operation", "status", "--es", "boot_generation", generation], timeout: timeout)
                }.value
                guard let receipt = ShellCapabilityBridgeActivationReceipt.parse(status, generation: generation), receipt.errorCode.isEmpty else {
                    throw ShellCapabilityBridgeFailure.operationFailed
                }
                if receipt.available, receipt.state == "ready" { break }
                guard ["prepared", "attaching"].contains(receipt.state) else { throw ShellCapabilityBridgeFailure.operationFailed }
                try await Task.sleep(for: .milliseconds(200))
            }
            // The Helper now owns a private lifetime FD. Closing the local
            // ADB client must not kill the setsid shell capability process.
            if launched?.isRunning == true { launched?.terminate() }
        } catch {
            if launched?.isRunning == true { launched?.terminate() }
            if !launchMayBeLive {
                // This exact unique file cannot belong to a launched process.
                _ = try? await Task.detached(priority: .utility) {
                    try adb.run(arguments: ["-s", serial, "shell", "rm", "-f", "--", remote], timeout: 2)
                }.value
            }
            // Before accepting an owner, the bridge exits after ten seconds.
            // Never unlink a possibly live JVM's JAR from the Mac failure path.
            throw ShellCapabilityBridgeFailure.operationFailed
        }
    }
}
#endif
