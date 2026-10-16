import Foundation

/// SurfaceFlinger panel state, independent of PowerManager wakefulness and
/// virtual display state. This says nothing about Android keyguard.
public enum PhonePanelPowerState: Equatable, Sendable {
    case on, off, unknown
}

public enum PhonePanelPowerParser {
    public static func parse(_ output: String) -> PhonePanelPowerState {
        struct Display { var physical = false; var mode: PhonePanelPowerState? }
        var displays: [String: Display] = [:]
        var currentID: String?
        var currentVirtual = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.range(of: #"^(?:Virtual )?Display \d+\b"#, options: .regularExpression) != nil {
                currentVirtual = line.hasPrefix("Virtual ")
                let fields = line.split(whereSeparator: \.isWhitespace)
                let index = currentVirtual ? 2 : 1
                let id = String(fields[index].prefix(while: \.isNumber))
                currentID = id
                if displays[id] == nil { displays[id] = Display() }
                if !currentVirtual, line.contains("HWC display") { displays[id]?.physical = true }
            } else if line == "connectionType=Internal", !currentVirtual, let id = currentID {
                displays[id]?.physical = true
            } else if line.hasPrefix("powerMode="), !currentVirtual, let id = currentID {
                let value = line.dropFirst("powerMode=".count).trimmingCharacters(in: .whitespaces)
                displays[id]?.mode = value == "OFF" ? .off : value == "ON" ? .on : .unknown
            }
        }
        let results = displays.values.filter(\.physical).map { $0.mode ?? .unknown }
        // Refuse mixed panel states: a single ON/OFF command cannot restore a
        // foldable's original mixture safely. Never infer OFF from virtuals.
        guard !results.isEmpty, !results.contains(.unknown) else { return .unknown }
        if results.allSatisfy({ $0 == .off }) { return .off }
        if results.allSatisfy({ $0 == .on }) { return .on }
        return .unknown
    }
}
