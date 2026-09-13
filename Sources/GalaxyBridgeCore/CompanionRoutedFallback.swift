import Foundation

public enum CompanionRoutedFallback {
    /// Stable TLS port used only as a routed-subnet fallback. Bonjour continues
    /// to advertise and resolve the actual listener on a shared link.
    public static let port: UInt16 = 46_737
}

public enum CompanionEndpointSource: Equatable, Sendable {
    case none
    case bonjour
    case routed
}

public enum CompanionEndpointSelectionPolicy {
    public static func source(
        hasBonjour: Bool,
        hasRoutedAddress: Bool,
        routedSessionActive: Bool
    ) -> CompanionEndpointSource {
        if routedSessionActive, hasRoutedAddress { return .routed }
        if hasBonjour { return .bonjour }
        if hasRoutedAddress { return .routed }
        return .none
    }
}

/// Keeps endpoint failover sticky per authenticated peer. A stale Bonjour
/// result can otherwise remain in NWBrowser indefinitely and prevent the
/// already verified routed address from ever being tried.
public struct CompanionEndpointFailoverState: Sendable {
    private var preferredSources: [String: CompanionEndpointSource] = [:]

    public init() {}

    public func source(
        peerID: String,
        hasBonjour: Bool,
        hasRoutedAddress: Bool,
        routedSessionActive: Bool
    ) -> CompanionEndpointSource {
        if routedSessionActive, hasRoutedAddress { return .routed }
        switch preferredSources[peerID] {
        case .routed where hasRoutedAddress:
            return .routed
        case .bonjour where hasBonjour:
            return .bonjour
        default:
            return CompanionEndpointSelectionPolicy.source(
                hasBonjour: hasBonjour,
                hasRoutedAddress: hasRoutedAddress,
                routedSessionActive: false
            )
        }
    }

    public mutating func recordFailure(peerID: String, source: CompanionEndpointSource) {
        switch source {
        case .bonjour:
            preferredSources[peerID] = .routed
        case .routed:
            preferredSources[peerID] = .bonjour
        case .none:
            preferredSources.removeValue(forKey: peerID)
        }
    }

    public mutating func recordSuccess(peerID: String, source: CompanionEndpointSource) {
        guard source != .none else { return }
        preferredSources[peerID] = source
    }

    public mutating func forget(peerID: String) {
        preferredSources.removeValue(forKey: peerID)
    }
}

public enum ADBWiFiIPv4AddressParser {
    public static func parse(_ output: String) -> String? {
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard let inetIndex = fields.firstIndex(of: "inet"),
                  fields.indices.contains(fields.index(after: inetIndex))
            else { continue }
            let addressWithPrefix = fields[fields.index(after: inetIndex)]
            guard let address = addressWithPrefix.split(separator: "/").first,
                  isUnicastIPv4(address)
            else { continue }
            return String(address)
        }
        return nil
    }

    private static func isUnicastIPv4(_ value: Substring) -> Bool {
        let octets = value.split(separator: ".")
        guard octets.count == 4,
              octets.allSatisfy({ UInt8($0) != nil }),
              value != "0.0.0.0",
              !value.hasPrefix("127.")
        else { return false }
        return true
    }
}
