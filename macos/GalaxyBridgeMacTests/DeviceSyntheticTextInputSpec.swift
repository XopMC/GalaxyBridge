import AppKit
import Foundation

/// Exercises the real input boundary without opening windows, posting system
/// events, changing the keyboard layout, or touching another application's UI.
@main
@MainActor
enum DeviceSyntheticTextInputSpec {
    static func main() throws {
        let phrase = "Привет Galaxy 123"
        let physicalCodes: [UInt16] = [5, 4, 11, 2, 17, 45, 49, 5, 0, 37, 0, 7, 16, 49, 18, 19, 20]
        try verify(phrase, codes: physicalCodes, label: "mixed-script characters supplied by a synthetic injector")
        try verify(phrase, codes: Array(repeating: 0, count: phrase.count), label: "Unicode injection reusing one physical key code")
        try verify("Galaxy", codes: [5, 0, 37, 0, 7, 16], label: "all Latin characters supplied under any active keyboard layout")
        print("PASS hidden input boundary: mixed scripts, complete Latin payload, reused synthetic keycodes; no system events posted")
    }

    private static func verify(_ text: String, codes: [UInt16], label: String) throws {
        let view = DeviceInputNSView(frame: .zero)
        var committed: [String] = []
        var unexpectedKeys = 0
        view.onText = { committed.append($0) }
        view.onKey = { _, _, _, _ in unexpectedKeys += 1 }
        guard codes.count == text.count else { throw Failure(message: "Invalid fixture") }
        for (index, character) in text.enumerated() {
            let value = String(character)
            let modifiers: NSEvent.ModifierFlags = value == "G" || value == "П" ? [.shift] : []
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: Double(index) / 1_000, windowNumber: 0, context: nil,
                characters: value, charactersIgnoringModifiers: value.lowercased(),
                isARepeat: false, keyCode: codes[index]
            ), view.handlePreDispatchKeyEvent(event) else {
                throw Failure(message: "Supplied printable event was rejected at index \(index): \(label)")
            }
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        guard committed == [text], unexpectedKeys == 0 else {
            throw Failure(message: "Input payload changed: \(label); expected \(text), got \(committed)")
        }
    }

    private struct Failure: Error { let message: String }
}
