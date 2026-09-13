import AppKit
import Foundation

@MainActor
private final class WindowSource: NativeCloseAllPrimaryWindowSource {
    var mirrors: [SeamlessMirrorWindow] = []

    func closeAllPrimaryWindowsSnapshot() -> [SeamlessMirrorWindow] { mirrors }
    func ownsPrimaryWindow(_ window: NSWindow) -> Bool { mirrors.contains { $0 === window } }
}

@MainActor
private final class CloseProbe: NSObject, NSWindowDelegate {
    private(set) var willCloseCount = 0
    func windowWillClose(_ notification: Notification) { willCloseCount += 1 }
}

@main
@MainActor
private enum NativePrimaryCloseCommandRouterSpec {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            do {
                try run()
                print("PASS generated native Close targets the frontmost seamless mirror and preserves ordinary windows")
                Foundation.exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                Foundation.exit(EXIT_FAILURE)
            }
        }
        NSApp.run()
    }

    private static func run() throws {
        let ordinary = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let mirror = SeamlessMirrorWindow(
            contentRect: NSRect(x: 120, y: 90, width: 430, height: 780),
            styleMask: MirrorWindowActivationPolicy.seamlessFocusableStyleMask(from: []),
            backing: .buffered,
            defer: false
        )
        ordinary.isReleasedWhenClosed = false
        mirror.isReleasedWhenClosed = false
        let ordinaryProbe = CloseProbe()
        let mirrorProbe = CloseProbe()
        ordinary.delegate = ordinaryProbe
        mirror.delegate = mirrorProbe
        defer {
            ordinary.delegate = nil
            mirror.delegate = nil
            ordinary.orderOut(nil)
            mirror.orderOut(nil)
            ordinary.close()
            mirror.close()
        }

        let root = NSMenu(title: "Main")
        let file = NSMenu(title: "File")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        root.addItem(fileItem)
        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = .command
        file.addItem(closeItem)
        NSApp.mainMenu = root

        let source = WindowSource()
        source.mirrors = [mirror]
        let router = NativePrimaryCloseCommandRouter(
            primaryWindowSource: source,
            notificationCenter: NotificationCenter()
        )
        router.install()
        try expect(closeItem.target === router, "the generated Close item must be bound to the ownership router")

        ordinary.makeKeyAndOrderFront(nil)
        mirror.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(NSApp.orderedWindows.first === mirror, "the seamless mirror must be the frontmost app window")
        try expect(router.validateMenuItem(closeItem), "frontmost closable mirror must enable Close")
        let mirrorCommandW = try commandW(windowNumber: mirror.windowNumber)
        try expect(file.performKeyEquivalent(with: mirrorCommandW),
                   "the generated menu must consume Cmd-W")
        try expect(mirrorProbe.willCloseCount == 1, "Cmd-W must close the frontmost mirror exactly once")
        try expect(ordinaryProbe.willCloseCount == 0, "closing a mirror must leave the document window open")

        ordinary.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let ordinaryCommandW = try commandW(windowNumber: ordinary.windowNumber)
        try expect(file.performKeyEquivalent(with: ordinaryCommandW),
                   "ordinary Close must still use native responder routing")
        try expect(ordinaryProbe.willCloseCount == 1, "ordinary app window must remain independently closeable")
    }

    private static func commandW(windowNumber: Int) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: 13
        ) else { throw Failure("could not construct Cmd-W") }
        return event
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
