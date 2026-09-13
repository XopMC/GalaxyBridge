import Darwin
import Foundation
import CryptoKit

private final class Outcomes: @unchecked Sendable {
    let lock = NSLock()
    private var values: [Bool] = []
    func append(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var passed: Bool { lock.lock(); defer { lock.unlock() }; return values.allSatisfy { $0 } }
}

private enum FixtureFailure: Error { case assertion(String) }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String = "fixture assertion failed") throws {
    if try !condition() { throw FixtureFailure.assertion(message) }
}

@main enum ADBOwnedRuntimeSpec {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gb-owned-swift-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let runtime = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GB_OWNED_ADB_TEST_RUNTIME"]!)
        let executable = runtime.appendingPathComponent("adb")
        // A self-consistent manifest is insufficient: reject an unreviewed
        // executable before it runs or any persistent identity is provisioned.
        let forged = root.appendingPathComponent("forged-runtime")
        try fm.createDirectory(at: forged, withIntermediateDirectories: false)
        let ranMarker = root.appendingPathComponent("forged-ran")
        let forgedADB = forged.appendingPathComponent("adb")
        try "#!/bin/sh\ntouch '\(ranMarker.path)'\n".write(to: forgedADB, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: forgedADB.path)
        try fm.copyItem(at: runtime.appendingPathComponent("libusb-1.0.0.dylib"),
                        to: forged.appendingPathComponent("libusb-1.0.0.dylib"))
        var forgedContract = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime.appendingPathComponent("OWNED-CONTRACT.json"))) as! [String: String]
        forgedContract["adb_sha256"] = SHA256.hash(data: try Data(contentsOf: forgedADB)).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: forgedContract).write(to: forged.appendingPathComponent("OWNED-CONTRACT.json"))
        let forgedUSB = root.appendingPathComponent("forged-usb-runtime")
        try fm.copyItem(at: runtime, to: forgedUSB)
        let modifiedLibrary = forgedUSB.appendingPathComponent("libusb-1.0.0.dylib")
        var modifiedBytes = try Data(contentsOf: modifiedLibrary)
        modifiedBytes.append(0)
        try modifiedBytes.write(to: modifiedLibrary)
        var libraryContract = forgedContract
        libraryContract["adb_sha256"] = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        libraryContract["libusb_sha256"] = SHA256.hash(data: modifiedBytes).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: libraryContract).write(to: forgedUSB.appendingPathComponent("OWNED-CONTRACT.json"))
        let rejectedUSBIdentity = root.appendingPathComponent("rejected-usb-identity")
        let forgedUSBExecutable = forgedUSB.appendingPathComponent("adb")
        let libraryOwner = ADBOwnedRuntime(executableURL: forgedUSBExecutable, identityRoot: rejectedUSBIdentity, runtimeParent: root)
        do { _ = try ADBClient(ownedRuntime: libraryOwner, executableURL: forgedUSBExecutable).devices(); preconditionFailure("self-asserted library accepted") }
        catch ADBOwnedRuntimeError.invalidArtifact {}
        try require(!fm.fileExists(atPath: rejectedUSBIdentity.path), "library pin must be checked before identity creation")

        let rejectedIdentity = root.appendingPathComponent("rejected-identity")
        let rejectedOwner = ADBOwnedRuntime(executableURL: forgedADB, identityRoot: rejectedIdentity, runtimeParent: root)
        do { _ = try ADBClient(ownedRuntime: rejectedOwner, executableURL: forgedADB).devices(); preconditionFailure("self-asserted artifact accepted") }
        catch ADBOwnedRuntimeError.invalidArtifact {}
        try require(!fm.fileExists(atPath: ranMarker.path) && !fm.fileExists(atPath: rejectedIdentity.path),
                    "artifact rejection must precede execution and persistent identity creation")

        let identity = root.appendingPathComponent("identity")
        let owner = ADBOwnedRuntime(executableURL: executable, identityRoot: identity, runtimeParent: root)
        let client = try ADBClient(ownedRuntime: owner, executableURL: executable)
        try require(!fm.fileExists(atPath: identity.path), "constructing a client must not provision ADB")

        let outcomes = Outcomes()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        let other = try ADBClient(ownedRuntime: owner, executableURL: executable)
                        let devices = try other.devices()
                        outcomes.append(devices.isEmpty)
                    } catch {
                        FileHandle.standardError.write(Data("Concurrent fixture failure: \(error)\n".utf8))
                        outcomes.append(false)
                    }
                }
            }
        }
        try require(outcomes.count == 8 && outcomes.passed, "concurrent starts must coalesce")
        try require(try client.devices().isEmpty)
        let key = identity.appendingPathComponent("keys/adbkey")
        let publicKey = identity.appendingPathComponent("keys/adbkey.pub")
        let originalKey = try Data(contentsOf: key)
        let originalPublic = try Data(contentsOf: publicKey)
        try require((try fm.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int) == 0o600)
        try require((try fm.attributesOfItem(atPath: identity.path)[.posixPermissions] as? Int) == 0o700)

        let secondOwner = ADBOwnedRuntime(executableURL: executable, identityRoot: identity, runtimeParent: root)
        do {
            _ = try ADBClient(ownedRuntime: secondOwner, executableURL: executable).devices()
            preconditionFailure("two owners must not share keys concurrently")
        } catch ADBOwnedRuntimeError.alreadyOwned {}
        secondOwner.shutdown()
        try require(try client.devices().isEmpty, "failed duplicate owner must not stop the first server")

        for arguments in [["-P", "5037", "devices"], ["-L", "tcp:5037", "devices"],
                          ["kill-server"], ["start-server"], ["disconnect"],
                          ["-s", "fake", "forward", "--remove-all"]] {
            do { _ = try client.run(arguments: arguments); preconditionFailure("endpoint/lifecycle override accepted") }
            catch ADBOwnedRuntimeError.invalidCommand {}
        }

        // Host-only track-devices streams exercise the real long-running path
        // without opening a USB interface or selecting any phone.
        let first = try client.launch(serial: "fixture-only", arguments: ["track-devices"])
        let second = try client.launch(serial: "fixture-only", arguments: ["track-devices"])
        let observations = Outcomes()
        first.terminationHandler = { _ in observations.append(true) }
        try await Task.sleep(for: .milliseconds(100))
        try require(first.isRunning && second.isRunning)
        first.terminate()
        first.waitUntilExit()
        try require(second.isRunning, "closing one session cannot stop another")
        try require(try client.devices().isEmpty)
        owner.beginShutdown()
        do { _ = try owner.makeClient(); preconditionFailure("new client admitted during shutdown") }
        catch ADBOwnedRuntimeError.stopped {}
        try require(try client.devices().isEmpty, "existing leases must remain valid for cleanup")
        await Task.detached { owner.shutdown() }.value
        try require(!second.isRunning)
        owner.shutdown()
        do { _ = try client.devices(); preconditionFailure("old client silently restarted") }
        catch ADBOwnedRuntimeError.stopped {}
        // Every subprocess boundary must observe the same retired generation,
        // including combined output, socket probe, long launch and pairing stdin.
        do { _ = try client.scrcpyDisplays(serial: "fixture-only"); preconditionFailure("combined output bypassed retired owner") }
        catch ADBOwnedRuntimeError.stopped {}
        do { try client.waitForAbstractSocket(serial: "fixture-only", socketName: "fixture", timeout: 0.1); preconditionFailure("socket probe bypassed retired owner") }
        catch ADBOwnedRuntimeError.stopped {}
        do { _ = try client.launch(serial: "fixture-only", arguments: ["track-devices"]); preconditionFailure("long launch bypassed retired owner") }
        catch ADBOwnedRuntimeError.stopped {}
        do {
            try client.pair(service: WirelessADBService(name: "fixture", kind: .pairing, endpoint: "192.168.10.20:12345"),
                            code: WirelessADBPairingCode("123456")!)
            preconditionFailure("pairing bypassed retired owner")
        } catch WirelessADBSetupError.pairingRejected {}
        try require(observations.count == 1, "runtime observation replaced the session termination callback")
        try require(try Data(contentsOf: key) == originalKey)
        try require(try Data(contentsOf: publicKey) == originalPublic)

        let restarted = ADBOwnedRuntime(executableURL: executable, identityRoot: identity, runtimeParent: root)
        let newClient = try ADBClient(ownedRuntime: restarted, executableURL: executable)
        try require(try newClient.devices().isEmpty)
        try require(try Data(contentsOf: key) == originalKey, "fresh generation must preserve identity")
        do { _ = try client.devices(); preconditionFailure("old lease mutated onto replacement generation") }
        catch ADBOwnedRuntimeError.stopped {}
        restarted.shutdown()

        let interrupted = root.appendingPathComponent("interrupted")
        try fm.createDirectory(at: interrupted.appendingPathComponent("keys-pending"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let interruptedOwner = ADBOwnedRuntime(executableURL: executable, identityRoot: interrupted, runtimeParent: root)
        do { _ = try ADBClient(ownedRuntime: interruptedOwner, executableURL: executable).devices(); preconditionFailure("interrupted key generation silently reset") }
        catch ADBOwnedRuntimeError.identityNeedsRecovery {}
        try require(!fm.fileExists(atPath: interrupted.appendingPathComponent("keys").path))

        let link = root.appendingPathComponent("identity-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: identity)
        let linked = ADBOwnedRuntime(executableURL: executable, identityRoot: link, runtimeParent: root)
        do { _ = try ADBClient(ownedRuntime: linked, executableURL: executable).devices(); preconditionFailure("identity symlink accepted") }
        catch ADBOwnedRuntimeError.unsafeStorage {}

        // Pairing cancellation must reach the finite child before returning.
        let fixture = root.appendingPathComponent("pair-fixture")
        let pidFile = root.appendingPathComponent("pair-pid")
        try "#!/bin/sh\nprintf '%s' \"$$\" > '\(pidFile.path)'\nread code\nprintf '%s' \"$code\"\nexec /bin/sleep 60\n".write(to: fixture, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let pairing = try ADBClient(testingExecutableURL: fixture)
        let cancellation = ADBProcessCancellation()
        let attempt = Task.detached {
            try pairing.pair(service: WirelessADBService(name: "fixture", kind: .pairing, endpoint: "192.168.10.20:12345"),
                             code: WirelessADBPairingCode("123456")!, cancellation: cancellation)
        }
        for _ in 0..<100 {
            if fm.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        cancellation.cancel()
        do { try await attempt.value; preconditionFailure("cancelled pairing succeeded") }
        catch is CancellationError {}
        try require(kill(pid, 0) != 0 && errno == ESRCH, "pair child survived settled cancellation")
        print("Owned runtime passed: lazy/concurrent startup, real private server, persistent keys, owner lock, leases, long-process observation, drain/restart, unsafe storage, pairing cancellation.")
    }
}
