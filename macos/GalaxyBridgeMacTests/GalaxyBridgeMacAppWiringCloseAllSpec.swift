import AppKit
import Foundation
import SwiftUI

private struct NativeCloseAllAppInvocation {
    let runID: String
    let resultURL: URL
    let pidURL: URL

    static func current() throws -> NativeCloseAllAppInvocation {
        let arguments = CommandLine.arguments
        func value(after option: String) -> String? {
            guard let index = arguments.firstIndex(of: option),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        guard let runID = value(after: "--task5k-run-id"), !runID.isEmpty,
              let resultPath = value(after: "--task5k-result"), resultPath.hasPrefix("/"),
              let pidPath = value(after: "--task5k-pid"), pidPath.hasPrefix("/")
        else {
            throw ProductionAppFailure(
                "isolated Close All host requires a run identity and absolute result/PID paths"
            )
        }
        return NativeCloseAllAppInvocation(
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

enum UserFacingText {
    static func formatted(_ key: String, _ arguments: CVarArg...) -> String { key }
}

struct DeviceRow: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceRow] = []
    @Published var activeRecordings: [ActiveRecordingSummary] = []
    func stopRecording(id: UUID) {}

    func refresh() {}
    func primaryMirrorDidOpen(_ device: DeviceRow) -> UUID { UUID() }
    func primaryMirrorDidClose(lease: UUID) {}
    func primaryMirrorDeviceID(for lease: UUID) -> String? { nil }
    func shutdownForApplicationTermination() async {}
}

@MainActor
final class ApplicationWindowCoordinator: ObservableObject {
    func shutdownForApplicationTermination() async {}
}

@MainActor
final class GalaxyBridgeApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let invocation: NativeCloseAllAppInvocation
        do {
            invocation = try NativeCloseAllAppInvocation.current()
            try invocation.writePID()
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }

        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            do {
                try GalaxyBridgeMacAppWiringCloseAllSpec.run()
                try invocation.writeResult(
                    status: "PASS",
                    message: "PASS actual GalaxyBridgeMacApp lifecycle routes generated Close All to both primaries"
                )
            } catch {
                try? invocation.writeResult(status: "FAIL", message: "FAIL: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    func installCleanupHandler(_ handler: @escaping @MainActor () async -> Void) {}
}

struct ContentView: View {
    @EnvironmentObject private var mirrorWindows: DeviceMirrorWindowPresenter

    var body: some View {
        Text("Controlled production-app wiring host")
            .frame(width: 320, height: 180)
            .onAppear {
                GalaxyBridgeMacAppWiringCloseAllSpec.observe(presenter: mirrorWindows)
            }
    }
}

struct PresentedDeviceMirror: View {
    init(lease: UUID, model: AppModel) {}
    var body: some View { EmptyView() }
}

struct AboutView: View {
    var body: some View { Text("Controlled About scene") }
}

struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {}
    }
}

@MainActor
private final class ProductionAppCloseProbe: NSObject, NSWindowDelegate {
    private weak var presenter: DeviceMirrorWindowPresenter?
    private(set) var shouldCloseCount = 0
    private(set) var willCloseCount = 0

    init(presenter: DeviceMirrorWindowPresenter) {
        self.presenter = presenter
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCount += 1
        return true
    }

    func windowWillClose(_ notification: Notification) {
        willCloseCount += 1
        presenter?.windowWillClose(notification)
    }
}

@MainActor
private final class OrdinaryWindowCloseProbe: NSObject, NSWindowDelegate {
    private(set) var willCloseCount = 0

    func windowWillClose(_ notification: Notification) {
        willCloseCount += 1
    }
}

@MainActor
private final class ProductionStockCloseAllProbe: NSObject {
    var onAction: ((Any?) -> Void)?
    private(set) var actionCount = 0

    @objc func closeAll(_ sender: Any?) {
        actionCount += 1
        onAction?(sender)
    }
}

@MainActor
enum GalaxyBridgeMacAppWiringCloseAllSpec {
    private static let closeAllAction = NSSelectorFromString("closeAll:")
    private static weak var presenter: DeviceMirrorWindowPresenter?

