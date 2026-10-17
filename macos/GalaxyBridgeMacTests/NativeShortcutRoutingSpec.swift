import Foundation
import OSLog

struct NSEvent {
    struct ModifierFlags: OptionSet, Sendable {
        let rawValue: UInt
        static let command = Self(rawValue: 1)
        static let control = Self(rawValue: 2)
        static let shift = Self(rawValue: 4)
        static let option = Self(rawValue: 8)
        static let deviceIndependentFlagsMask = Self(rawValue: 15)
    }
    let keyCode: UInt16
    var modifierFlags: ModifierFlags = [.command]
    var characters: String? = "`"
    var isARepeat = false
}
enum ScrcpyKeyAction: Equatable { case down, up }
enum RemoteClipboardCommand: Equatable { case copy, cut }
@MainActor final class SyntheticInputWindow { func makeFirstResponder(_ view: ShortcutInputProbe) {} }
@MainActor class NativeResponderProbe {
    var nativeEvents: [UInt16] = []
    @MainActor init() {}
    func keyDown(with event: NSEvent) { nativeEvents.append(event.keyCode) }
}
@MainActor final class ShortcutInputProbe: NativeResponderProbe {
    let logger = Logger(subsystem: "com.xopmc.GalaxyBridge.synthetic-test", category: "shortcuts")
    var window: SyntheticInputWindow?
    var activeKeys: [UInt16: (androidKeycode: UInt32, metaState: UInt32)] = [:]
    var interpretedKeyEvent: NSEvent?
    var didHandleInterpretedKeyEvent = false
    var onKey: ((ScrcpyKeyAction, UInt32, UInt32, UInt32) -> Void)?
    var onText: ((String) -> Void)?
    var onClipboardCommand: ((RemoteClipboardCommand) -> Bool)?
    var pasteTextProvider: () -> String? = { "clipboard" }
    var text: [String] = []
    var keys: [(ScrcpyKeyAction, UInt32, UInt32)] = []
    var clipboardCommands: [RemoteClipboardCommand] = []
    override init() {
        super.init()
        onKey = { [weak self] action, code, _, modifiers in self?.keys.append((action, code, modifiers)) }
        onText = { [weak self] in self?.text.append($0) }
        onClipboardCommand = { [weak self] in self?.clipboardCommands.append($0); return true }
    }
    func hasMarkedText() -> Bool { false }
    func interpretKeyEvents(_ events: [NSEvent]) {}
    func flushPendingText() {}
    func enqueueText(_ value: String) { text.append(value) }
    // ACTUAL_SHORTCUT_METHODS
}
@main enum NativeShortcutRoutingSpec {
    @MainActor static func main() {
        let input = ShortcutInputProbe()
        for event in [NSEvent(keyCode: 50), NSEvent(keyCode: 50, modifierFlags: [.command, .shift]),
                      NSEvent(keyCode: 13, characters: "w"), NSEvent(keyCode: 13, modifierFlags: [.command, .option], characters: "w"),
                      NSEvent(keyCode: 46, characters: "m"), NSEvent(keyCode: 12, characters: "q")] {
            precondition(!input.handlePreDispatchKeyEvent(event), "Native command was consumed before AppKit")
            input.keyDown(with: event)
        }
        precondition(input.text.isEmpty && input.keys.isEmpty && input.clipboardCommands.isEmpty,
            "Unhandled native Command shortcuts reached the remote phone")
        precondition(input.nativeEvents == [50, 50, 13, 13, 46, 12], "Native Command shortcuts did not continue through the responder chain")
        input.keyDown(with: NSEvent(keyCode: 0, characters: "a"))
        precondition(input.keys.count == 2 && input.keys[0].0 == .down && input.keys[0].1 == 29 && input.keys[0].2 == 0x3000 && input.keys[1].0 == .up,
            "Android Cmd-A control mapping changed")
        input.keyDown(with: NSEvent(keyCode: 9, characters: "v"))
        input.keyDown(with: NSEvent(keyCode: 8, characters: "c"))
        input.keyDown(with: NSEvent(keyCode: 7, characters: "x"))
        precondition(input.text == ["clipboard"] && input.clipboardCommands == [.copy, .cut], "Existing remote copy/cut/paste routing changed")
        precondition(input.nativeEvents.count == 6)
        print("PASS actual shortcut entry points: native Cmd-grave/reverse/close/close-all/minimize/quit stay local; Android select-all and copy/cut/paste preserved")
    }
}
