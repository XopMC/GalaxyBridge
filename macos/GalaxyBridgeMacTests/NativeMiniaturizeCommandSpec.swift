import AppKit
import Foundation
import SwiftUI

private struct NativeMiniaturizeInvocation {
    let runID: String
    let resultURL: URL
    let pidURL: URL

    static func current() throws -> NativeMiniaturizeInvocation {
        let arguments = CommandLine.arguments
        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
                return nil
            }
            return arguments[index + 1]
        }

        guard let runID = value(after: "--task5l-run-id"), !runID.isEmpty,
              let resultPath = value(after: "--task5l-result"), resultPath.hasPrefix("/"),
              let pidPath = value(after: "--task5l-pid"), pidPath.hasPrefix("/")
        else {
            throw Failure("isolated host requires a run identity and absolute result/PID paths")
        }
        return NativeMiniaturizeInvocation(
            runID: runID,
            resultURL: URL(fileURLWithPath: resultPath),
            pidURL: URL(fileURLWithPath: pidPath)
        )
    }

    func writePID() throws {
        let line = "\(runID)\t\(ProcessInfo.processInfo.processIdentifier)\n"
        try Data(line.utf8).write(to: pidURL, options: .atomic)
    }

    func writeResult(status: String, message: String) throws {
        let singleLineMessage = message
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let line = "\(runID)\t\(status)\t\(singleLineMessage)\n"
        try Data(line.utf8).write(to: resultURL, options: .atomic)
    }
}

@MainActor
private final class NativeMiniaturizeTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let invocation: NativeMiniaturizeInvocation
        do {
            invocation = try NativeMiniaturizeInvocation.current()
            try invocation.writePID()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            do {
                try NativeMiniaturizeCommandSpec.run()
                try invocation.writeResult(
                    status: "PASS",
                    message: "PASS native SwiftUI-generated Minimize routing, state, callbacks, guard, and Close regression"
                )
            } catch {
                try? invocation.writeResult(status: "FAIL", message: "FAIL: \(error)")
            }
            NSApp.terminate(nil)
        }
    }
}

private struct NativeMiniaturizeTestApp: App {
    @NSApplicationDelegateAdaptor(NativeMiniaturizeTestDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Native Minimize Test") {
            Text("Controlled native menu host").frame(width: 240, height: 120)
        }
    }
}

@main
private enum NativeMiniaturizeTestBootstrap {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NativeMiniaturizeTestApp.main()
    }
}

@MainActor
private final class WindowProbe: NSObject, NSWindowDelegate {
    private(set) var didMiniaturizeCount = 0
    private(set) var didDeminiaturizeCount = 0
    private(set) var shouldCloseCount = 0
    private(set) var willCloseCount = 0

    func windowDidMiniaturize(_ notification: Notification) {
        didMiniaturizeCount += 1
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        didDeminiaturizeCount += 1
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCount += 1
        return true
    }

    func windowWillClose(_ notification: Notification) {
        willCloseCount += 1
    }

    @objc func recordDelayedDuplicateMiniaturizeCallback() {
        didMiniaturizeCount += 1
    }
}

@MainActor
private enum NativeMiniaturizeCommandSpec {
    private static let minimizeAction = #selector(NSWindow.performMiniaturize(_:))
    private static let closeAction = #selector(NSWindow.performClose(_:))

    static func run() throws {
        try expect(waitUntil { NSApp.isActive }, "the isolated native host must activate itself")
        let generatedMenu = try expectValue(NSApp.mainMenu, "SwiftUI must install a main menu")
        let minimizeItem = try uniqueItem(in: generatedMenu, action: minimizeAction, name: "performMiniaturize:")
        let closeItem = try uniqueItem(in: generatedMenu, action: closeAction, name: "performClose:")

        try generatedMinimizeTargetsOnlyKeyMirror(
            menu: generatedMenu,
            minimizeItem: minimizeItem,
            closeItem: closeItem
        )
        try nonMiniaturizableMirrorRejectsNativeAction(minimizeItem: minimizeItem)
        try commandWStillClosesAfterRestore(menu: generatedMenu)
    }

