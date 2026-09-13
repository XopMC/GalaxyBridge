import Foundation

struct WirelessADBReconnectPeer {
    let deviceID: String
    let endpoint: String
    let hardwareSerial: String?
    let verifiedAt: Date
}

enum WirelessADBReconnectPolicy {
    /// Input records have already been checked against the paired identity.
    /// Bonjour locates a port, never grants trust; the connection is rebound
    /// using the signed nonce before it is merged with a Companion device.
    static func candidates(
        peers: [WirelessADBReconnectPeer],
        connectedSerials: Set<String>,
        mdnsServices: String
    ) -> [String] {
        let services = mdnsServices.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, fields[1] == "_adb-tls-connect._tcp",
                  isLocalEndpoint(fields[2]) else { return nil }
            return (fields[0], fields[2])
        }
        var visited = Set<String>()
        return peers.sorted { $0.verifiedAt > $1.verifiedAt }.compactMap { peer in
            guard visited.insert(peer.deviceID).inserted else { return nil }
            if connectedSerials.contains(peer.endpoint) { return nil }
            if let serial = peer.hardwareSerial,
               let service = services.first(where: { $0.0.hasPrefix("adb-\(serial)-") }) {
                return connectedSerials.contains(service.0) || connectedSerials.contains(service.1) ? nil : service.1
            }
            return isLocalEndpoint(peer.endpoint) ? peer.endpoint : nil
        }
    }

    static func isLocalEndpoint(_ endpoint: String) -> Bool {
        let fields = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let port = UInt16(fields[1]), port > 0 else { return false }
        let octets = fields[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let bytes = octets.compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168) ||
            (bytes[0] == 172 && (16...31).contains(bytes[1])) ||
            (bytes[0] == 169 && bytes[1] == 254)
    }
}
