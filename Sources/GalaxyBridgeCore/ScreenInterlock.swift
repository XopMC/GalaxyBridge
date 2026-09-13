import Foundation

/// What the Mac is allowed to present while an enhanced mirror session is active.
/// This state never performs or implies an Android unlock.
public enum ScreenInterlockPresentation: Equatable, Sendable {
    case waitingForFirstFrame
    case mirroring
    case physicalDeviceActive
    case mediaUnavailable
}

/// Prevents a 60 fps decoded-frame stream from republishing an unchanged
/// placeholder state through Combine/SwiftUI.
public struct ScreenInterlockPresentationPublicationState: Sendable {
    private var current: ScreenInterlockPresentation

    public init(initial: ScreenInterlockPresentation) {
        current = initial
    }

    public mutating func consume(
        _ next: ScreenInterlockPresentation
    ) -> ScreenInterlockPresentation? {
        guard next != current else { return nil }
        current = next
        return next
    }
}

public enum PhysicalDisplayState: Equatable, Sendable {
    case off
    case on
    case unknown
}

public enum ScreenInterlockEvent: Equatable, Sendable {
    case controlReady
    case firstFrame
    case physicalDisplayChanged(PhysicalDisplayState)
    case stopped
}

public enum ScreenInterlockEffect: Equatable, Sendable {
    case setPhysicalDisplayPowerOff
    case forcePhysicalDisplayPowerOff
    case applyInteractiveBlackout
    case revealPhysicalDisplay
    case restorePhysicalDisplay
    case startPhysicalDisplayMonitoring
    case stopPhysicalDisplayMonitoring
}

/// Samsung blocks all positional input while its default display power state is
/// OFF. This mode keeps the display logically ON at zero OLED brightness, so
/// the phone looks off while remote touch remains interactive. A physical power
/// press is still honored: the first OFF transition restores and reveals the
/// phone, the next OFF transition reapplies the interactive blackout.
public struct InteractiveDisplayBlackoutStateMachine: Sendable {
    public private(set) var presentation: ScreenInterlockPresentation = .waitingForFirstFrame

    private enum PendingTransition: Sendable {
        case reveal
        case blackout
    }

    private var controlReady = false
    private var receivedFirstFrame = false
    private var blackoutStarted = false
    private var monitoringPhysicalDisplay = false
    private var pendingTransition: PendingTransition?

    public init() {}

    public mutating func handle(_ event: ScreenInterlockEvent) -> [ScreenInterlockEffect] {
        switch event {
        case .controlReady:
            controlReady = true
        case .firstFrame:
            receivedFirstFrame = true
            if presentation == .waitingForFirstFrame { presentation = .mirroring }
        case let .physicalDisplayChanged(state):
            guard monitoringPhysicalDisplay else { return [] }
            switch state {
            case .on:
                pendingTransition = nil
                return []
            case .off:
                guard pendingTransition == nil else { return [] }
                if presentation == .physicalDeviceActive {
                    presentation = receivedFirstFrame ? .mirroring : .waitingForFirstFrame
                    pendingTransition = .blackout
                    return [.applyInteractiveBlackout]
                }
                presentation = .physicalDeviceActive
                pendingTransition = .reveal
                return [.revealPhysicalDisplay]
            case .unknown:
                return []
            }
        case .stopped:
            var effects: [ScreenInterlockEffect] = []
            if blackoutStarted { effects.append(.restorePhysicalDisplay) }
            if monitoringPhysicalDisplay { effects.append(.stopPhysicalDisplayMonitoring) }
            self = InteractiveDisplayBlackoutStateMachine()
            return effects
        }

        guard controlReady, receivedFirstFrame, !blackoutStarted else { return [] }
        blackoutStarted = true
        monitoringPhysicalDisplay = true
        presentation = .mirroring
        return [.applyInteractiveBlackout, .startPhysicalDisplayMonitoring]
    }
}