    private static func generatedMinimizeTargetsOnlyKeyMirror(
        menu: NSMenu,
        minimizeItem: NSMenuItem,
        closeItem: NSMenuItem
    ) throws {
        let windowA = makeMirrorWindow(originX: 40)
        let windowB = makeMirrorWindow(originX: 520)
        let probeA = WindowProbe()
        let probeB = WindowProbe()
        windowA.delegate = probeA
        windowB.delegate = probeB
        try makeKey(windowA)
        try makeKey(windowB)
#if TASK5L_FORCE_WRONG_KEY_WINDOW
        try makeKey(windowA)
#endif
        defer {
            tearDown(windowA)
            tearDown(windowB)
        }

        try expect(minimizeItem.target == nil, "generated Minimize must use target-nil responder routing")
        try expect(windowB.isKeyWindow, "B must report real AppKit key-window state")
        try expect(NSApp.keyWindow === windowB, "the real NSApp.keyWindow must be B")
        try expect(
            NSApp.target(forAction: minimizeItem.action!, to: minimizeItem.target, from: minimizeItem) as? NSWindow === windowB,
            "target-nil generated Minimize must resolve to key B"
        )
        minimizeItem.isEnabled = false
        minimizeItem.menu?.update()
        try expect(minimizeItem.isEnabled, "generated Minimize must validate for miniaturizable key B")
        try expect(windowB.validateUserInterfaceItem(minimizeItem), "Minimize validation must retain NSWindow's enabled result")
        try expectEqual(probeB.shouldCloseCount, 0, "Minimize validation must not invoke the close veto")

        let directCount = probeB.didMiniaturizeCount
        windowB.miniaturize(nil)
#if TASK5L_INJECT_DELAYED_DUPLICATE_CALLBACK
        let duplicateTimer = Timer(
            timeInterval: 0.03,
            target: probeB,
            selector: #selector(WindowProbe.recordDelayedDuplicateMiniaturizeCallback),
            userInfo: nil,
            repeats: false
        )
        RunLoop.current.add(duplicateTimer, forMode: .default)
#endif
        try expectMiniaturizedTransition(
            windowB,
            probe: probeB,
            priorCount: directCount,
            message: "direct miniaturize positive control"
        )
        try expect(!windowA.isMiniaturized, "direct control must leave A non-miniaturized")
        try expectEqual(probeA.didMiniaturizeCount, 0, "direct control must not notify A")
        try restore(windowB, probe: probeB)

        let nativeCount = probeB.didMiniaturizeCount
        try expect(
            NSApp.sendAction(minimizeItem.action!, to: minimizeItem.target, from: minimizeItem),
            "generated Minimize action must dispatch"
        )
        try expectMiniaturizedTransition(
            windowB,
            probe: probeB,
            priorCount: nativeCount,
            message: "generated performMiniaturize:"
        )
        try expect(!windowA.isMiniaturized, "generated Minimize must leave A non-miniaturized")
        try expectEqual(probeA.didMiniaturizeCount, 0, "generated Minimize must not notify A")
        try expectEqual(probeB.shouldCloseCount, 0, "generated Minimize must not invoke B's close veto")
        try restore(windowB, probe: probeB)

        try expectEqual(minimizeItem.keyEquivalent, "m", "generated Minimize must retain the native M key equivalent")
        try expect(
            minimizeItem.keyEquivalentModifierMask.contains(.command),
            "generated Minimize must retain the Command modifier"
        )
        let commandCount = probeB.didMiniaturizeCount
        let commandM = try keyEvent(character: "m", keyCode: 46, window: windowB)
        try expect(menu.performKeyEquivalent(with: commandM), "generated Window menu must consume local Cmd-M")
        try expectMiniaturizedTransition(
            windowB,
            probe: probeB,
            priorCount: commandCount,
            message: "generated Cmd-M"
        )
        try expect(!windowA.isMiniaturized, "generated Cmd-M must leave A non-miniaturized")
        try expectEqual(probeA.didMiniaturizeCount, 0, "generated Cmd-M must not notify A")
        try expectEqual(probeB.shouldCloseCount, 0, "generated Cmd-M must not invoke B's close veto")
        try restore(windowB, probe: probeB)

        let repeatCount = probeB.didMiniaturizeCount
        try expect(
            NSApp.sendAction(minimizeItem.action!, to: minimizeItem.target, from: minimizeItem),
            "repeat generated Minimize must dispatch"
        )
        try expectMiniaturizedTransition(
            windowB,
            probe: probeB,
            priorCount: repeatCount,
            message: "repeat generated Minimize"
        )
        try expectEqual(probeB.shouldCloseCount, 0, "repeat Minimize must not invoke B's close veto")
        try restore(windowB, probe: probeB)

        try expect(
            NSApp.target(forAction: closeItem.action!, to: closeItem.target, from: closeItem) as? NSWindow === windowB,
            "target-nil generated Close must still resolve to restored key B"
        )
        try expect(
            NSApp.sendAction(closeItem.action!, to: closeItem.target, from: closeItem),
            "generated Close must dispatch after restore"
        )
        try expectEqual(probeB.shouldCloseCount, 1, "Close after restore must consult B's delegate once")
        try expectEqual(probeB.willCloseCount, 1, "Close after restore must close B exactly once")
        try expectEqual(probeA.shouldCloseCount, 0, "Close after restore must not consult A")
        try expectEqual(probeA.willCloseCount, 0, "Close after restore must leave A open")
    }

    private static func nonMiniaturizableMirrorRejectsNativeAction(minimizeItem: NSMenuItem) throws {
        let window = makeMirrorWindow(originX: 520)
        window.styleMask.remove(.miniaturizable)
        let probe = WindowProbe()
        window.delegate = probe
        try makeKey(window)
        defer { tearDown(window) }

        try expect(
            NSApp.target(forAction: minimizeItem.action!, to: minimizeItem.target, from: minimizeItem) as? NSWindow === window,
            "non-miniaturizable controlled window must remain the native action target"
        )
        try expect(
            NSApp.sendAction(minimizeItem.action!, to: minimizeItem.target, from: minimizeItem),
            "guarded Minimize action must be handled"
        )
        let changed = waitUntil(timeout: 0.1) { window.isMiniaturized || probe.didMiniaturizeCount > 0 }
        try expect(!changed, "a non-miniaturizable seamless window must reject the native Minimize action")
        try expectEqual(probe.shouldCloseCount, 0, "guarded Minimize must not invoke the close veto")
    }