    static func observe(presenter: DeviceMirrorWindowPresenter) {
        self.presenter = presenter
    }

    static func run() throws {
        try expect(
            waitUntil { NSApp.isActive },
            "the isolated Close All app host must activate only itself"
        )
        let presenter = try expectValue(
            presenter,
            "the actual GalaxyBridgeMacApp environment must retain its production presenter"
        )
        let initialMain = try expectValue(
            NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
            "the actual WindowGroup must create its initial main window"
        )
        initialMain.performClose(nil)
        drainMainQueue()

        let initialMenu = try expectValue(NSApp.mainMenu, "the actual app must own a generated main menu")
        let commandN = try expectValue(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "n",
                charactersIgnoringModifiers: "n",
                isARepeat: false,
                keyCode: 45
            ),
            "the isolated local Cmd-N event must be constructible"
        )
        try expect(
            initialMenu.performKeyEquivalent(with: commandN),
            "the actual generated menu must consume Cmd-N"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        try expect(
            NSApp.windows.contains(where: {
                $0 !== initialMain && $0.isVisible && $0.canBecomeMain
            }),
            "Cmd-N must recreate the actual WindowGroup content"
        )

        let primaryA = makeRegisteredMirror(deviceID: "actual-app-a", presenter: presenter)
        let primaryB = makeRegisteredMirror(deviceID: "actual-app-b", presenter: presenter)
        let ordinary = makeOrdinaryWindow()
        let ordinaryProbe = OrdinaryWindowCloseProbe()
        ordinary.delegate = ordinaryProbe
        primaryA.window.orderFront(nil)
        primaryB.window.orderFront(nil)
        ordinary.orderFront(nil)
        defer {
            tearDown(primaryA.window)
            tearDown(primaryB.window)
            tearDown(ordinary)
        }

        try expect(
            presenter.ownsPrimaryWindow(primaryA.window)
                && presenter.ownsPrimaryWindow(primaryB.window),
            "both primaries must be genuinely owned by the production presenter after main-scene recreation"
        )
        let menu = try expectValue(NSApp.mainMenu, "the recreated app must retain its generated main menu")
        let generatedItem = try uniqueCloseAllItem(in: menu)
        try expect(
            generatedItem.target is NativeCloseAllCommandRouter,
            "the actual GalaxyBridgeMacApp onAppear installer must own the generated Close All item"
        )
        let stock = ProductionStockCloseAllProbe()
        stock.onAction = { sender in
            ordinary.performClose(sender)
            NotificationCenter.default.post(name: NSMenu.didRemoveItemNotification, object: generatedItem.menu)
            NotificationCenter.default.post(name: NSMenu.didAddItemNotification, object: generatedItem.menu)
        }
        let (replacementMenu, item) = controlledMenu(from: generatedItem, target: stock)
        let generatedFileMenu = try expectValue(
            generatedItem.menu,
            "the generated Close All item must belong to its native File menu"
        )
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: generatedFileMenu)
        NSApp.mainMenu = replacementMenu
        NotificationCenter.default.post(name: NSMenu.didRemoveItemNotification, object: generatedFileMenu)
        NotificationCenter.default.post(name: NSMenu.didAddItemNotification, object: item.menu)
        try expect(
            item.target is NativeCloseAllCommandRouter,
            "replacement after tracking begins must bind synchronously before native dispatch"
        )
        try expect(
            NSApp.sendAction(closeAllAction, to: item.target, from: item),
            "the replacement closeAll: item must dispatch in the same native tracking transaction"
        )
        try expectEqual(stock.actionCount, 1, "the preserved stock Close All action must forward exactly once")
        try expectEqual(ordinaryProbe.willCloseCount, 1, "stock Close All must close the ordinary window")
        try expectEqual(primaryA.probe.shouldCloseCount, 1, "actual app-wired Close All must attempt primary A once")
        try expectEqual(primaryB.probe.shouldCloseCount, 1, "actual app-wired Close All must attempt primary B once")
        try expectEqual(primaryA.probe.willCloseCount, 1, "actual app-wired Close All must close primary A")
        try expectEqual(primaryB.probe.willCloseCount, 1, "actual app-wired Close All must close primary B")

