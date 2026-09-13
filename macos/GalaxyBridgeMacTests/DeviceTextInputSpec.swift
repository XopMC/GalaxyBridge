import AppKit
import Foundation
import GalaxyBridgeCore

@main
@MainActor
enum DeviceTextInputSpec {
    static func main() throws {
        let view = DeviceInputNSView(frame: NSRect(x: 0, y: 0, width: 360, height: 780))
        var committedText: [String] = []
        var keys: [(ScrcpyKeyAction, UInt32, UInt32)] = []
        var keyRepeatCounts: [UInt32] = []
        var navigation: [UInt32] = []
        var deliveryOrder: [DeliveryEvent] = []
        view.onText = {
            committedText.append($0)
            deliveryOrder.append(.text($0))
        }
        view.onKey = { action, keycode, repeatCount, metaState in
            keys.append((action, keycode, metaState))
            keyRepeatCounts.append(repeatCount)
            deliveryOrder.append(.key(action, keycode))
        }
        view.onNavigation = {
            navigation.append($0)
            deliveryOrder.append(.navigation($0))
        }

        try expect(
            view.acceptsFirstMouse(for: nil),
            "the first click in an inactive mirror must activate Android input instead of being swallowed"
        )

        view.insertText("G", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("B", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("_", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expectEqual(committedText, [], "adjacent printable inserts wait for the short batching window")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(committedText, ["GB_"], "rapid adjacent printable inserts reach Android as one text action")
        committedText.removeAll()
        deliveryOrder.removeAll()

        // Real AppKit hardware events are not always delivered back-to-back.
        // Keep an ordinary fast word atomic so scrcpy performs one clipboard
        // paste instead of racing several asynchronous Android clipboard
        // updates and dropping characters.
        view.insertText("G", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.055))
        view.insertText("B", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.055))
        view.insertText("_TEST_123", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expectEqual(committedText, [], "fast physical typing remains one pending text batch")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(
            committedText,
            ["GB_TEST_123"],
            "realistic inter-key timing reaches Android as one lossless text action"
        )
        committedText.removeAll()
        deliveryOrder.removeAll()

        view.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("B", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.doCommand(by: NSSelectorFromString("cancelOperation:"))
        try expectEqual(
            deliveryOrder,
            [.text("AB"), .navigation(4)],
            "navigation flushes accumulated text before the Android command"
        )
        committedText.removeAll()
        navigation.removeAll()
        deliveryOrder.removeAll()

        view.setMarkedText("e\u{301}", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(view.hasMarkedText(), "composition must be held locally until it is committed")
        try expectEqual(view.markedRange(), NSRange(location: 0, length: 2), "marked range uses Cocoa UTF-16 offsets")
        try expectEqual(view.selectedRange(), NSRange(location: 2, length: 0), "marked selection is exposed to the input method")
        try expectEqual(committedText, [], "marked text must not leak incomplete IME composition to Android")

        view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expectEqual(committedText, ["é"], "insertText commits composed text exactly once")
        try expect(!view.hasMarkedText(), "committing text clears marked composition")

        view.setMarkedText(NSAttributedString(string: "かな"), selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        var actualRange = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(forProposedRange: NSRange(location: 1, length: 1), actualRange: &actualRange)
        try expectEqual(substring?.string, "な", "input method can query its marked document")
        try expectEqual(actualRange, NSRange(location: 1, length: 1), "query reports the bounded actual range")
        view.unmarkText()
        try expectEqual(committedText, ["é", "かな"], "unmarkText accepts pending composition without dropping text")

        view.setMarkedText("отмена", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.doCommand(by: NSSelectorFromString("cancelOperation:"))
        try expectEqual(committedText, ["é", "かな"], "cancelled composition is not committed")
        try expect(!view.hasMarkedText(), "cancelOperation clears pending composition")
        try expectEqual(navigation, [], "first Escape cancels IME locally instead of navigating Android back")
        view.doCommand(by: NSSelectorFromString("cancelOperation:"))
        try expectEqual(navigation, [4], "Escape without composition navigates Android back")

        view.doCommand(by: NSSelectorFromString("insertNewline:"))
        try expectKeyPair(keys, keycode: 66, metaState: 0, "Return command")
        keys.removeAll()
        view.doCommand(by: NSSelectorFromString("moveLeftAndModifySelection:"))
        try expectKeyPair(keys, keycode: 21, metaState: 0x41, "Shift-left selection command")

        view.insertText(NSAttributedString(string: "g"), replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(committedText.last, "g", "attributed insertText reaches Android as plain UTF-8 text")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        let focusStealer = FocusStealingView(frame: .zero)
        view.addSubview(focusStealer)
        try expect(window.makeFirstResponder(view), "input surface starts with keyboard focus")
        view.insertText("focus", replacementRange: NSRange(location: NSNotFound, length: 0))
        try expect(window.makeFirstResponder(focusStealer), "test control can temporarily take keyboard focus")
        try expectEqual(committedText.last, "focus", "focus resignation flushes pending printable text")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        try expect(
            window.firstResponder === view,
            "key-window activation restores DeviceInputNSView after a control or another window had focus"
        )

        let headerPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.addChildWindow(headerPanel, ordered: .above)
        try expect(window.makeFirstResponder(focusStealer), "header focus test starts away from the input surface")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: headerPanel)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        try expect(
            window.firstResponder === view,
            "activating the detached header restores keyboard focus to its phone window"
        )
        window.removeChildWindow(headerPanel)

        try expect(window.makeFirstResponder(view), "input surface must become the window first responder")
        let event = try keyEvent(type: .keyDown, characters: "h", keyCode: 4, window: window)
        let countBeforeKeyEvent = committedText.count
        view.keyDown(with: event)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(committedText.count, countBeforeKeyEvent + 1, "keyDown must emit exactly one text insertion")
        try expectEqual(committedText.last, "h", "keyDown is routed through Cocoa Text Input Services")

        committedText.removeAll()
        let rapidCyrillic: [(String, UInt16)] = [("п", 35), ("р", 15), ("и", 34)]
        for (character, keyCode) in rapidCyrillic {
            view.keyDown(with: try keyEvent(type: .keyDown, characters: character, keyCode: keyCode, window: window))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(
            committedText,
            ["при"],
            "rapid Cyrillic key events use one UTF-8 text callback without requiring an Android IME change"
        )

        committedText.removeAll()
        view.insertText("Привет", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: try keyEvent(type: .keyDown, characters: " ", keyCode: 49, window: window))
        view.insertText("Galaxy", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: try keyEvent(type: .keyDown, characters: " ", keyCode: 49, window: window))
        view.insertText("123", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(
            committedText,
            ["Привет Galaxy 123"],
            "a rapid mixed-layout phrase, including spaces, is committed as one atomic text batch"
        )

        committedText.removeAll()
        window.sendEvent(try keyEvent(type: .keyDown, characters: "w", keyCode: 13, window: window))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(
            committedText,
            ["w"],
            "a key event dispatched through the real borderless window reaches the input surface"
        )

        committedText.removeAll()
        let preDispatchLatin = try keyEvent(
            type: .keyDown,
            characters: "g",
            keyCode: 5,
            window: window
        )
        try expect(
            view.handlePreDispatchKeyEvent(preDispatchLatin),
            "an ordinary printable character must be claimed before the borderless window menu dispatch can drop it"
        )
        let preDispatchCyrillic = try keyEvent(
            type: .keyDown,
            characters: "п",
            keyCode: 35,
            window: window
        )
        try expect(
            view.handlePreDispatchKeyEvent(preDispatchCyrillic),
            "a physical Cyrillic character must use the same pre-dispatch text path"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(
            committedText,
            ["gп"],
            "Latin and Cyrillic physical keys reach Android exactly once through the borderless window"
        )

        committedText.removeAll()
        let optionGeneratedLatin = try keyEvent(
            type: .keyDown,
            characters: "g",
            keyCode: 5,
            modifiers: .option,
            window: window
        )
        try expect(
            view.handlePreDispatchKeyEvent(optionGeneratedLatin),
            "an Option-generated printable character must be claimed before the menu system drops it"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.11))
        try expectEqual(
            committedText,
            ["g"],
            "an Option-generated printable character reaches Android exactly once"
        )

        keys.removeAll()
        keyRepeatCounts.removeAll()
        let leftArrow = String(UnicodeScalar(0xF702)!)
        view.keyDown(with: try keyEvent(type: .keyDown, characters: leftArrow, keyCode: 123, window: window))
        try expect(
            keys.count == 1 && keys[0].0 == .down && keys[0].1 == 21,
            "physical left arrow must remain down until AppKit delivers keyUp"
        )
        view.keyUp(with: try keyEvent(type: .keyUp, characters: leftArrow, keyCode: 123, window: window))
        try expectKeyPair(keys, keycode: 21, metaState: 0, "physical left arrow")

        let controlKeys: [(name: String, characters: String, mac: UInt16, android: UInt32)] = [
            ("Return", "\r", 36, 66),
            ("Delete", "\u{7f}", 51, 67),
            ("Right arrow", String(UnicodeScalar(0xF703)!), 124, 22),
            ("Down arrow", String(UnicodeScalar(0xF701)!), 125, 20),
            ("Up arrow", String(UnicodeScalar(0xF700)!), 126, 19),
        ]
        for control in controlKeys {
            keys.removeAll()
            keyRepeatCounts.removeAll()
            view.keyDown(with: try keyEvent(
                type: .keyDown,
                characters: control.characters,
                keyCode: control.mac,
                window: window
            ))
            view.keyDown(with: try keyEvent(
                type: .keyDown,
                characters: control.characters,
                keyCode: control.mac,
                isARepeat: true,
                window: window
            ))
            try expectEqual(
                keys.map(\.0),
                [.down, .down],
                "held \(control.name) emits down and repeat without an early up"
            )
            try expectEqual(
                keys.map(\.1),
                [control.android, control.android],
                "held \(control.name) preserves the Android keycode"
            )
            try expectEqual(keyRepeatCounts, [0, 1], "held \(control.name) preserves repeat state")
            view.keyUp(with: try keyEvent(
                type: .keyUp,
                characters: control.characters,
                keyCode: control.mac,
                window: window
            ))
            try expectEqual(
                keys.map(\.0),
                [.down, .down, .up],
                "held \(control.name) releases exactly once on keyUp"
            )
        }

        keys.removeAll()
        keyRepeatCounts.removeAll()
        let commandV = try keyEvent(
            type: .keyDown,
            characters: "м",
            keyCode: 9,
            modifiers: .command,
            window: window
        )
        view.pasteTextProvider = { "PASTE_Привет" }
        deliveryOrder.removeAll()
        view.insertText("Q", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyDown(with: commandV)
        try expectEqual(keys.count, 0, "Command-V must not depend on Android hardware-shortcut handling")
        try expectEqual(
            deliveryOrder,
            [.text("Q"), .text("PASTE_Привет")],
            "Command-V flushes pending typing before explicitly inserting the Mac clipboard text"
        )
        try expectEqual(committedText.last, "PASTE_Привет", "Command-V inserts the clipboard exactly once")

        keys.removeAll()
        let commandC = try keyEvent(
            type: .keyDown,
            characters: "c",
            keyCode: 8,
            modifiers: .command,
            window: window
        )
        try expect(
            view.handlePreDispatchKeyEvent(commandC),
            "Command-C must be claimed by the input surface before the macOS Edit menu consumes it"
        )
        try expectKeyPair(
            keys,
            keycode: 31,
            metaState: 0x3000,
            "pre-dispatch Command-C"
        )

        var clipboardCommands: [RemoteClipboardCommand] = []
        view.onClipboardCommand = {
            clipboardCommands.append($0)
            return true
        }
        keys.removeAll()
        try expect(
            view.handlePreDispatchKeyEvent(commandC),
            "Command-C must be consumed by the dedicated enhanced clipboard request"
        )
        try expectEqual(clipboardCommands, [.copy], "Command-C requests a remote clipboard copy")
        try expectEqual(keys.count, 0, "handled remote copy must not also inject a generic Ctrl-C chord")

        let commandX = try keyEvent(
            type: .keyDown,
            characters: "x",
            keyCode: 7,
            modifiers: .command,
            window: window
        )
        try expect(
            view.handlePreDispatchKeyEvent(commandX),
            "Command-X must be consumed by the dedicated enhanced clipboard request"
        )
        try expectEqual(clipboardCommands, [.copy, .cut], "Command-X requests a remote clipboard cut")
        try expectEqual(keys.count, 0, "handled remote cut must not also inject a generic Ctrl-X chord")

        committedText.removeAll()
        keys.removeAll()
        view.pasteTextProvider = { "PRE_DISPATCH_PASTE" }
        try expect(
            view.handlePreDispatchKeyEvent(commandV),
            "Command-V must be claimed before the macOS Edit menu consumes it"
        )
        try expectEqual(
            committedText,
            ["PRE_DISPATCH_PASTE"],
            "pre-dispatch Command-V enters the Mac clipboard exactly once"
        )
        try expectEqual(keys.count, 0, "pre-dispatch Command-V remains a text transaction")

        keys.removeAll()
        keyRepeatCounts.removeAll()
        let repeatedCommandV = try keyEvent(
            type: .keyDown,
            characters: "м",
            keyCode: 9,
            modifiers: .command,
            isARepeat: true,
            window: window
        )
        view.keyDown(with: repeatedCommandV)
        try expectEqual(
            committedText.suffix(2),
            ["PRE_DISPATCH_PASTE", "PRE_DISPATCH_PASTE"],
            "a deliberate repeated Command-V performs another explicit paste"
        )

        var routedEvents: [RoutedEvent] = []
        for route in InputRoute.allCases {
            let routedView = DeviceInputNSView(frame: NSRect(x: 0, y: 0, width: 360, height: 780))
            routedView.onText = { routedEvents.append(.text(route, $0)) }
            routedView.onKey = { action, keycode, _, _ in routedEvents.append(.key(route, action, keycode)) }
            routedView.insertText("Galaxy Привет", replacementRange: NSRange(location: NSNotFound, length: 0))
            routedView.doCommand(by: NSSelectorFromString("insertNewline:"))
        }
        try expectEqual(
            routedEvents,
            [
                .text(.enhancedADB, "Galaxy Привет"),
                .key(.enhancedADB, .down, 66),
                .key(.enhancedADB, .up, 66),
                .text(.companionLAN, "Galaxy Привет"),
                .key(.companionLAN, .down, 66),
                .key(.companionLAN, .up, 66),
            ],
            "the transport-neutral callbacks expose identical text and command events to Enhanced ADB and Companion LAN"
        )

        print("PASS DeviceInput NSTextInputClient commits text, preserves IME composition, and routes commands")
    }

    private static func expectKeyPair(
        _ keys: [(ScrcpyKeyAction, UInt32, UInt32)],
        keycode: UInt32,
        metaState: UInt32,
        _ message: String
    ) throws {
        try expect(keys.count == 2, "\(message) must send one down/up pair")
        try expect(keys[0].0 == .down && keys[1].0 == .up, "\(message) action order")
        try expect(keys[0].1 == keycode && keys[1].1 == keycode, "\(message) keycode")
        try expect(keys[0].2 == metaState && keys[1].2 == metaState, "\(message) modifiers")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message: message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else {
            throw SpecFailure(message: "\(message): expected \(expected), got \(actual)")
        }
    }

    private static func keyEvent(
        type: NSEvent.EventType,
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false,
        window: NSWindow
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isARepeat,
            keyCode: keyCode
        ) else {
            throw SpecFailure(message: "missing synthetic key event")
        }
        return event
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private final class FocusStealingView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
}

private enum DeliveryEvent: Equatable {
    case text(String)
    case key(ScrcpyKeyAction, UInt32)
    case navigation(UInt32)
}

private enum InputRoute: CaseIterable {
    case enhancedADB
    case companionLAN
}

private enum RoutedEvent: Equatable {
    case text(InputRoute, String)
    case key(InputRoute, ScrcpyKeyAction, UInt32)
}
