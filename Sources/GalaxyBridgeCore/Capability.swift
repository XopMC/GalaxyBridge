public enum Capability: String, CaseIterable, Codable, Hashable, Sendable {
    case screenCapture
    case inputInjection
    case audioForwarding
    case clipboardRead
    case clipboardWrite
    case files
    case notifications
    case sms
    case calls
    case cameraStream
    case virtualDisplay
    case recording
}

public struct TransportSnapshot: Equatable, Sendable {
    public let kind: TransportKind
    public let isConnected: Bool
    public let capabilities: Set<Capability>

    public init(
        kind: TransportKind,
        isConnected: Bool,
        capabilities: Set<Capability>
    ) {
        self.kind = kind
        self.isConnected = isConnected
        self.capabilities = capabilities
    }
}

public enum CapabilityResolver {
    public static func routes(
        for snapshots: [TransportSnapshot]
    ) -> [Capability: TransportKind] {
        var routes: [Capability: TransportKind] = [:]

        for snapshot in snapshots where snapshot.isConnected {
            for capability in snapshot.capabilities {
                guard let current = routes[capability] else {
                    routes[capability] = snapshot.kind
                    continue
                }
                routes[capability] = TransportSelector.preferred(
                    from: [current, snapshot.kind]
                )
            }
        }

        return routes
    }
}

public enum EnhancedPositionalInputBackend: Equatable, Sendable {
    case scrcpy
    case adbShell
}

/// Positional input must stay on scrcpy's continuous control stream. Launching
/// `adb shell input` only after pointer-up discards every intermediate MOVE,
/// adds a process launch to each gesture and makes drag/trackpad input appear
/// frozen. The enhanced mirror keeps Samsung's physical display logically ON
/// at zero OLED brightness, so display 0 remains interactive without this
/// lossy fallback.
public enum EnhancedPositionalInputRoutingPolicy {
    public static func backend(deviceName: String) -> EnhancedPositionalInputBackend {
        _ = deviceName
        return .scrcpy
    }
}

public enum EnhancedADBTouchCommand: Equatable, Sendable {
    case tap(x: Double, y: Double)
    case swipe(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMilliseconds: Int
    )
}

/// Collapses AppKit's down/many-moves/up stream into one Android shell gesture.
/// Dispatching every MOVE as a separate Accessibility gesture cancels the
/// preceding gesture and is especially unreliable while the Samsung panel is
/// off. One terminal command preserves tap and swipe semantics without a
/// process launch for every move.
public struct EnhancedADBTouchAccumulator: Sendable {
    private struct Point: Sendable {
        let x: Double
        let y: Double
    }

    private var starts: [UInt64: Point] = [:]

    public init() {}

    public mutating func handle(
        _ action: ScrcpyMotionAction,
        pointerID: UInt64,
        x: Double,
        y: Double
    ) -> EnhancedADBTouchCommand? {
        let point = Point(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        switch action {
        case .down:
            starts[pointerID] = point
            return nil
        case .move:
            return nil
        case .up:
            let start = starts.removeValue(forKey: pointerID) ?? point
            let distance = abs(start.x - point.x) + abs(start.y - point.y)
            if distance < 0.01 { return .tap(x: point.x, y: point.y) }
            return .swipe(
                fromX: start.x,
                fromY: start.y,
                toX: point.x,
                toY: point.y,
                durationMilliseconds: 120
            )
        case .cancel:
            starts.removeValue(forKey: pointerID)
            return nil
        }
    }
}
