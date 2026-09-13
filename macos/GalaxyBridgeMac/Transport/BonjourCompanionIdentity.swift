import CryptoKit
import Foundation

struct BonjourCompanionIdentity: Equatable, Hashable, Sendable {
    let deviceID: String?
    let publicKeyFingerprint: Data?
    let protocolMajor: Int?
}

struct ParsedBonjourAdvertisement: Equatable, Sendable {
    let identity: BonjourCompanionIdentity
    let displayName: String?
}

enum BonjourAdvertisementParser {
    static func parse(entries: [String: String]) -> ParsedBonjourAdvertisement {
        let deviceID = entries["id"].flatMap(canonicalDeviceID)
        let fingerprint = entries["pkfp"].flatMap(hexData)
        let protocolMajor = entries["v"].flatMap(Int.init)
        let name = entries["name"].flatMap(cleanDisplayName)
        return ParsedBonjourAdvertisement(
            identity: BonjourCompanionIdentity(
                deviceID: deviceID,
                publicKeyFingerprint: fingerprint,
                protocolMajor: protocolMajor
            ),
            displayName: name
        )
    }

    static func displayName(txtName: String?, serviceName: String) -> String {
        if let txtName = txtName.flatMap(cleanDisplayName) { return txtName }
        var candidate = serviceName
        if candidate.hasPrefix("GalaxyBridge ") {
            candidate.removeFirst("GalaxyBridge ".count)
        }
        if let suffixRange = candidate.range(
            of: #" \([0-9]+\)$"#,
            options: .regularExpression
        ) {
            candidate.removeSubrange(suffixRange)
        }
        return cleanDisplayName(candidate) ?? "Samsung Galaxy"
    }

    private static func canonicalDeviceID(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString.lowercased()
    }

    private static func hexData(_ value: String) -> Data? {
        guard value.utf8.count == 64 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func cleanDisplayName(_ value: String) -> String? {
        let cleaned = value
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(128))
    }
}

enum CompanionPeerMatcher {
    static func logicalDeviceID(
        discoveryID: String,
        identity: BonjourCompanionIdentity,
        peers: [PairedPeer]
    ) -> String {
        match(identity: identity, peers: peers).map { "device:\($0.deviceID)" } ?? "lan:\(discoveryID)"
    }

    static func match(identity: BonjourCompanionIdentity, peers: [PairedPeer]) -> PairedPeer? {
        guard identity.protocolMajor == 1,
              let advertisedDeviceID = identity.deviceID,
              let advertisedFingerprint = identity.publicKeyFingerprint
        else { return nil }
        return peers.first { peer in
            peer.deviceID.lowercased() == advertisedDeviceID &&
                Data(SHA256.hash(data: peer.identityPublicKey)) == advertisedFingerprint
        }
    }
}
