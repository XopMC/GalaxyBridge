import AppKit
import Foundation

@MainActor
private final class NativeCloseTestApplication: NSApplication {
    weak var testKeyWindow: NSWindow?

    override var keyWindow: NSWindow? { testKeyWindow ?? super.keyWindow }
    override var mainWindow: NSWindow? { testKeyWindow ?? super.mainWindow }
}

@MainActor
private final class CloseProbe: NSObject, NSWindowDelegate {
    var allowsClose = true
    private(set) var shouldCloseCount = 0
    private(set) var willCloseCount = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shouldCloseCount += 1
        return allowsClose
    }

    func windowWillClose(_ notification: Notification) {
        willCloseCount += 1
    }
}

@MainActor
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@main
@MainActor
enum NativeCloseCommandSpec {
    static func main() {
        _ = NativeCloseTestApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            do {
                try runSpecs()
                print("PASS native seamless-window Close validation and action dispatch")
                Foundation.exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
                Foundation.exit(EXIT_FAILURE)
            }
        }
        NSApp.run()
    }

    private static func runSpecs() throws {
        try targetNilMenuValidationDoesNotEvaluateVeto()
        try sendActionClosesOnlyTheKeyMirror()
        try commandWUsesTheNativeMenuKeyEquivalent()
        try vetoThenAllowedCloseCleansUpExactlyOnce()
        try contentFirstResponderStillRoutesCloseToItsWindow()
        try ordinaryApplicationWindowRemainsAnIndependentControl()
        try minimizedWindowKeepsNativeCloseEligibility()
        try unrelatedValidationDefersToNSWindow()
        try seamlessAppearanceAndGeometryRemainUnchanged()
    }

    private static func targetNilMenuValidationDoesNotEvaluateVeto() throws {
        let window = makeMirrorWindow()
        let probe = CloseProbe()
        probe.allowsClose = false
        window.delegate = probe
        makeKey(window)
        defer { tearDown(window) }

        let (_, closeItem) = makeCloseMenu()
        closeItem.isEnabled = false
        closeItem.menu?.update()

        try expect(closeItem.target == nil, "Close must use AppKit's actual target-nil responder routing")
        try expect(NSApp.keyWindow === window, "the native harness must establish the mirror as key window")
        try expect(
            NSApp.target(forAction: closeItem.action!, to: nil, from: closeItem) as? NSWindow === window,
            "AppKit must resolve target-nil Close to the key mirror"
        )
        try expect(closeItem.isEnabled, "target-nil Close must validate for the key seamless window")
        try expect(window.validateUserInterfaceItem(closeItem), "the key seamless window must validate Close directly")
        try expectEqual(probe.shouldCloseCount, 0, "menu validation must not invoke a side-effecting close veto")
    }

    private static func sendActionClosesOnlyTheKeyMirror() throws {
        let windowA = makeMirrorWindow(originX: 40)
        let windowB = makeMirrorWindow(originX: 520)
        let probeA = CloseProbe()
        let probeB = CloseProbe()
        windowA.delegate = probeA
        windowB.delegate = probeB
        makeKey(windowA)
        makeKey(windowB)
        defer {
            tearDown(windowA)
            tearDown(windowB)
        }

        let (_, closeItem) = makeCloseMenu()
        let dispatched = NSApp.sendAction(closeItem.action!, to: nil, from: closeItem)

        try expect(dispatched, "NSApp.sendAction must find the native Close target")
        try expectEqual(probeA.willCloseCount, 0, "Close must not use selected-device or creation-order routing")
        try expectEqual(probeB.willCloseCount, 1, "Close must retire only the actual key mirror")
    }

    private static func commandWUsesTheNativeMenuKeyEquivalent() throws {
        let window = makeMirrorWindow()
        let probe = CloseProbe()
        window.delegate = probe
        makeKey(window)
        defer { tearDown(window) }

        let (menu, _) = makeCloseMenu()
        let event = try expectValue(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "w",
                charactersIgnoringModifiers: "w",
                isARepeat: false,
                keyCode: 13
            ),
            "the local Cmd-W event must be constructible"
        )

        try expect(menu.performKeyEquivalent(with: event), "the native menu must consume Cmd-W")
        try expectEqual(probe.willCloseCount, 1, "Cmd-W must dispatch native Close exactly once")
    }

    private static func vetoThenAllowedCloseCleansUpExactlyOnce() throws {
        let window = makeMirrorWindow()
        let probe = CloseProbe()
        probe.allowsClose = false
        window.delegate = probe
        makeKey(window)
        defer { tearDown(window) }

        let (_, closeItem) = makeCloseMenu()
        try expect(NSApp.sendAction(closeItem.action!, to: nil, from: closeItem), "vetoed Close is still handled")
        try expectEqual(probe.shouldCloseCount, 1, "the action must consult the delegate veto once")
        try expectEqual(probe.willCloseCount, 0, "a vetoed window must remain owned")

        probe.allowsClose = true
        try expect(NSApp.sendAction(closeItem.action!, to: window, from: closeItem), "allowed native Close must dispatch")
        try expectEqual(probe.shouldCloseCount, 2, "the allowed action must consult the delegate once")
        try expectEqual(probe.willCloseCount, 1, "allowed Close must run registry cleanup once")

        try expect(NSApp.sendAction(closeItem.action!, to: window, from: closeItem), "repeat native Close remains handled")
        try expectEqual(probe.willCloseCount, 1, "repeat Close must not duplicate registry/session cleanup")
    }

    private static func contentFirstResponderStillRoutesCloseToItsWindow() throws {
        let window = makeMirrorWindow()
        let focusView = FocusableView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = focusView
        let probe = CloseProbe()
        window.delegate = probe
        makeKey(window)
        try expect(window.makeFirstResponder(focusView), "mirror input view must become first responder")
        defer { tearDown(window) }

        let (_, closeItem) = makeCloseMenu()
        try expect(NSApp.sendAction(closeItem.action!, to: nil, from: closeItem), "Close must traverse the input responder chain")
        try expectEqual(probe.willCloseCount, 1, "input focus must still close its owning mirror")
    }

    private static func ordinaryApplicationWindowRemainsAnIndependentControl() throws {
        let mirror = makeMirrorWindow()
        let mirrorProbe = CloseProbe()
        mirror.delegate = mirrorProbe
        let application = NSWindow(
            contentRect: NSRect(x: 520, y: 40, width: 480, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        application.isReleasedWhenClosed = false
        application.standardWindowButton(.closeButton)?.isHidden = true
        application.standardWindowButton(.miniaturizeButton)?.isHidden = true
        application.standardWindowButton(.zoomButton)?.isHidden = true
        let applicationProbe = CloseProbe()
        application.delegate = applicationProbe
        makeKey(mirror)
        makeKey(application)
        defer {
            tearDown(mirror)
            tearDown(application)
        }

        let (_, closeItem) = makeCloseMenu()
        try expect(NSApp.sendAction(closeItem.action!, to: nil, from: closeItem), "ordinary app window Close must remain native")
        try expectEqual(applicationProbe.willCloseCount, 1, "only the key application window cleans up")
        try expectEqual(mirrorProbe.willCloseCount, 0, "application Close must not disconnect or close the primary mirror")
    }

    private static func minimizedWindowKeepsNativeCloseEligibility() throws {
        let window = makeMirrorWindow()
        let probe = CloseProbe()
        window.delegate = probe
        makeKey(window)
        window.miniaturize(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        defer { tearDown(window) }

        let (_, closeItem) = makeCloseMenu()
        try expect(window.isMiniaturized, "the native test window must actually be minimized")
        try expect(window.validateUserInterfaceItem(closeItem), "a minimized owned mirror remains individually close-eligible")
        try expectEqual(probe.shouldCloseCount, 0, "minimized-window validation must not ask the close veto")
    }

    private static func unrelatedValidationDefersToNSWindow() throws {
        let window = makeMirrorWindow()
        defer { tearDown(window) }
        let minimizeItem = NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )

        let nativeResult = window.validateUserInterfaceItem(minimizeItem)
        try expect(nativeResult, "seamless Close support must preserve superclass validation for Minimize")
    }

    private static func seamlessAppearanceAndGeometryRemainUnchanged() throws {
        let frame = NSRect(x: 120, y: 80, width: 432, height: 832)
        let window = SeamlessMirrorWindow(
            contentRect: frame,
            styleMask: MirrorWindowActivationPolicy.seamlessFocusableStyleMask(from: [.titled, .resizable]),
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { tearDown(window) }

        try expect(!window.styleMask.contains(.titled), "native Close must not restore title-bar composition")
        try expect(!window.styleMask.contains(.resizable), "native Close must not restore straight-edge resize")
        try expect(window.standardWindowButton(.closeButton) == nil, "native Close must not add traffic lights")
        try expectEqual(window.frame, frame, "native Close integration must not change the mirror frame")
        try expectEqual(window.contentLayoutRect, window.contentView?.bounds ?? .zero, "all content remains borderless")
    }

    private static func makeMirrorWindow(originX: CGFloat = 40) -> SeamlessMirrorWindow {
        let window = SeamlessMirrorWindow(
            contentRect: NSRect(x: originX, y: 40, width: 432, height: 832),
            styleMask: MirrorWindowActivationPolicy.seamlessFocusableStyleMask(from: []),
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func makeKey(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        (NSApp as? NativeCloseTestApplication)?.testKeyWindow = window
    }

    private static func makeCloseMenu() -> (NSMenu, NSMenuItem) {
        let mainMenu = NSMenu(title: "Main")
        let menu = NSMenu(title: "File")
        menu.autoenablesItems = true
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = menu
        mainMenu.addItem(fileItem)
        NSApp.mainMenu = mainMenu
        let item = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        item.keyEquivalentModifierMask = .command
        item.target = nil
        menu.addItem(item)
        return (menu, item)
    }

    private static func tearDown(_ window: NSWindow) {
        if (NSApp as? NativeCloseTestApplication)?.testKeyWindow === window {
            (NSApp as? NativeCloseTestApplication)?.testKeyWindow = nil
        }
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else {
            throw Failure("\(message): expected \(expected), got \(actual)")
        }
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