        let nestedStock = ProductionStockCloseAllProbe()
        let (nestedMenu, nestedItem) = controlledMenu(from: generatedItem, target: nestedStock)
        NSApp.mainMenu = nestedMenu
        NotificationCenter.default.post(name: NSMenu.didAddItemNotification, object: nestedItem.menu)
        try expect(
            nestedItem.target is NativeCloseAllCommandRouter,
            "a nested tracking scope must keep later replacement reconciliation synchronous"
        )
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: generatedFileMenu)

        let outerStock = ProductionStockCloseAllProbe()
        let (outerMenu, outerItem) = controlledMenu(from: generatedItem, target: outerStock)
        NSApp.mainMenu = outerMenu
        NotificationCenter.default.post(name: NSMenu.didAddItemNotification, object: outerItem.menu)
        try expect(
            outerItem.target is NativeCloseAllCommandRouter,
            "ending the nested File scope must leave the outer tracking scope synchronous"
        )
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)

        let settledStock = ProductionStockCloseAllProbe()
        let (settledMenu, settledItem) = controlledMenu(from: generatedItem, target: settledStock)
        NSApp.mainMenu = settledMenu
        NotificationCenter.default.post(name: NSMenu.didAddItemNotification, object: settledItem.menu)
        try expect(
            settledItem.target === settledStock,
            "outside tracking, replacement reconciliation must remain asynchronously coalesced"
        )
    }

    private static func makeRegisteredMirror(
        deviceID: String,
        presenter: DeviceMirrorWindowPresenter
    ) -> (window: SeamlessMirrorWindow, probe: ProductionAppCloseProbe) {
        let window = SeamlessMirrorWindow(
            contentRect: NSRect(x: 40, y: 40, width: 432, height: 832),
            styleMask: MirrorWindowActivationPolicy.seamlessFocusableStyleMask(from: []),
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        presenter.registerPrimaryWindow(window, forDeviceID: deviceID)
        let probe = ProductionAppCloseProbe(presenter: presenter)
        window.delegate = probe
        return (window, probe)
    }

    private static func makeOrdinaryWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 520, y: 40, width: 480, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Controlled Calculator"
        window.isReleasedWhenClosed = false
        return window
    }

    private static func uniqueCloseAllItem(in menu: NSMenu) throws -> NSMenuItem {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ menu: NSMenu) -> [NSMenuItem] {
            guard visited.insert(ObjectIdentifier(menu)).inserted else { return [] }
            return menu.items.flatMap { item in
                (item.action == closeAllAction ? [item] : []) + (item.submenu.map(visit) ?? [])
            }
        }
        let matches = visit(menu)
        try expectEqual(matches.count, 1, "actual generated main menu must contain one exact closeAll: item")
        return matches[0]
    }

    private static func controlledMenu(
        from generatedItem: NSMenuItem,
        target: AnyObject
    ) -> (menu: NSMenu, item: NSMenuItem) {
        let mainMenu = NSMenu(title: "Main")
        let fileMenu = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let item = NSMenuItem(
            title: generatedItem.title,
            action: generatedItem.action,
            keyEquivalent: generatedItem.keyEquivalent
        )
        item.keyEquivalentModifierMask = generatedItem.keyEquivalentModifierMask
        item.target = target
        fileMenu.addItem(item)
        return (mainMenu, item)
    }

    private static func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }

    private static func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func tearDown(_ window: NSWindow) {
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProductionAppFailure(message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else {
            throw ProductionAppFailure("\(message): expected \(expected), got \(actual)")
        }
    }

    private static func expectValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ProductionAppFailure(message) }
        return value
    }
}

private struct ProductionAppFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