    private static func commandWStillClosesAfterRestore(menu: NSMenu) throws {
        let window = makeMirrorWindow(originX: 520)
        let probe = WindowProbe()
        window.delegate = probe
        try makeKey(window)
        defer { tearDown(window) }

        window.miniaturize(nil)
        try expectMiniaturizedTransition(
            window,
            probe: probe,
            priorCount: 0,
            message: "Cmd-W direct control"
        )
        try restore(window, probe: probe)
        try expectEqual(probe.shouldCloseCount, 0, "restore before Cmd-W must not invoke the close veto")

        let commandW = try keyEvent(character: "w", keyCode: 13, window: window)
        try expect(menu.performKeyEquivalent(with: commandW), "generated native menu must consume local Cmd-W after restore")
        try expectEqual(probe.shouldCloseCount, 1, "Cmd-W after restore must consult the delegate once")
        try expectEqual(probe.willCloseCount, 1, "Cmd-W after restore must close exactly once")
    }

    private static func restore(_ window: NSWindow, probe: WindowProbe) throws {
        let priorCount = probe.didDeminiaturizeCount
        window.deminiaturize(nil)
        try expect(
            waitUntil { !window.isMiniaturized && probe.didDeminiaturizeCount >= priorCount + 1 },
            "deminiaturize must restore native state and emit a callback"
        )
        settleEventLoop()
        try expect(!window.isMiniaturized, "deminiaturize must remain restored after bounded settling")
        try expectEqual(
            probe.didDeminiaturizeCount,
            priorCount + 1,
            "deminiaturize must settle with exactly one new callback"
        )
        try makeKey(window)
    }

    private static func makeMirrorWindow(originX: CGFloat) -> SeamlessMirrorWindow {
        let window = SeamlessMirrorWindow(
            contentRect: NSRect(x: originX, y: 40, width: 432, height: 832),
            styleMask: MirrorWindowActivationPolicy.seamlessFocusableStyleMask(from: []),
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func makeKey(_ window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        let becameKey = waitUntil { window.isKeyWindow && NSApp.keyWindow === window }
        guard becameKey else {
            throw Failure(
                "AppKit must establish the requested window as the real key window "
                    + "(activationPolicy=\(NSApp.activationPolicy().rawValue), "
                    + "isActive=\(NSApp.isActive), requestedIsKey=\(window.isKeyWindow), "
                    + "hasAnyKeyWindow=\(NSApp.keyWindow != nil))"
            )
        }
    }

    private static func keyEvent(character: String, keyCode: UInt16, window: NSWindow) throws -> NSEvent {
        try expectValue(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: character,
                charactersIgnoringModifiers: character,
                isARepeat: false,
                keyCode: keyCode
            ),
            "local Cmd-\(character.uppercased()) event must be constructible"
        )
    }

    private static func uniqueItem(in menu: NSMenu, action: Selector, name: String) throws -> NSMenuItem {
        let matches = recursivelyCollectItems(in: menu, action: action)
        try expectEqual(matches.count, 1, "generated main menu must contain one exact \(name) action")
        return matches[0]
    }

    private static func recursivelyCollectItems(in root: NSMenu, action: Selector) -> [NSMenuItem] {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ menu: NSMenu) -> [NSMenuItem] {
            guard visited.insert(ObjectIdentifier(menu)).inserted else { return [] }
            return menu.items.flatMap { item -> [NSMenuItem] in
                (item.action == action ? [item] : []) + (item.submenu.map(visit) ?? [])
            }
        }
        return visit(root)
    }

    private static func waitUntil(timeout: TimeInterval = 1, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: deadline)
        }
        return condition()
    }

    private static func expectMiniaturizedTransition(
        _ window: NSWindow,
        probe: WindowProbe,
        priorCount: Int,
        message: String
    ) throws {
        try expect(
            waitUntil { window.isMiniaturized && probe.didMiniaturizeCount >= priorCount + 1 },
            "\(message) must set isMiniaturized and emit a callback"
        )
        settleEventLoop()
        try expect(window.isMiniaturized, "\(message) must remain miniaturized after bounded settling")
        try expectEqual(
            probe.didMiniaturizeCount,
            priorCount + 1,
            "\(message) must settle with exactly one new callback"
        )
    }

    private static func settleEventLoop(for duration: TimeInterval = 0.12) {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            _ = RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(min(0.01, remaining))
            )
        }
    }

    private static func tearDown(_ window: NSWindow) {
        window.delegate = nil
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderOut(nil)
        window.close()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else { throw Failure("\(message): expected \(expected), got \(actual)") }
    }

    private static func expectValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message) }
        return value
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