/// Coordinates scrcpy control readiness, the first decoded frame, and the
/// physical display state. The scrcpy server owns display-power restoration via
/// its `cleanup=true` policy when the session ends.
public struct ScreenInterlockStateMachine: Sendable {
    public private(set) var presentation: ScreenInterlockPresentation = .waitingForFirstFrame

    private var controlReady = false
    private var receivedFirstFrame = false
    private var requestedPhysicalDisplayOff = false
    private var confirmedPhysicalDisplayOff = false
    private var attemptedShellPowerOffFallback = false
    private var monitoringPhysicalDisplay = false

    public init() {}

    public mutating func handle(_ event: ScreenInterlockEvent) -> [ScreenInterlockEffect] {
        var effects: [ScreenInterlockEffect] = []
        switch event {
        case .controlReady:
            controlReady = true
        case .firstFrame:
            receivedFirstFrame = true
            if presentation == .waitingForFirstFrame { presentation = .mirroring }
        case let .physicalDisplayChanged(state):
            guard monitoringPhysicalDisplay else { return [] }
            switch state {
            case .off:
                confirmedPhysicalDisplayOff = true
                presentation = receivedFirstFrame ? .mirroring : .waitingForFirstFrame
            case .on:
                presentation = .physicalDeviceActive
                if requestedPhysicalDisplayOff,
                   !confirmedPhysicalDisplayOff,
                   !attemptedShellPowerOffFallback {
                    attemptedShellPowerOffFallback = true
                    effects.append(.forcePhysicalDisplayPowerOff)
                }
            case .unknown:
                break
            }
        case .stopped:
            let effects: [ScreenInterlockEffect] = monitoringPhysicalDisplay
                ? [.stopPhysicalDisplayMonitoring]
                : []
            self = ScreenInterlockStateMachine()
            return effects
        }

        guard controlReady, receivedFirstFrame, !requestedPhysicalDisplayOff else { return effects }
        requestedPhysicalDisplayOff = true
        monitoringPhysicalDisplay = true
        effects.append(contentsOf: [.setPhysicalDisplayPowerOff, .startPhysicalDisplayMonitoring])
        return effects
    }
}

public enum PhysicalDisplayProbeParser {
    public static func parse(_ output: String) -> PhysicalDisplayState {
        let lines = output.split(whereSeparator: \Character.isNewline).map(String.init)

        for line in lines {
            if let value = firstCapture(
                in: line,
                pattern: #"\bmWakefulness\s*=\s*(Awake|Asleep|Dozing|Dreaming)\b"#
            ) {
                switch value {
                case "Awake", "Dreaming": return .on
                case "Asleep", "Dozing": return .off
                default: break
                }
            }
        }

        // A virtual scrcpy/DeX display may remain ON while the actual panel is
        // OFF. Prefer Android's built-in/default display record over all global
        // fallbacks, regardless of record order.
        for line in lines where isBuiltInDisplayRecord(line) {
            if let state = displayState(in: line) { return state }
        }
        for line in lines {
            if let value = firstCapture(
                in: line,
                pattern: #"(?:Display Power:\s*state|mScreenState)\s*=\s*(ON|OFF|DOZE|DOZE_SUSPEND)\b"#
            ) {
                return normalized(value)
            }
        }
        return .unknown
    }

    private static func isBuiltInDisplayRecord(_ line: String) -> Bool {
        line.contains("DisplayDeviceInfo{") &&
            (line.range(of: #"\btype\s+INTERNAL\b"#, options: .regularExpression) != nil ||
             line.contains("FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY") ||
             line.localizedCaseInsensitiveContains("Built-in Screen"))
    }

    private static func displayState(in line: String) -> PhysicalDisplayState? {
        guard let value = firstCapture(
            in: line,
            pattern: #"\bstate\s*[= ]\s*(ON|OFF|DOZE|DOZE_SUSPEND)\b"#
        ) else { return nil }
        return normalized(value)
    }

    private static func firstCapture(in value: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func normalized(_ value: String) -> PhysicalDisplayState {
        value == "OFF" ? .off : .on
    }
}
