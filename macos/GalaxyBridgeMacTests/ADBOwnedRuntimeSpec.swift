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

        let identity = root.appendingPathComponent("identity with spaces")
        let owner = ADBOwnedRuntime(executableURL: executable, identityRoot: identity, runtimeParent: root)
        let client = try ADBClient(ownedRuntime: owner, executableURL: executable)
        try require(client.acquiredGeneration == nil && !client.acquiredGenerationIsRetired && owner.activeGeneration == nil,
            "observing an unused client must not acquire a daemon generation")
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
        let hostFeatures = try client.run(arguments: ["host-features"])
        guard hostFeatures.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "delayed_ack" })
        else { print("FAIL: owned ADB server has no negotiated burst-mode capability"); exit(1) }
        let nativeChild = try client.nativeChildCommand(arguments: ["devices", "-l"])
        try require(nativeChild.program == "/usr/bin/env" && nativeChild.arguments.first == "-i")
        let nativeResult = try ADBCommandRunner(executableURL: URL(fileURLWithPath: nativeChild.program))
            .run(arguments: nativeChild.arguments)
        try require(nativeResult.exitCode == 0, "native transport child must inherit owned keys and endpoint without aborting")
        try require(String(decoding: nativeResult.stdout, as: UTF8.self).contains("List of devices attached"))
        try require(nativeChild.arguments.contains("GALAXYBRIDGE_ADB_USER_DIR=" + identity.appendingPathComponent("keys").path))
        try require(nativeChild.arguments.contains("-L"), "native transport must not fall through to system ADB")
        try require(nativeChild.arguments.contains("ADB_BURST_MODE=1"), "native child must share the owned transport feature policy")
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
            do { _ = try client.nativeChildCommand(arguments: arguments); preconditionFailure("native child accepted endpoint/lifecycle override") }
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
        try require(!client.acquiredGenerationIsRetired, "closing admission claimed a live daemon's forwards disappeared")
        do { _ = try owner.makeClient(); preconditionFailure("new client admitted during shutdown") }
        catch ADBOwnedRuntimeError.stopped {}
        try require(try client.devices().isEmpty, "existing leases must remain valid for cleanup")
        await Task.detached { owner.shutdown() }.value
        try require(!second.isRunning)
        owner.shutdown()
        try require(client.acquiredGenerationIsRetired, "reaped daemon did not prove its local listeners absent")
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

        // Kill only this fixture's USB-disabled daemon. A fresh client may
        // recover the owner; a frozen old lease must never migrate implicitly.
        let recovering = ADBOwnedRuntime(executableURL: executable, identityRoot: identity, runtimeParent: root)
        defer { recovering.shutdown() }
        let crashedClient = try ADBClient(ownedRuntime: recovering, executableURL: executable)
        try require(try crashedClient.devices().isEmpty)
        let frozenGeneration = crashedClient.acquiredGeneration
        try require(frozenGeneration != nil && frozenGeneration == recovering.activeGeneration,
            "client did not observe its acquired generation")
        let oldChild = try crashedClient.nativeChildCommand(arguments: ["devices"])
        let oldEndpointIndex = oldChild.arguments.firstIndex(of: "-L")!
        let oldEndpoint = oldChild.arguments[oldEndpointIndex + 1]
        let abandoned = try crashedClient.launch(serial: "fixture-only", arguments: ["track-devices"])
        let processList = try ADBCommandRunner(executableURL: URL(fileURLWithPath: "/bin/ps"))
            .run(arguments: ["-axo", "pid=,ppid=,command="])
        let expected = executable.path + " -L " + oldEndpoint + " nodaemon server"
        let daemonIDs = String(decoding: processList.stdout, as: UTF8.self).split(separator: "\n").compactMap { line -> Int32? in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, Int32(fields[1]) == getpid(), String(fields[2]) == expected else { return nil }
            return Int32(fields[0])
        }
        try require(daemonIDs.count == 1, "fixture daemon identity is ambiguous")
        try require(kill(daemonIDs[0], SIGKILL) == 0, "fixture daemon kill failed")
        var retired = false
        for _ in 0..<100 {
            do { _ = try crashedClient.devices() }
            catch ADBOwnedRuntimeError.stopped { retired = true; break }
            catch { }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(retired, "crashed generation was not invalidated")
        try require(crashedClient.acquiredGenerationIsRetired, "daemon exit did not retire its local listener ownership")
        try require(recovering.activeGeneration == nil && crashedClient.acquiredGeneration == frozenGeneration,
            "daemon death must invalidate current observation without erasing the old lease identity")
        let recoveredClient = try ADBClient(ownedRuntime: recovering, executableURL: executable)
        try require(try recoveredClient.devices().isEmpty, "a new client could not recover after unexpected daemon exit")
        try require(!recoveredClient.acquiredGenerationIsRetired && crashedClient.acquiredGenerationIsRetired,
            "new and retired local listener ownership were confused")
        let recoveredChild = try recoveredClient.nativeChildCommand(arguments: ["devices"])
        let newEndpoint = recoveredChild.arguments[recoveredChild.arguments.firstIndex(of: "-L")! + 1]
        try require(oldEndpoint != newEndpoint, "recovery reused the retired private socket")
        try require(recoveredClient.acquiredGeneration == recovering.activeGeneration
            && recoveredClient.acquiredGeneration != frozenGeneration && crashedClient.acquiredGeneration == frozenGeneration,
            "generation observation migrated an old client or failed to distinguish a fresh one")
        try require(!abandoned.isRunning, "recovery retained an old generation's subprocess")
        do { _ = try crashedClient.devices(); preconditionFailure("old client migrated onto recovered daemon") }
        catch ADBOwnedRuntimeError.stopped {}
        try require(try Data(contentsOf: key) == originalKey && Data(contentsOf: publicKey) == originalPublic,
            "daemon recovery changed persistent identity")
        recovering.beginShutdown()
        do { _ = try recovering.makeClient(); preconditionFailure("recovery bypassed explicit shutdown admission") }
        catch ADBOwnedRuntimeError.stopped {}
        recovering.shutdown()

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
        var childPID: Int32?
        for _ in 0..<100 {
            // Creation can precede printf's first bytes; an existing empty
            // file is not evidence that the fixture has published its PID.
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text), pid > 0 { childPID = pid; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let pid = childPID else {
            cancellation.cancel()
            _ = try? await attempt.value
            throw FixtureFailure.assertion("pairing fixture did not publish its PID")
        }
        cancellation.cancel()
        do { try await attempt.value; preconditionFailure("cancelled pairing succeeded") }
        catch is CancellationError {}
        try require(kill(pid, 0) != 0 && errno == ESRCH, "pair child survived settled cancellation")
        print("Owned runtime passed: lazy/concurrent startup, real private server, persistent keys, owner lock, leases, long-process observation, drain/restart, unexpected daemon recovery with frozen old leases, unsafe storage, pairing cancellation.")
    }
}
