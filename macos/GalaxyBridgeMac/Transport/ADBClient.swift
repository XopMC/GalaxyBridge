#if !GALAXYBRIDGE_APP_STORE
import Darwin
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore

enum ADBClientError: Error, LocalizedError {
    case executableNotFound
    case bundledExecutableNotFound
    case commandFailed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound: String(localized: "ADB_NOT_FOUND")
        case .bundledExecutableNotFound: String(localized: "ADB_BUNDLED_RUNTIME_MISSING")
        case .commandFailed: String(localized: "ERROR_ADB_COMMAND")
        }
    }
}

enum ADBDistributionChannel: Sendable {
    case internalDevelopment
    case developerID

    init(infoDictionaryValue: String?) {
        switch infoDictionaryValue {
        case "developer-id", "github-direct":
            self = .developerID
        default:
            self = .internalDevelopment
        }
    }
}

struct ADBPhysicalDisplaySize: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum ADBPhysicalDisplaySizeParser {
    static func parse(_ output: String) -> ADBPhysicalDisplaySize? {
        let pattern = #"(?:Physical size|Override size):\s*(\d+)x(\d+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        let matches = expression.matches(in: output, range: range)
        // `wm size` may print both physical and override values. Android's
        // input command targets the currently logical display size, so prefer
        // the last (override) record when it exists.
        guard let match = matches.last,
              let widthRange = Range(match.range(at: 1), in: output),
              let heightRange = Range(match.range(at: 2), in: output),
              let width = Int(output[widthRange]),
              let height = Int(output[heightRange]),
              width > 0,
              height > 0
        else { return nil }
        return ADBPhysicalDisplaySize(width: width, height: height)
    }
}

/// Parses only the exact scrcpy server instance owned by a session. This is
/// deliberately separate from the ADB process runner so malformed `ps` output
/// can never broaden cleanup to unrelated Android processes.
enum ADBScrcpyServerProcessParser {
    static func processIDs(_ output: String, scid: UInt32) -> [Int32] {
        guard scid > 0, scid <= 0x7FFF_FFFF else { return [] }
        let expectedSCID = String(format: "scid=%08x", scid)
        var result = Set<Int32>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  let processID = Int32(fields[0]),
                  processID > 1,
                  fields.contains("com.genymobile.scrcpy.Server"),
                  fields.contains(where: { $0 == Substring(expectedSCID) })
            else { continue }
            result.insert(processID)
        }
        return result.sorted()
    }
}

