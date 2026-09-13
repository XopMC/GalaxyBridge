import Darwin
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore

private enum SpecFailure: Error, CustomStringConvertible {
    case mismatch(got: [String], expected: [String])
    case missingCapture

    var description: String {
        switch self {
        case let .mismatch(got, expected):
            "remote command arguments changed: got \(got); expected \(expected)"
        case .missingCapture:
            "fake Android command did not capture any arguments"
        }
    }
}

@main
private enum ADBClientShellSpec {
    static func main() throws {
        // Exercise the public ADB boundary, not a copy of its process logic.
        let shellBoundary = try ADBClient(testingExecutableURL: URL(fileURLWithPath: "/bin/sh"))
        let flood = try shellBoundary.run(arguments: [
            "-c", "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2",
        ], timeout: 2)
        precondition(flood.utf8.count == 262144, "ADB must drain both full pipes while the command is running")
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("galaxybridge-adb-shell-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let captureURL = temporaryDirectory.appendingPathComponent("am-arguments.txt")
        let adbURL = temporaryDirectory.appendingPathComponent("adb")
        let amURL = temporaryDirectory.appendingPathComponent("am")
        let pmURL = temporaryDirectory.appendingPathComponent("pm")
        let appProcessURL = temporaryDirectory.appendingPathComponent("app_process")
        let cmdURL = temporaryDirectory.appendingPathComponent("cmd")
        let wmURL = temporaryDirectory.appendingPathComponent("wm")
        let inputURL = temporaryDirectory.appendingPathComponent("input")
        let settingsURL = temporaryDirectory.appendingPathComponent("settings")
        let dumpsysURL = temporaryDirectory.appendingPathComponent("dumpsys")
        let toyboxURL = temporaryDirectory.appendingPathComponent("toybox")
        let psURL = temporaryDirectory.appendingPathComponent("ps")
        let commandLogURL = temporaryDirectory.appendingPathComponent("adb-commands.txt")
        let socketProbeCountURL = temporaryDirectory.appendingPathComponent("socket-probe-count.txt")
        let scrcpyProbeCountURL = temporaryDirectory.appendingPathComponent("scrcpy-probe-count.txt")
        let scrcpyKilledURL = temporaryDirectory.appendingPathComponent("scrcpy-killed.txt")
        let serverURL = temporaryDirectory.appendingPathComponent("scrcpy-server.jar")
        try Data("pinned-server".utf8).write(to: serverURL)
        try Self.writeExecutable(
            at: adbURL,
            contents: """
            #!/bin/sh
            printf '%s\n' "$*" >> "$GB_ADB_COMMAND_LOG"
            if [ "$3" = "shell" ] && [ "$4" = "grep" ] && [ "$7" = "/proc/net/unix" ]; then
              count=$(cat "$GB_ADB_SOCKET_PROBE_COUNT" 2>/dev/null || printf '0')
              if [ "$count" = "0" ]; then
                printf '1' > "$GB_ADB_SOCKET_PROBE_COUNT"
                sleep 0.55
                exit 1
              fi
              printf '%s\n' '@galaxybridge_delayed_socket'
              exit 0
            fi
            if [ "$3" = "push" ]; then
              exit 0
            fi
            if [ "$3" = "shell" ]; then
              if [ "$4" = "'kill' '120' '124'" ]; then
                printf '%s\n' '120' '124' > "$GB_ADB_SCRCPY_KILLED"
                exit 0
              fi
              shift 3
              /bin/sh -c "$*"
              exit $?
            fi
            exit 64
            """
        )
        try Self.writeExecutable(
            at: toyboxURL,
            contents: """
            #!/bin/sh
            if [ "$1" = "sha256sum" ]; then
              printf '%s  %s\n' 'expected-scrcpy-sha256' "$2"
              exit 0
            fi
            exit 64
            """
        )
        try Self.writeExecutable(
            at: psURL,
            contents: """
            #!/bin/sh
            count=$(cat "$GB_ADB_SCRCPY_PROBE_COUNT" 2>/dev/null || printf '0')
            next=$((count + 1))
            printf '%s' "$next" > "$GB_ADB_SCRCPY_PROBE_COUNT"
            printf '%s\n' 'PID ARGS'
            printf '%s\n' '90 app_process / com.genymobile.scrcpy.Server 4.1 scid=76543210'
            printf '%s\n' '91 app_process / com.example.Other scid=1a2b3c4d'
            printf '%s\n' '92 app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d-extra'
            if [ "$count" -gt 0 ] && [ ! -f "$GB_ADB_SCRCPY_KILLED" ]; then
              printf '%s\n' '120 app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d video=false audio=false'
              printf '%s\n' '124 app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d cleanup=false'
            fi
            """
        )
        try Self.writeExecutable(
            at: amURL,
            contents: """
            #!/bin/sh
            printf '%s\\n' "$@" > "$GB_ADB_CAPTURE_PATH"
            if [ "$1" = "get-current-user" ]; then
              printf '%s\\n' '10'
              exit 0
            fi
            if [ "$1" = "broadcast" ]; then
              printf '%s\\n' 'Broadcast completed: result=0'
            fi
            """
        )
        try Self.writeExecutable(
            at: pmURL,
            contents: """
            #!/bin/sh
            printf '%s\\n' 'package:com.xopmc.galaxybridge.internal'
            """
        )
        try Self.writeExecutable(
            at: appProcessURL,
            contents: """
            #!/bin/sh
            printf '%s\n' '[server] INFO: List of apps:'
            printf '%s\n' ' * One UI Home                       com.sec.android.app.launcher'
            printf '%s\n' ' - Samsung Notes                     com.samsung.android.app.notes'
            """
        )
        try Self.writeExecutable(
            at: cmdURL,
            contents: """
            #!/bin/sh
            if [ "$1" = "package" ] && [ "$2" = "query-receivers" ]; then
              for component do :; done
              printf '%s\n' "$component"
              exit 0
            fi
            if [ "$1" = "display" ] && [ "$2" = "get-brightness" ]; then
              printf '%s\n' '0.42'
              exit 0
            fi
            if [ "$1" = "display" ] && [ "$2" = "set-brightness" ]; then
              printf '%s\n' "$@" > "$GB_ADB_BRIGHTNESS_CAPTURE_PATH"
              exit 0
            fi
            printf '%s\n' '2 activities found:'
            printf '%s\n' 'com.sec.android.app.launcher/.activities.LauncherActivity'
            printf '%s\n' 'com.samsung.android.app.notes/.NotesActivity'
            """
        )
        try Self.writeExecutable(
            at: wmURL,
            contents: """
            #!/bin/sh
            printf '%s\n' 'Physical size: 1440x3120'
            """
        )
        try Self.writeExecutable(
            at: inputURL,
            contents: """
            #!/bin/sh
            printf '%s\n' "$@" > "$GB_ADB_INPUT_CAPTURE_PATH"
            """
        )
        try Self.writeExecutable(
            at: settingsURL,
            contents: """
            #!/bin/sh
            if [ "$1" = "get" ]; then
              printf '%s\n' '1'
              exit 0
            fi
            printf '%s\n' "$@" > "$GB_ADB_SETTINGS_CAPTURE_PATH"
            """
        )
        try Self.writeExecutable(
            at: dumpsysURL,
            contents: """
            #!/bin/sh
            [ "$1" = "power" ] || exit 64
            printf '%s\n' '  mWakefulness=Dozing'
            printf '%s\n' 'unrelated large diagnostic line that must be filtered remotely'
            """
        )

        let previousPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(temporaryDirectory.path):\(previousPath)", 1)
        setenv("GB_ADB_CAPTURE_PATH", captureURL.path, 1)
        setenv("GB_ADB_COMMAND_LOG", commandLogURL.path, 1)
        setenv("GB_ADB_SOCKET_PROBE_COUNT", socketProbeCountURL.path, 1)
        setenv("GB_ADB_SCRCPY_PROBE_COUNT", scrcpyProbeCountURL.path, 1)
        setenv("GB_ADB_SCRCPY_KILLED", scrcpyKilledURL.path, 1)
        let inputCaptureURL = temporaryDirectory.appendingPathComponent("input-arguments.txt")
        let brightnessCaptureURL = temporaryDirectory.appendingPathComponent("brightness-arguments.txt")
        let settingsCaptureURL = temporaryDirectory.appendingPathComponent("settings-arguments.txt")
        setenv("GB_ADB_INPUT_CAPTURE_PATH", inputCaptureURL.path, 1)
        setenv("GB_ADB_BRIGHTNESS_CAPTURE_PATH", brightnessCaptureURL.path, 1)
        setenv("GB_ADB_SETTINGS_CAPTURE_PATH", settingsCaptureURL.path, 1)

        let deepLink = URL(
            string: "galaxybridge://bind?host=host-1&device=device-1&serial=TESTPHONE01&nonce=abc-123"
        )!
        let client = try ADBClient(testingExecutableURL: adbURL)
        let parsedScrcpyProcessIDs = ADBScrcpyServerProcessParser.processIDs(
            """
            PID ARGS
            120 app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d video=false
            121 app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d-extra
            122 app_process / com.example.Other 4.1 scid=1a2b3c4d
            nope app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d
            1 app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d
            124 app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d
            124 app_process / com.genymobile.scrcpy.Server 4.1 scid=1a2b3c4d
            """,
            scid: 0x1A2B_3C4D
        )
        guard parsedScrcpyProcessIDs == [120, 124] else {
            fatalError("exact scrcpy SCID parser widened its match: \(parsedScrcpyProcessIDs)")
        }
        try client.retireScrcpyServer(serial: "TESTPHONE01", scid: 0x1A2B_3C4D)
        let killedScrcpyProcessIDs = try String(contentsOf: scrcpyKilledURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard killedScrcpyProcessIDs == ["120", "124"] else {
            fatalError("scrcpy retirement must kill only the exact SCID: \(killedScrcpyProcessIDs)")
        }
        try client.waitForAbstractSocket(
            serial: "TESTPHONE01",
            socketName: "galaxybridge_delayed_socket",
            timeout: 0.9
        )
        try client.openDeepLink(serial: "TESTPHONE01", url: deepLink)

        guard let captured = try? String(contentsOf: captureURL, encoding: .utf8) else {
            throw SpecFailure.missingCapture
        }
        let got = captured.split(whereSeparator: \.isNewline).map(String.init)
        let expected = [
            "start",
            "--user",
            "10",
            "-W",
            "-a",
            "android.intent.action.VIEW",
            "-d",
            deepLink.absoluteString,
            "-n",
            "com.xopmc.galaxybridge.internal/com.xopmc.galaxybridge.MainActivity",
        ]
        guard got == expected else { throw SpecFailure.mismatch(got: got, expected: expected) }

        let remoteText = "Привет 🌉"
        guard try client.injectRemoteText(serial: "TESTPHONE01", text: remoteText) else {
            fatalError("shell-protected remote text receiver rejected a valid payload")
        }
        let remoteTextArguments = try String(contentsOf: captureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard remoteTextArguments == [
            "broadcast",
            "--user",
            "10",
            "-W",
            "--receiver-foreground",
            "-a",
            "com.xopmc.galaxybridge.INJECT_REMOTE_TEXT",
            "-n",
            "com.xopmc.galaxybridge.internal/com.xopmc.galaxybridge.service.RemoteTextInputReceiver",
            "--es",
            "text_b64",
            Data(remoteText.utf8).base64EncodedString(),
        ] else {
            fatalError("remote Unicode text must use the shell-only internal receiver: \(remoteTextArguments)")
        }

        guard try client.displayBrightness(serial: "TESTPHONE01") == 0.42 else {
            fatalError("ADB display brightness parser changed")
        }
        try client.setDisplayBrightness(serial: "TESTPHONE01", brightness: 0)
        let brightnessArguments = try String(contentsOf: brightnessCaptureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard brightnessArguments == ["display", "set-brightness", "0.0"] else {
            fatalError("ADB display brightness command changed: \(brightnessArguments)")
        }

        guard try client.showsSoftwareKeyboardWithHardware(serial: "TESTPHONE01") == true else {
            fatalError("ADB hardware-keyboard IME setting parser changed")
        }
        guard try client.physicalDisplayState(serial: "TESTPHONE01") == .off else {
            fatalError("ADB lightweight physical-display state parser changed")
        }
        let powerProbeCommand = try String(contentsOf: commandLogURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last
        guard powerProbeCommand == "-s TESTPHONE01 shell 'sh' '-c' 'dumpsys power | grep -m 1 mWakefulness='" else {
            fatalError("physical-display monitoring must use the bounded power probe: \(powerProbeCommand ?? "missing")")
        }
        try client.wakePhysicalDisplay(serial: "TESTPHONE01")
        let wakeArguments = try String(contentsOf: inputCaptureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard wakeArguments == ["keyevent", "KEYCODE_WAKEUP"] else {
            fatalError("screen interlock must wake only the lock screen: \(wakeArguments)")
        }
        try client.setShowsSoftwareKeyboardWithHardware(serial: "TESTPHONE01", enabled: false)
        let hiddenIMEArguments = try String(contentsOf: settingsCaptureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard hiddenIMEArguments == ["put", "secure", "show_ime_with_hard_keyboard", "0"] else {
            fatalError("ADB remote-keyboard IME command changed: \(hiddenIMEArguments)")
        }
        try client.setShowsSoftwareKeyboardWithHardware(serial: "TESTPHONE01", enabled: nil)
        let restoredIMEArguments = try String(contentsOf: settingsCaptureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard restoredIMEArguments == ["delete", "secure", "show_ime_with_hard_keyboard"] else {
            fatalError("ADB remote-keyboard IME restore changed: \(restoredIMEArguments)")
        }

        try client.injectTouch(
            serial: "TESTPHONE01",
            command: .tap(x: 0.70, y: 0.60)
        )
        let tapArguments = try String(contentsOf: inputCaptureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard tapArguments == ["touchscreen", "tap", "1007", "1871"] else {
            fatalError("ADB physical-display tap changed: \(tapArguments)")
        }

        try client.injectTouch(
            serial: "TESTPHONE01",
            command: .swipe(
                fromX: 0.80,
                fromY: 0.50,
                toX: 0.20,
                toY: 0.50,
                durationMilliseconds: 120
            )
        )
        let swipeArguments = try String(contentsOf: inputCaptureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard swipeArguments == ["touchscreen", "swipe", "1151", "1560", "288", "1560", "120"] else {
            fatalError("ADB physical-display swipe changed: \(swipeArguments)")
        }

        let applications = try client.scrcpyApplications(serial: "TESTPHONE01")
        guard applications == [
            ScrcpyApplication(
                packageName: "com.sec.android.app.launcher",
                componentName: "com.sec.android.app.launcher/.activities.LauncherActivity",
                label: "One UI Home",
                isSystem: true
            ),
            ScrcpyApplication(
                packageName: "com.samsung.android.app.notes",
                componentName: "com.samsung.android.app.notes/.NotesActivity",
                label: "Samsung Notes",
                isSystem: false
            ),
        ] else {
            fatalError("scrcpy app listing and launcher-component merge changed: \(applications)")
        }

        try "".write(to: commandLogURL, atomically: true, encoding: .utf8)
        _ = try client.scrcpyDisplays(serial: "TESTPHONE01", serverURL: serverURL)
        let displayCommands = try String(contentsOf: commandLogURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard displayCommands.count == 3,
              displayCommands[0].contains(" push -q \(serverURL.path) \(ScrcpyLaunchConfiguration.remoteServerPath)"),
              displayCommands[1].contains(" shell toybox sha256sum \(ScrcpyLaunchConfiguration.remoteServerPath)"),
              displayCommands[2].contains(" shell CLASSPATH=\(ScrcpyLaunchConfiguration.remoteServerPath) app_process / com.genymobile.scrcpy.Server 4.1 list_displays=true cleanup=false")
        else {
            fatalError("display discovery must deploy and verify the pinned server before launch: \(displayCommands)")
        }
        print("ADB remote shell quoting spec passed")
    }

    private static func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
