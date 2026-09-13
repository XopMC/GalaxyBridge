#if !GALAXYBRIDGE_APP_STORE
import CryptoKit
import Darwin
import Foundation
import GalaxyBridgeBuildPins

enum ADBOwnedRuntimeError: Error, LocalizedError {
    case unavailable, invalidArtifact, unsafeStorage, identityNeedsRecovery, alreadyOwned, stopped, invalidCommand
    var errorDescription: String? {
        switch self {
        case .unavailable, .invalidArtifact: String(localized: "ADB_BUNDLED_RUNTIME_MISSING")
        case .unsafeStorage, .identityNeedsRecovery: String(localized: "ADB_OWNED_IDENTITY_RECOVERY")
        case .alreadyOwned: String(localized: "ADB_OWNED_ALREADY_RUNNING")
        case .stopped: String(localized: "ADB_OWNED_SESSION_ENDED")
        case .invalidCommand: String(localized: "ADB_OWNED_OPERATION_REJECTED")
        }
    }
}

struct ADBRuntimeConfiguration: Sendable {
    let executableURL: URL
    let generation: UUID
    let endpoint: String
    let environment: [String: String]
    let processes: ADBProcessRegistry
    var argumentPrefix: [String] { ["-L", endpoint] }

    func validate(_ arguments: [String]) throws {
        var command = arguments
        if command.first == "-s" {
            guard command.count >= 3, !command[1].isEmpty else { throw ADBOwnedRuntimeError.invalidCommand }
            command.removeFirst(2)
        }
        guard let verb = command.first, !verb.hasPrefix("-"),
              !["server", "nodaemon", "fork-server", "start-server", "kill-server", "reconnect", "keygen", "pubkey"].contains(verb),
              !(verb == "disconnect" && command.count == 1),
              !(["forward", "reverse"].contains(verb) && command.contains("--remove-all"))
        else { throw ADBOwnedRuntimeError.invalidCommand }
    }
    func runner(cancellation: ADBProcessCancellation? = nil) -> ADBCommandRunner {
        ADBCommandRunner(executableURL: executableURL, environment: environment,
                         argumentPrefix: argumentPrefix, processRegistry: processes, cancellation: cancellation)
    }
}

/// A client never silently migrates onto a replacement generation. The shared
/// owner is lazy, while this reference pins its first successfully acquired one.
final class ADBOwnedRuntimeClient: @unchecked Sendable {
    private let lock = NSLock()
    private let owner: ADBOwnedRuntime
    private var configuration: ADBRuntimeConfiguration?
    init(owner: ADBOwnedRuntime) { self.owner = owner }
    func acquire() throws -> ADBRuntimeConfiguration {
        lock.lock(); defer { lock.unlock() }
        if let configuration {
            try owner.validate(generation: configuration.generation)
            return configuration
        }
        let result = try owner.acquire()
        configuration = result
        return result
    }
}

/// One owner per app process. No file, key or process is created by this static
/// initialization: Companion-only users never need to initialize ADB.
enum ADBOwnedUSBPolicy: String, Sendable {
    case disabled = "disabled"
    case nonSeizingUSB = "usb-nonseizing-v1"
}

final class ADBOwnedRuntime: @unchecked Sendable {
    // Build-specific, ad-hoc signed arm64 artifact from the pinned source + all three
    // owned-runtime patches. A self-asserted manifest cannot authorize an SDK
    // binary that might touch ~/.android before rejecting our runtime marker.
    static let pinnedADBSHA256 = GalaxyBridgeBuildPins.adbSHA
    static let shared = ADBOwnedRuntime(
        executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/platform-tools/adb"),
        identityRoot: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GalaxyBridgeADB/owned-v1"),
        usbPolicy: .nonSeizingUSB)
    private let lock = NSRecursiveLock()
    private let executableURL: URL
    private let identityRoot: URL
    private let runtimeParent: URL
    private let usbPolicy: ADBOwnedUSBPolicy
    private var acceptingClients = true
    private var configuration: ADBRuntimeConfiguration?
    private var server: Process?
    private var lifetime: Pipe?
    private var runDirectory: URL?
    private var ownershipFD: Int32 = -1
    private var failed = false

    /// Explicit paths are used by controlled fixtures. Production uses shared.
    init(executableURL: URL, identityRoot: URL, runtimeParent: URL = URL(fileURLWithPath: "/private/tmp"),
         usbPolicy: ADBOwnedUSBPolicy = .disabled) {
        self.executableURL = executableURL
        self.identityRoot = identityRoot
        self.runtimeParent = runtimeParent
        self.usbPolicy = usbPolicy
    }
    deinit { shutdown() }