struct ADBExecutableResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(
        distribution: ADBDistributionChannel,
        bundleURL: URL,
        installedCandidates: [URL]
    ) -> URL? {
        let bundledCandidate = bundleURL
            .appendingPathComponent("Contents/Resources/platform-tools/adb", isDirectory: false)
        let orderedCandidates: [URL]
        switch distribution {
        case .internalDevelopment:
            orderedCandidates = installedCandidates + [bundledCandidate]
        case .developerID:
            orderedCandidates = [bundledCandidate]
        }
        return orderedCandidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

struct ADBClient: Sendable {
    let executableURL: URL
    func prepareQuicExecutable(serial: String, remotePath: String) throws {
        guard remotePath.hasPrefix("/data/local/tmp/gb-quic-"), remotePath.hasSuffix("-backend"),
              remotePath.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || [45, 47].contains($0) }) else {
            throw ADBClientError.commandFailed(code: -1, message: "Invalid exact QUIC artifact path")
        }
        _ = try runRemoteShell(serial: serial, arguments: ["chmod", "700", remotePath])
    }
    private let distribution: ADBDistributionChannel
    private let ownedRuntime: ADBOwnedRuntimeClient?
    private var commandCancellation: ADBProcessCancellation? = nil

    /// Explicit fake-process injection is confined to test call sites. Public
    /// distribution construction never accepts an installed executable override.
    init(testingExecutableURL: URL, distribution: ADBDistributionChannel = .internalDevelopment) throws {
        self.executableURL = testingExecutableURL
        self.distribution = distribution
        self.ownedRuntime = nil
    }

    init(ownedRuntime: ADBOwnedRuntime, executableURL: URL) throws {
        self.executableURL = executableURL
        self.distribution = .developerID
        self.ownedRuntime = try ownedRuntime.makeClient()
    }

    init(distribution: ADBDistributionChannel? = nil) throws {
        let channel = Bundle.main.object(forInfoDictionaryKey: "GalaxyBridgeDistribution") as? String
        if distribution == nil, Bundle.main.bundleIdentifier == "com.xopmc.GalaxyBridge",
           channel != "github-direct", channel != "developer-id" {
            throw ADBOwnedRuntimeError.invalidArtifact
        }
        self.distribution = distribution ?? ADBDistributionChannel(infoDictionaryValue: channel)
        self.ownedRuntime = self.distribution == .developerID ? try ADBOwnedRuntime.shared.makeClient() : nil
        let fileManager = FileManager.default
        let installedCandidates = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Android/sdk/platform-tools/adb"),
            URL(fileURLWithPath: "/opt/homebrew/bin/adb"),
            URL(fileURLWithPath: "/usr/local/bin/adb"),
        ]
        guard let executableURL = ADBExecutableResolver(fileManager: fileManager).resolve(
            distribution: self.distribution,
            bundleURL: Bundle.main.bundleURL,
            installedCandidates: installedCandidates
        ) else {
            if case .developerID = self.distribution {
                throw ADBClientError.bundledExecutableNotFound
            }
            throw ADBClientError.executableNotFound
        }
        self.executableURL = executableURL
    }

    func devices() throws -> [ADBDevice] {
        let output = try run(arguments: ["devices", "-l"])
        return ADBDeviceParser.parse(output)
    }

    func wifiIPv4Address(serial: String) throws -> String {
        let output = try runRemoteShell(
            serial: serial,
            arguments: ["ip", "-o", "-4", "addr", "show", "dev", "wlan0"]
        )
        guard let address = ADBWiFiIPv4AddressParser.parse(output) else {
            throw ADBClientError.commandFailed(
                code: -1,
                message: "Galaxy Wi-Fi address is unavailable"
            )
        }
        return address
    }

    func connect(host: String, port: UInt16) throws -> String {
        try connect(endpoint: "\(host):\(port)")
    }

    func connect(endpoint: String) throws -> String {
        try run(arguments: ["connect", endpoint], timeout: 3)
    }

    func mdnsServices() throws -> String {
        try run(arguments: ["mdns", "services"], timeout: 2)
    }

    func hardwareSerial(serial: String) throws -> String {
        try run(arguments: ["-s", serial, "shell", "getprop", "ro.serialno"], timeout: 2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func forward(serial: String, local: String, remote: String) throws {
        _ = try run(arguments: ["-s", serial, "forward", local, remote])
    }

    func forwardAutomatically(serial: String, socketName: String) throws -> UInt16 {
        let output = try run(arguments: ["-s", serial, "forward", "tcp:0", "localabstract:\(socketName)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(output), port > 0 else {
            throw ADBClientError.commandFailed(code: -1, message: "adb returned an invalid forwarded port: \(output)")
        }
        return port
    }

    func waitForAbstractSocket(
        serial: String,
        socketName: String,
        timeout: TimeInterval = 2
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // Do not read all of /proc/net/unix here. On Samsung builds it can exceed
            // a Process Pipe buffer, while run(arguments:) waits for adb to exit
            // before draining stdout. Limit the remote output to the matching line.
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            if try hasAbstractSocket(
                serial: serial,
                socketName: socketName,
                commandTimeout: min(0.5, remaining),
            ) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw ADBClientError.commandFailed(
            code: -1,
            message: "scrcpy server socket @\(socketName) was not ready within \(timeout) seconds"
        )
    }

    private func hasAbstractSocket(
        serial: String,
        socketName: String,
        commandTimeout: TimeInterval
    ) throws -> Bool {
        let result: ADBCommandRunner.Result
        do {
            result = try runCommand(arguments: [
                "-s", serial, "shell", "grep", "-F", "@\(socketName)", "/proc/net/unix",
            ], timeout: commandTimeout)
        } catch ADBCommandRunner.Failure.timedOut {
            return false
        }
        guard result.exitCode == 0 else { return false }
        let match = String(decoding: result.stdout, as: UTF8.self)
        return match.split(whereSeparator: \.isNewline).contains { $0.hasSuffix("@\(socketName)") }
    }

    func removeForward(serial: String, port: UInt16) throws {
        _ = try run(arguments: ["-s", serial, "forward", "--remove", "tcp:\(port)"])
    }

    /// Retires one capture-free scrcpy helper without matching another screen,
    /// app-window, or clipboard session. Repeated probes cover the short race
    /// where the local adb process is terminated while Android is still
    /// entering `app_process`.
    func retireScrcpyServer(serial: String, scid: UInt32) throws {
        guard scid > 0, scid <= 0x7FFF_FFFF else { return }
        let maximumProbeCount = 5
        for probeIndex in 0 ..< maximumProbeCount {
            let output = try runRemoteShell(
                serial: serial,
                arguments: ["ps", "-A", "-o", "PID,ARGS"]
            )
            let processIDs = ADBScrcpyServerProcessParser.processIDs(output, scid: scid)
            if !processIDs.isEmpty {
                _ = try runRemoteShell(
                    serial: serial,
                    arguments: ["kill"] + processIDs.map(String.init)
                )
            }
            if probeIndex + 1 < maximumProbeCount {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        let remainingOutput = try runRemoteShell(
            serial: serial,
            arguments: ["ps", "-A", "-o", "PID,ARGS"]
        )
        let remaining = ADBScrcpyServerProcessParser.processIDs(remainingOutput, scid: scid)
        guard remaining.isEmpty else {
            throw ADBClientError.commandFailed(
                code: -1,
                message: "scrcpy server \(String(format: "%08x", scid)) did not stop"
            )
        }
    }

    func reverse(serial: String, socketName: String, hostPort: UInt16) throws {
        _ = try run(arguments: [
            "-s", serial, "reverse",
            "localabstract:\(socketName)", "tcp:\(hostPort)",
        ])
    }

    func removeReverse(serial: String, socketName: String) throws {
        _ = try run(arguments: [
            "-s", serial, "reverse", "--remove", "localabstract:\(socketName)",
        ])
    }

    func push(serial: String, localURL: URL, remotePath: String) throws {
        _ = try run(arguments: ["-s", serial, "push", "-q", localURL.path, remotePath], timeout: 3600)
    }

    func pull(serial: String, remotePath: String, localURL: URL) throws {
        _ = try run(arguments: ["-s", serial, "pull", "-q", remotePath, localURL.path], timeout: 3600)
    }

    func pushVerified(
        serial: String,
        localURL: URL,
        remotePath: String,
        expectedSHA256Hex: String
    ) throws {
        precondition(remotePath.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) })
        try push(serial: serial, localURL: localURL, remotePath: remotePath)
        let output = try run(arguments: ["-s", serial, "shell", "toybox", "sha256sum", remotePath])
        guard output.split(whereSeparator: \.isWhitespace).first?.lowercased() == expectedSHA256Hex.lowercased() else {
            throw ADBClientError.commandFailed(code: -1, message: "remote SHA-256 mismatch")
        }
    }

    func scrcpyDisplays(serial: String) throws -> [ScrcpyDisplay] {
        let output = try runCombined(arguments: [
            "-s", serial,
            "shell",
            "CLASSPATH=\(ScrcpyLaunchConfiguration.remoteServerPath)",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            ScrcpyLaunchConfiguration.serverVersion,
            "list_displays=true",
            "cleanup=false",
        ])
        return ScrcpyDisplayParser.parse(output)
    }

    func scrcpyDisplays(serial: String, serverURL: URL) throws -> [ScrcpyDisplay] {
        try pushVerified(
            serial: serial,
            localURL: serverURL,
            remotePath: ScrcpyLaunchConfiguration.remoteServerPath,
            expectedSHA256Hex: ScrcpyLaunchConfiguration.serverSHA256Hex
        )
        return try scrcpyDisplays(serial: serial)
    }

    /// Uses scrcpy's pinned, versioned application-list protocol for labels and
    /// package names. Android's public package-manager command contributes the
    /// launcher component in one bounded pass, avoiding one shell process per app.
    func scrcpyApplications(serial: String) throws -> [ScrcpyApplication] {
        let listOutput = try runCombined(arguments: [
            "-s", serial,
            "shell",
            "CLASSPATH=\(ScrcpyLaunchConfiguration.remoteServerPath)",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            ScrcpyLaunchConfiguration.serverVersion,
            "list_apps=true",
            "cleanup=false",
        ])
        let componentOutput = try runRemoteShell(serial: serial, arguments: [
            "cmd", "package", "query-activities",
            "--brief", "--components",
            "-a", "android.intent.action.MAIN",
            "-c", "android.intent.category.LAUNCHER",
        ])
        let components = ScrcpyLaunchableComponentParser.parse(componentOutput)
        return ScrcpyApplicationListParser.parse(listOutput).map { application in
            ScrcpyApplication(
                packageName: application.packageName,
                componentName: components[application.packageName],
                label: application.label,
                isSystem: application.isSystem
            )
        }
    }

    func openDeepLink(serial: String, url: URL) throws {
        let userID = try foregroundAndroidUser(serial: serial)
        guard let applicationID = try selectedCompanionPackage(serial: serial, userID: userID) else {
            throw ADBClientError.commandFailed(code: -1, message: "GalaxyBridge Android companion is not installed")
        }
        _ = try runRemoteShell(serial: serial, arguments: [
            "am", "start",
            "--user", userID,
            "-W",
            "-a", "android.intent.action.VIEW",
            "-d", url.absoluteString,
            "-n", "\(applicationID)/com.xopmc.galaxybridge.MainActivity",
        ])
    }

    /// Sends committed hardware-keyboard text to the focused Android editor
    /// through the selected companion's shell-protected Accessibility bridge.
    /// Base64 keeps arbitrary Unicode out of shell parsing and command logs.
    func injectRemoteText(serial: String, text: String) throws -> Bool {
        let boundedText = String(text.prefix(4_096))
        guard !boundedText.isEmpty else { return false }
        let userID = try foregroundAndroidUser(serial: serial)
        guard let applicationID = try selectedCompanionPackage(serial: serial, userID: userID) else { return false }
        let action = "com.xopmc.galaxybridge.INJECT_REMOTE_TEXT"
        let receiver = "com.xopmc.galaxybridge.service.RemoteTextInputReceiver"
        guard try hasReceiver(
            serial: serial,
            userID: userID,
            applicationID: applicationID,
            receiver: receiver,
            action: action
        ) else { return false }
        let payload = Data(boundedText.utf8).base64EncodedString()
        let output = try runRemoteShell(serial: serial, arguments: [
            "am", "broadcast", "--user", userID, "-W", "--receiver-foreground",
            "-a", action,
            "-n", "\(applicationID)/\(receiver)",
            "--es", "text_b64", payload,
        ])
        return Self.broadcastSucceeded(output)
    }

    func physicalDisplaySize(serial: String) throws -> ADBPhysicalDisplaySize {
        let output = try runRemoteShell(serial: serial, arguments: ["wm", "size"])
        guard let size = ADBPhysicalDisplaySizeParser.parse(output) else {
            throw ADBClientError.commandFailed(code: -1, message: "adb returned an invalid physical display size")
        }
        return size
    }

    func displayBrightness(serial: String) throws -> Double {
        let output = try runRemoteShell(
            serial: serial,
            arguments: ["cmd", "display", "get-brightness"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let brightness = Double(output), brightness.isFinite, (0 ... 1).contains(brightness) else {
            throw ADBClientError.commandFailed(code: -1, message: "adb returned an invalid display brightness")
        }
        return brightness
    }

    func setDisplayBrightness(serial: String, brightness: Double) throws {
        let clamped = min(max(brightness, 0), 1)
        _ = try runRemoteShell(
            serial: serial,
            arguments: ["cmd", "display", "set-brightness", String(clamped)]
        )
    }

    /// Wakes the physical lock screen without dismissing keyguard or injecting
    /// an unlock gesture. Samsung does not reliably wake from scrcpy's
    /// SET_DISPLAY_POWER(true) after the user presses the hardware power key.
    func wakePhysicalDisplay(serial: String) throws {
        _ = try runRemoteShell(
            serial: serial,
            arguments: ["input", "keyevent", "KEYCODE_WAKEUP"]
        )
    }

    func physicalDisplayState(serial: String) throws -> PhysicalDisplayState {
        let output = try runRemoteShell(
            serial: serial,
            arguments: [
                "sh", "-c",
                "dumpsys power | grep -m 1 mWakefulness=",
            ]
        )
        return PhysicalDisplayProbeParser.parse(output)
    }

    /// Whether Android should also show its software IME while a physical
    /// keyboard is attached. `nil` means the user has no explicit setting.
    func showsSoftwareKeyboardWithHardware(serial: String) throws -> Bool? {
        let output = try runRemoteShell(
            serial: serial,
            arguments: ["settings", "get", "secure", "show_ime_with_hard_keyboard"]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        switch output {
        case "1", "true": return true
        case "0", "false": return false
        case "", "null": return nil
        default:
            throw ADBClientError.commandFailed(code: -1, message: "adb returned an invalid hardware-keyboard IME setting")
        }
    }

    func setShowsSoftwareKeyboardWithHardware(serial: String, enabled: Bool?) throws {
        if let enabled {
            _ = try runRemoteShell(
                serial: serial,
                arguments: [
                    "settings", "put", "secure", "show_ime_with_hard_keyboard",
                    enabled ? "1" : "0",
                ]
            )
        } else {
            _ = try runRemoteShell(
                serial: serial,
                arguments: ["settings", "delete", "secure", "show_ime_with_hard_keyboard"]
            )
        }
    }

    func injectTouch(serial: String, command: EnhancedADBTouchCommand) throws {
        try injectTouch(serial: serial, command: command, displaySize: physicalDisplaySize(serial: serial))
    }

    func injectTouch(
        serial: String,
        command: EnhancedADBTouchCommand,
        displaySize: ADBPhysicalDisplaySize
    ) throws {
        func coordinate(_ normalized: Double, extent: Int) -> String {
            let clamped = min(max(normalized, 0), 1)
            return String(Int((clamped * Double(max(0, extent - 1))).rounded()))
        }

        let arguments: [String]
        switch command {
        case let .tap(x, y):
            arguments = [
                "input", "touchscreen", "tap",
                coordinate(x, extent: displaySize.width),
                coordinate(y, extent: displaySize.height),
            ]
        case let .swipe(fromX, fromY, toX, toY, durationMilliseconds):
            arguments = [
                "input", "touchscreen", "swipe",
                coordinate(fromX, extent: displaySize.width),
                coordinate(fromY, extent: displaySize.height),
                coordinate(toX, extent: displaySize.width),
                coordinate(toY, extent: displaySize.height),
                String(min(max(durationMilliseconds, 1), 60_000)),
            ]
        }
        _ = try runRemoteShell(serial: serial, arguments: arguments)
    }

    func exportApplicationCatalog(serial: String, requestID: String) throws -> String {
        guard Self.isRequestID(requestID) else {
            throw ADBClientError.commandFailed(
                code: -1,
                message: "Invalid application catalog request identifier"
            )
        }
        let userID = try foregroundAndroidUser(serial: serial)
        guard let applicationID = try selectedCompanionPackage(serial: serial, userID: userID) else {
            throw ADBClientError.commandFailed(code: -1, message: "Galaxy Bridge companion is required for app icons")
        }
        let action = "com.xopmc.galaxybridge.EXPORT_APPLICATION_CATALOG"
        let receiver = "com.xopmc.galaxybridge.catalog.ApplicationCatalogExportReceiver"
        guard try hasReceiver(
            serial: serial,
            userID: userID,
            applicationID: applicationID,
            receiver: receiver,
            action: action
        ) else {
            throw ADBClientError.commandFailed(code: -1, message: "Galaxy Bridge companion does not support app icons")
        }
        let output = try runRemoteShell(serial: serial, arguments: [
            "am", "broadcast", "--user", userID, "-W", "--receiver-foreground",
            "-a", action,
            "-n", "\(applicationID)/\(receiver)",
            "--es", "request_id", requestID,
        ])
        guard Self.broadcastSucceeded(output) else {
            throw ADBClientError.commandFailed(code: -1, message: output)
        }
        return "/sdcard/Android/data/\(applicationID)/files/application-catalog/\(requestID)"
    }

    func removeApplicationCatalogExport(serial: String, remotePath: String) throws {
        let validPrefixes = Self.knownCompanionPackageIDs.map {
            "/sdcard/Android/data/\($0)/files/application-catalog/"
        }
        guard validPrefixes.contains(where: { prefix in
            guard remotePath.hasPrefix(prefix) else { return false }
            return Self.isRequestID(String(remotePath.dropFirst(prefix.count)))
        }) else { return }
        _ = try runRemoteShell(serial: serial, arguments: ["rm", "-rf", "--", remotePath])
    }

    private static let publicCompanionPackageID = "com.xopmc.galaxybridge"
    private static let internalCompanionPackageID = "com.xopmc.galaxybridge.internal"
    private static let knownCompanionPackageIDs = [publicCompanionPackageID, internalCompanionPackageID]

    private func foregroundAndroidUser(serial: String) throws -> String {
        let output = try runRemoteShell(serial: serial, arguments: ["am", "get-current-user"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty,
              output.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              UInt32(output) != nil
        else {
            throw ADBClientError.commandFailed(code: -1, message: "adb returned an invalid foreground Android user")
        }
        return output
    }

    private func selectedCompanionPackage(serial: String, userID: String) throws -> String? {
        let installed = Set(try installedCompanionPackages(serial: serial, userID: userID))
        switch distribution {
        case .internalDevelopment:
            return [Self.internalCompanionPackageID, Self.publicCompanionPackageID]
                .first(where: installed.contains)
        case .developerID:
            return installed.contains(Self.publicCompanionPackageID) ? Self.publicCompanionPackageID : nil
        }
    }

    private func installedCompanionPackages(serial: String, userID: String) throws -> [String] {
        try runRemoteShell(
            serial: serial,
            arguments: ["pm", "list", "packages", "--user", userID, Self.publicCompanionPackageID]
        )
        .split(whereSeparator: \.isNewline)
        .compactMap { line -> String? in
            let value = String(line)
            guard value.hasPrefix("package:") else { return nil }
            let packageID = String(value.dropFirst("package:".count))
            return Self.knownCompanionPackageIDs.contains(packageID) ? packageID : nil
        }
    }

    private func hasReceiver(
        serial: String,
        userID: String,
        applicationID: String,
        receiver: String,
        action: String
    ) throws -> Bool {
        let component = "\(applicationID)/\(receiver)"
        let output = try runRemoteShell(serial: serial, arguments: [
            "cmd", "package", "query-receivers",
            "--user", userID,
            "--brief", "--components",
            "-a", action,
            "-n", component,
        ])
        return output.split(whereSeparator: \.isNewline).contains {
            Self.normalizedReceiverComponent(String($0), applicationID: applicationID) == component
        }
    }

    private static func normalizedReceiverComponent(_ value: String, applicationID: String) -> String? {
        let fields = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == applicationID, !fields[1].isEmpty else { return nil }
        let receiverClass = fields[1].first == "." ? applicationID + fields[1] : String(fields[1])
        return "\(applicationID)/\(receiverClass)"
    }

    private static func isRequestID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    private static func broadcastSucceeded(_ output: String) -> Bool {
        let marker = "Broadcast completed: result="
        return output.split(whereSeparator: \.isNewline).contains { line in
            guard let range = line.range(of: marker) else { return false }
            let result = line[range.upperBound...].prefix { !$0.isWhitespace && $0 != "," }
            return Int(result) == 0 && result == "0"
        }
    }

    private func runRemoteShell(serial: String, arguments: [String]) throws -> String {
        try run(arguments: ["-s", serial, "shell", Self.remoteShellCommand(arguments)])
    }

    private static func remoteShellCommand(_ arguments: [String]) -> String {
        arguments.map { argument in
            "'\(argument.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        }.joined(separator: " ")
    }

    func launch(
        serial: String,
        arguments: [String],
        outputObserver: ScrcpyOwnedProcessOutputObserver? = nil
    ) throws -> Process {
        let process = Process()
        let configuration = try ownedRuntime?.acquire()
        let selectedArguments = ["-s", serial] + arguments
        try configuration?.validate(selectedArguments)
        process.executableURL = configuration?.executableURL ?? executableURL
        process.environment = configuration?.environment
        process.arguments = (configuration?.argumentPrefix ?? []) + selectedArguments
        // The session observes server errors through its sockets. Never leave
        // an unread pipe that can freeze a long-running server when it fills.
        if let outputObserver {
            do {
                try outputObserver.attach(to: process)
            } catch {
                outputObserver.launchDidFail()
                throw error
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            if let configuration {
                let token = try configuration.processes.start(process)
                // Compose with display identity's terminationHandler by observing
                // exit separately. Never overwrite its callback slot.
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    configuration.processes.finished(token)
                }
            } else {
                try process.run()
            }
            outputObserver?.launchDidSucceed()
        } catch {
            outputObserver?.launchDidFail()
            throw error
        }
        return process
    }

    func cancelling(with token: ADBProcessCancellation) -> Self {
        var client = self
        client.commandCancellation = token
        return client
    }

    func runCommand(arguments: [String], input: Data = Data(), timeout: TimeInterval = 10,
                    outputLimit: Int = 4 * 1024 * 1024,
                    cancellation: ADBProcessCancellation? = nil) throws -> ADBCommandRunner.Result {
        let cancellation = cancellation ?? commandCancellation
        if cancellation?.isCancelled == true { throw CancellationError() }
        if let ownedRuntime {
            let configuration = try ownedRuntime.acquire()
            try configuration.validate(arguments)
            return try configuration.runner(cancellation: cancellation).run(
                arguments: arguments, input: input, timeout: timeout, outputLimit: outputLimit)
        }
        return try ADBCommandRunner(executableURL: executableURL, cancellation: cancellation).run(
            arguments: arguments, input: input, timeout: timeout, outputLimit: outputLimit)
    }

    @discardableResult
    func run(arguments: [String], timeout: TimeInterval? = nil) throws -> String {
        let result = try runCommand(arguments: arguments, timeout: timeout ?? 10)
        guard result.exitCode == 0 else {
            throw ADBClientError.commandFailed(
                code: result.exitCode,
                message: String(decoding: result.stderr, as: UTF8.self)
            )
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func runCombined(arguments: [String]) throws -> String {
        let result = try runCommand(arguments: arguments, timeout: 30)
        let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        guard result.exitCode == 0 else {
            throw ADBClientError.commandFailed(code: result.exitCode, message: text)
        }
        return text
    }
}
#endif
