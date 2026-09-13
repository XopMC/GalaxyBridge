public enum TransportKind: String, CaseIterable, Codable, Hashable, Sendable {
    case usbADB
    case wirelessADB
    case companionLAN

    fileprivate var priority: Int {
        switch self {
        case .usbADB: 3
        case .wirelessADB: 2
        case .companionLAN: 1
        }
    }
}

public enum TransportSelector {
    public static func connectionLabelKeys(for transports: [TransportKind]) -> [String] {
        var labels: [String] = []
        if transports.contains(.usbADB) { labels.append("USB_ADB") }
        if transports.contains(where: { $0 != .usbADB }) { labels.append("COMPANION_LAN") }
        return labels
    }

    public static func preferred<S: Sequence>(from transports: S) -> TransportKind?
    where S.Element == TransportKind {
        transports.max { left, right in
            left.priority < right.priority
        }
    }

    /// Transports shown as connected in user-facing copy. If no route is live,
    /// the known routes remain visible so setup errors still have context.
    public static func presented(from snapshots: [TransportSnapshot]) -> [TransportKind] {
        let connected = snapshots.filter(\.isConnected)
        let source = connected.isEmpty ? snapshots : connected
        return Array(Set(source.map(\.kind))).sorted { left, right in
            left.priority > right.priority
        }
    }
}