    func makeClient() throws -> ADBOwnedRuntimeClient {
        lock.lock(); defer { lock.unlock() }
        guard acceptingClients, !failed else { throw ADBOwnedRuntimeError.stopped }
        return ADBOwnedRuntimeClient(owner: self)
    }

    private static func privateDirectory(_ url: URL, create: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, create else { throw ADBOwnedRuntimeError.unsafeStorage }
            try privateDirectory(url.deletingLastPathComponent(), create: true, allowExistingAncestor: true)
            guard mkdir(url.path, 0o700) == 0 else { throw ADBOwnedRuntimeError.unsafeStorage }
        }
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().path
        else { throw ADBOwnedRuntimeError.unsafeStorage }
    }
    private static func privateDirectory(_ url: URL, create: Bool, allowExistingAncestor: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR,
                  url.standardizedFileURL.path == url.resolvingSymlinksInPath().path
            else { throw ADBOwnedRuntimeError.unsafeStorage }
            return
        }
        try privateDirectory(url, create: create)
    }
    private static func privateFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1
        else { throw ADBOwnedRuntimeError.identityNeedsRecovery }
    }

    private func validateArtifact() throws {
        let directory = executableURL.deletingLastPathComponent()
        let contractURL = directory.appendingPathComponent("OWNED-CONTRACT.json")
        guard executableURL.lastPathComponent == "adb",
              let data = try? Data(contentsOf: contractURL),
              let contract = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              contract["contract"] == "galaxybridge-owned-adb-v2",
              contract["usb_policy"] == "nonseizing-v1",
              let expectedADB = contract["adb_sha256"], expectedADB == Self.pinnedADBSHA256,
              let expectedUSB = contract["libusb_sha256"], expectedUSB == GalaxyBridgeBuildPins.libusbSHA
        else { throw ADBOwnedRuntimeError.invalidArtifact }
        for (name, expected) in [("adb", expectedADB), ("libusb-1.0.0.dylib", expectedUSB)] {
            let url = directory.appendingPathComponent(name)
            guard url.path == url.resolvingSymlinksInPath().path,
                  let bytes = try? Data(contentsOf: url),
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected
            else { throw ADBOwnedRuntimeError.invalidArtifact }
        }
    }

    private func acquireOwnerLock() throws {
        let url = identityRoot.appendingPathComponent("owner.lock")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ADBOwnedRuntimeError.unsafeStorage }
        do {
            try Self.privateFile(url)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ADBOwnedRuntimeError.alreadyOwned }
            ownershipFD = descriptor
        } catch { close(descriptor); throw error }
    }

    private func prepareKeys(environment: [String: String], endpoint: String) throws {
        let keys = identityRoot.appendingPathComponent("keys")
        var info = stat()
        if lstat(keys.path, &info) != 0 {
            guard errno == ENOENT else { throw ADBOwnedRuntimeError.identityNeedsRecovery }
            // Generation in a separate directory is atomic. A crash cannot make
            // an established identity look like a first launch.
            let pending = identityRoot.appendingPathComponent("keys-pending")
            guard lstat(pending.path, &info) != 0, errno == ENOENT else { throw ADBOwnedRuntimeError.identityNeedsRecovery }
            try Self.privateDirectory(pending, create: true)
            var childEnvironment = environment
            childEnvironment["GALAXYBRIDGE_ADB_USER_DIR"] = pending.path
            let generated = try ADBCommandRunner(executableURL: executableURL, environment: childEnvironment,
                argumentPrefix: ["-L", endpoint]).run(arguments: ["keygen", pending.appendingPathComponent("adbkey").path])
            guard generated.exitCode == 0 else { throw ADBOwnedRuntimeError.identityNeedsRecovery }
            try Self.privateFile(pending.appendingPathComponent("adbkey"))
            try Self.privateFile(pending.appendingPathComponent("adbkey.pub"))
            guard rename(pending.path, keys.path) == 0 else { throw ADBOwnedRuntimeError.identityNeedsRecovery }
        }
        try Self.privateDirectory(keys, create: false)
        for name in ["adbkey", "adbkey.pub"] { try Self.privateFile(keys.appendingPathComponent(name)) }
        let trust = keys.appendingPathComponent("adb_known_hosts.pb")
        if lstat(trust.path, &info) == 0 { try Self.privateFile(trust) }
        else if errno != ENOENT { throw ADBOwnedRuntimeError.identityNeedsRecovery }
        let checked = try ADBCommandRunner(executableURL: executableURL, environment: environment,
            argumentPrefix: ["-L", endpoint]).run(arguments: ["pubkey", keys.appendingPathComponent("adbkey").path])
        guard checked.exitCode == 0,
              let publicKey = try? String(contentsOf: keys.appendingPathComponent("adbkey.pub"), encoding: .utf8),
              String(decoding: checked.stdout, as: UTF8.self).split(separator: " ").first == publicKey.split(separator: " ").first
        else { throw ADBOwnedRuntimeError.identityNeedsRecovery }
    }

    fileprivate func acquire() throws -> ADBRuntimeConfiguration {
        lock.lock(); defer { lock.unlock() }
        guard acceptingClients, !failed else { throw ADBOwnedRuntimeError.stopped }
        if let configuration { try validate(generation: configuration.generation); return configuration }
        do {
            try validateArtifact()
            try Self.privateDirectory(identityRoot, create: true)
            try acquireOwnerLock()
            let run = runtimeParent.appendingPathComponent("gb-adb-\(UUID().uuidString.prefix(12))")
            // Darwin sockaddr_un.sun_path is 104 bytes including the terminator.
            let path = run.appendingPathComponent("s").path
            guard path.utf8.count < 104 else { throw ADBOwnedRuntimeError.unsafeStorage }
            guard mkdir(run.path, 0o700) == 0 else { throw ADBOwnedRuntimeError.unsafeStorage }
            runDirectory = run
            try Self.privateDirectory(run, create: false)
            let endpoint = "localfilesystem:" + path
            let environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C",
                "GALAXYBRIDGE_ADB_USER_DIR": identityRoot.appendingPathComponent("keys").path,
                "GALAXYBRIDGE_ADB_PARENT_PIPE": "stdin-v1", "ADB_USB": "0", "ADB_EMU": "0",
                "GALAXYBRIDGE_ADB_USB_POLICY": usbPolicy.rawValue,
                "ADB_REJECT_KILL_SERVER": "1", "ADB_TRACE": "", "ANDROID_ADB_LOG_PATH": "/dev/null"]
            // Probe the reviewed binary contract with an empty, temporary key
            // directory before allowing any persistent identity generation.
            let probeKeys = run.appendingPathComponent("probe")
            try Self.privateDirectory(probeKeys, create: true)
            var probeEnvironment = environment
            probeEnvironment["GALAXYBRIDGE_ADB_USER_DIR"] = probeKeys.path
            let contract = try ADBCommandRunner(executableURL: executableURL, environment: probeEnvironment)
                .run(arguments: ["gb-runtime-contract"], timeout: 2, outputLimit: 1024)
            guard contract.exitCode == 0,
                  String(decoding: contract.stdout, as: UTF8.self) == "galaxybridge-owned-adb-v2 keydir-only no-autostart parent-stdin usb-nonseizing-optin\n"
            else { throw ADBOwnedRuntimeError.invalidArtifact }
            try FileManager.default.removeItem(at: probeKeys)
            try prepareKeys(environment: environment, endpoint: endpoint)
            let process = Process(), pipe = Pipe()
            process.executableURL = executableURL
            process.environment = environment
            process.arguments = ["-L", endpoint, "nodaemon", "server"]
            process.standardInput = pipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            server = process; lifetime = pipe
            try pipe.fileHandleForReading.close()
            let result = ADBRuntimeConfiguration(executableURL: executableURL, generation: UUID(), endpoint: endpoint,
                                                 environment: environment, processes: ADBProcessRegistry())
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                if let status = try? result.runner().run(arguments: ["devices", "-l"], timeout: 0.25, outputLimit: 4096),
                   status.exitCode == 0, process.isRunning {
                    configuration = result
                    return result
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw ADBOwnedRuntimeError.unavailable
        } catch {
            failed = true
            releaseResources()
            throw error
        }
    }

    fileprivate func validate(generation: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failed, configuration?.generation == generation, server?.isRunning == true else {
            throw ADBOwnedRuntimeError.stopped
        }
    }
    /// Root calls this before cancelling discovery and draining media cleanup.
    func beginShutdown() { lock.lock(); acceptingClients = false; lock.unlock() }
    /// Root calls this after all session-owned forward/keyboard cleanup settles.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        acceptingClients = false
        configuration?.processes.drainAndCancel(timeout: 1)
        releaseResources()
    }
    private func releaseResources() {
        try? lifetime?.fileHandleForWriting.close()
        lifetime = nil
        if let server { ADBProcessRegistry.stopAndReap(server) }
        server = nil; configuration = nil
        if let runDirectory { try? FileManager.default.removeItem(at: runDirectory) }
        runDirectory = nil
        if ownershipFD >= 0 { flock(ownershipFD, LOCK_UN); close(ownershipFD); ownershipFD = -1 }
    }
}
#endif
