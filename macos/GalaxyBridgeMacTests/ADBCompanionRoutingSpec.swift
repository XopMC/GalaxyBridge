import Darwin
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore

@main
private enum ADBCompanionRoutingSpec {
    static func main() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("galaxybridge-companion-routing-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let adbURL = directory.appendingPathComponent("adb")
        let amURL = directory.appendingPathComponent("am")
        let pmURL = directory.appendingPathComponent("pm")
        let cmdURL = directory.appendingPathComponent("cmd")
        let rmURL = directory.appendingPathComponent("rm")
        let commandLogURL = directory.appendingPathComponent("android-commands.txt")
        try writeExecutable(at: adbURL, contents: """
            #!/bin/sh
            [ "$3" = "shell" ] || exit 64
            shift 3
            /bin/sh -c "$*"
            """)
        try writeExecutable(at: amURL, contents: """
            #!/bin/sh
            printf 'am %s\n' "$*" >> "$GB_ANDROID_COMMAND_LOG"
            if [ "$1" = "get-current-user" ]; then
              printf '%s\n' "${GB_CURRENT_USER:-10}"
              exit 0
            fi
            if [ "$1" = "broadcast" ]; then
              printf '%s\n' "${GB_BROADCAST_RESULT:-Broadcast completed: result=0}"
              exit 0
            fi
            [ "$1" = "start" ] && exit 0
            exit 64
            """)
        try writeExecutable(at: pmURL, contents: """
            #!/bin/sh
            printf 'pm %s\n' "$*" >> "$GB_ANDROID_COMMAND_LOG"
            printf '%b' "${GB_INSTALLED_PACKAGES:-}"
            """)
        try writeExecutable(at: cmdURL, contents: """
            #!/bin/sh
            printf 'cmd %s\n' "$*" >> "$GB_ANDROID_COMMAND_LOG"
            if [ "$1" = "package" ] && [ "$2" = "query-receivers" ]; then
              printf '%b' "${GB_RECEIVERS:-}"
              exit 0
            fi
            exit 64
            """)
        try writeExecutable(at: rmURL, contents: """
            #!/bin/sh
            printf 'rm %s\n' "$*" >> "$GB_ANDROID_COMMAND_LOG"
            [ "$1" = "-rf" ] || exit 64
            [ "$2" = "--" ] || exit 64
            [ "$3" = "$GB_EXPECTED_REMOTE_EXPORT_PATH" ] || exit 64
            /bin/rm -rf -- "$GB_LOCAL_EXPORT_PATH"
            """)

        let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(directory.path):\(oldPath)", 1)
        setenv("GB_ANDROID_COMMAND_LOG", commandLogURL.path, 1)
        defer {
            setenv("PATH", oldPath, 1)
            unsetenv("GB_ANDROID_COMMAND_LOG")
            unsetenv("GB_CURRENT_USER")
            unsetenv("GB_INSTALLED_PACKAGES")
            unsetenv("GB_RECEIVERS")
            unsetenv("GB_BROADCAST_RESULT")
            unsetenv("GB_EXPECTED_REMOTE_EXPORT_PATH")
            unsetenv("GB_LOCAL_EXPORT_PATH")
        }

        let publicID = "com.xopmc.galaxybridge"
        let internalID = "com.xopmc.galaxybridge.internal"
        let textReceiver = "com.xopmc.galaxybridge.service.RemoteTextInputReceiver"
        let catalogReceiver = "com.xopmc.galaxybridge.catalog.ApplicationCatalogExportReceiver"
        let requestID = "0123456789abcdef0123456789abcdef"
        let serial = "PHONE"

        func configure(packages: [String], receivers: [String], user: String = "10") throws {
            try? fileManager.removeItem(at: commandLogURL)
            setenv("GB_CURRENT_USER", user, 1)
            setenv("GB_INSTALLED_PACKAGES", packages.map { "package:\($0)\n" }.joined(), 1)
            setenv("GB_RECEIVERS", receivers.map { "\($0)\n" }.joined(), 1)
            unsetenv("GB_BROADCAST_RESULT")
        }

        func client(_ distribution: ADBDistributionChannel) throws -> ADBClient {
            try ADBClient(testingExecutableURL: adbURL, distribution: distribution)
        }

        func commands() throws -> [String] {
            (try String(contentsOf: commandLogURL, encoding: .utf8))
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        }

        // Public-only Direct routes through its explicit shell-protected receiver.
        try configure(packages: [publicID], receivers: ["\(publicID)/.service.RemoteTextInputReceiver"])
        let publicDelivered = try client(.developerID).injectRemoteText(serial: serial, text: "Привет 🌉")
        expect(publicDelivered, "Direct remote text must be delivered")
        var log = try commands()
        expect(log.contains("am get-current-user"), "routing must resolve the foreground Android user")
        expect(log.contains("pm list packages --user 10 \(publicID)"), "package lookup must be scoped to the foreground user")
        expect(log.contains { $0 == "cmd package query-receivers --user 10 --brief --components -a com.xopmc.galaxybridge.INJECT_REMOTE_TEXT -n \(publicID)/\(textReceiver)" },
               "Direct text must verify the exact receiver in the foreground user")
        expect(log.contains { $0.contains("am broadcast --user 10 -W --receiver-foreground") && $0.contains("-n \(publicID)/\(textReceiver)") },
               "Direct text must explicitly target the public receiver for the foreground user")

        for wrongReceiver in [
            "com.example.wrong/.service.RemoteTextInputReceiver",
            "\(publicID)/.service.WrongReceiver",
            "\(publicID).evil/.service.RemoteTextInputReceiver",
        ] {
            try configure(packages: [publicID], receivers: [wrongReceiver])
            let wrongReceiverDelivered = try client(.developerID).injectRemoteText(serial: serial, text: "Wrong")
            expect(!wrongReceiverDelivered, "wrong receiver package/class must not satisfy capability discovery")
            let wrongReceiverCommands = try commands()
            expect(!wrongReceiverCommands.contains { $0.hasPrefix("am broadcast") },
                   "wrong receiver output must stop before broadcast")
        }

        // Internal distribution keeps preferring Internal when both exact IDs exist.
        try configure(packages: [publicID, internalID], receivers: ["\(internalID)/\(textReceiver)"])
        let internalDelivered = try client(.internalDevelopment).injectRemoteText(serial: serial, text: "Internal")
        expect(internalDelivered, "Internal remote text must remain delivered")
        log = try commands()
        expect(log.contains { $0.contains("-n \(internalID)/\(textReceiver)") },
               "Internal Mac must deterministically prefer Internal companion")

        // Customer distribution keeps preferring public when both exact IDs exist.
        try configure(packages: [internalID, publicID], receivers: ["\(publicID)/.service.RemoteTextInputReceiver"])
        let preferredPublicDelivered = try client(.developerID).injectRemoteText(serial: serial, text: "Direct")
        expect(preferredPublicDelivered, "customer routing must deliver through public companion")
        log = try commands()
        expect(log.contains { $0.contains("-n \(publicID)/\(textReceiver)") },
               "customer Mac must deterministically prefer public companion")

        try configure(packages: [internalID], receivers: ["\(internalID)/\(textReceiver)"])
        let customerInternalDelivered = try client(.developerID).injectRemoteText(serial: serial, text: "Wrong flavor")
        expect(!customerInternalDelivered, "customer Mac must not route through an Internal-only install")

        // Internal-only remains functional for Internal Mac.
        try configure(packages: [internalID], receivers: ["\(internalID)/\(catalogReceiver)"])
        let internalPath = try client(.internalDevelopment).exportApplicationCatalog(serial: serial, requestID: requestID)
        expect(internalPath == "/sdcard/Android/data/\(internalID)/files/application-catalog/\(requestID)",
               "Internal catalog path must remain package-scoped")

        try configure(packages: [publicID], receivers: ["\(publicID)/.catalog.ApplicationCatalogExportReceiver"])
        let publicPath = try client(.developerID).exportApplicationCatalog(serial: serial, requestID: requestID)
        expect(publicPath == "/sdcard/Android/data/\(publicID)/files/application-catalog/\(requestID)",
               "Direct catalog export must remain package-scoped")

        // Prefix/suffix near matches are not companions.
        try configure(packages: ["com.xopmc.galaxybridge.beta", "evil.com.xopmc.galaxybridge"], receivers: [])
        let unrelatedDelivered = try client(.developerID).injectRemoteText(serial: serial, text: "No route")
        expect(!unrelatedDelivered,
               "unrelated package IDs must not receive text")
        log = try commands()
        expect(!log.contains { $0.hasPrefix("cmd package query-receivers") || $0.hasPrefix("am broadcast") },
               "unrelated IDs must stop before receiver lookup or broadcast")

        // Play shares the public package ID but lacks these receivers.
        try configure(packages: [publicID], receivers: [])
        let playDelivered = try client(.developerID).injectRemoteText(serial: serial, text: "Play")
        expect(!playDelivered,
               "a missing Play receiver must not be reported as delivered")
        log = try commands()
        expect(!log.contains { $0.hasPrefix("am broadcast") },
               "missing receiver capability must stop before broadcast")
        do {
            _ = try client(.developerID).exportApplicationCatalog(serial: serial, requestID: requestID)
            fatalError("Play must not export a catalog without the receiver")
        } catch ADBClientError.commandFailed {
            // Expected capability failure.
        }

        try configure(packages: [publicID], receivers: ["\(publicID)/.service.RemoteTextInputReceiver"])
        setenv("GB_BROADCAST_RESULT", "Broadcast completed: result=-1", 1)
        let rejectedBroadcast = try client(.developerID).injectRemoteText(serial: serial, text: "Rejected")
        expect(!rejectedBroadcast, "an explicit receiver rejection must not be reported as delivered")

        try configure(packages: [publicID], receivers: ["\(publicID)/.catalog.ApplicationCatalogExportReceiver"])
        setenv("GB_BROADCAST_RESULT", "Broadcast completed: result=01", 1)
        do {
            _ = try client(.developerID).exportApplicationCatalog(serial: serial, requestID: requestID)
            fatalError("a near-match broadcast result must not count as catalog success")
        } catch ADBClientError.commandFailed {
            // Expected strict result parsing.
        }

        // Invalid current-user resolution fails closed before profile-scoped access.
        try configure(packages: [publicID], receivers: [], user: "Security exception")
        do {
            _ = try client(.developerID).injectRemoteText(serial: serial, text: "No user")
            fatalError("invalid current-user output must fail")
        } catch ADBClientError.commandFailed {
            log = try commands()
            expect(!log.contains { $0.hasPrefix("pm ") || $0.hasPrefix("cmd ") },
                   "failed foreground-user resolution must not query other profiles")
        }

        // Cleanup accepts only an exact known package root plus 32 lowercase ASCII hex.
        try configure(packages: [], receivers: [])
        let cleanupPath = "/sdcard/Android/data/\(publicID)/files/application-catalog/\(requestID)"
        let localExportPath = directory.appendingPathComponent("nonempty-export", isDirectory: true)
        try fileManager.createDirectory(at: localExportPath, withIntermediateDirectories: true)
        try Data("icon".utf8).write(to: localExportPath.appendingPathComponent("icon.png"))
        setenv("GB_EXPECTED_REMOTE_EXPORT_PATH", cleanupPath, 1)
        setenv("GB_LOCAL_EXPORT_PATH", localExportPath.path, 1)
        try client(.developerID).removeApplicationCatalogExport(serial: serial, remotePath: cleanupPath)
        log = try commands()
        expect(!fileManager.fileExists(atPath: localExportPath.path),
               "valid cleanup must recursively remove a nonempty export directory")
        expect(log.last == "rm -rf -- \(cleanupPath)",
               "valid public cleanup must recursively remove exactly one known export directory")
        let invalidPaths = [
            "/sdcard/Android/data/\(publicID)/files/application-catalog/../\(requestID)",
            "/sdcard/Android/data/\(publicID).evil/files/application-catalog/\(requestID)",
            "/sdcard/Android/data/\(publicID)/files/application-catalog/ABCDEF0123456789abcdef0123456789",
            "/sdcard/Android/data/\(publicID)/files/application-catalog/0123456789abcdef0123456789abcdeg",
            "/sdcard/Android/data/\(publicID)/files/application-catalog/\(requestID)/child",
        ]
        let countBefore = log.count
        for path in invalidPaths {
            try client(.developerID).removeApplicationCatalogExport(serial: serial, remotePath: path)
        }
        let countAfterInvalidPaths = try commands().count
        expect(countAfterInvalidPaths == countBefore, "near-match and traversal cleanup paths must have no ADB side effect")

        print("PASS public/Internal companion routing, foreground-user targeting, capability checks, and cleanup")
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError(message) }
    }

    private static func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
