import Foundation

public enum TransportKind: Sendable {
    case usbADB
    case wirelessADB
    case companionLAN
}

public enum ADBWiFiIPv4AddressParser {
    public static func parse(_ output: String) -> String? {
        output
            .split(whereSeparator: \.isWhitespace)
            .first(where: { token in
                let value = token.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                let octets = value.split(separator: ".")
                return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
            })
            .map { String($0.split(separator: "/", maxSplits: 1)[0]) }
    }
}

public struct ScrcpyDisplay: Sendable {}

public enum ScrcpyDisplayParser {
    public static func parse(_ output: String) -> [ScrcpyDisplay] { [] }
}

public enum ScrcpyLaunchConfiguration {
    public static let remoteServerPath = "/data/local/tmp/scrcpy-server.jar"
    public static let serverVersion = "4.1"
    public static let serverSHA256Hex = "expected-scrcpy-sha256"
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

public enum PhysicalDisplayState: Equatable, Sendable {
    case off
    case on
    case unknown
}

public enum PhysicalDisplayProbeParser {
    public static func parse(_ output: String) -> PhysicalDisplayState {
        if output.contains("Dozing") || output.contains("Asleep") { return .off }
        if output.contains("Awake") { return .on }
        return .unknown
    }
}
