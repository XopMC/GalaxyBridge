import CryptoKit
import Foundation

@main
enum BonjourIdentityMatchingSpec {
    static func main() throws {
        let keyA = Data(repeating: 0x11, count: 65)
        let keyB = Data(repeating: 0x22, count: 65)
        let peerA = peer(id: "a7ce395c-2f84-49a7-bb39-91a43a3b08b7", key: keyA)
        let peerB = peer(id: "c4cc875d-42e8-44cc-8dd0-90038d3dd9d0", key: keyB)

        let first = BonjourCompanionIdentity(
            deviceID: peerA.deviceID,
            publicKeyFingerprint: Data(SHA256.hash(data: keyA)),
            protocolMajor: 1
        )
        let second = BonjourCompanionIdentity(
            deviceID: peerB.deviceID,
            publicKeyFingerprint: Data(SHA256.hash(data: keyB)),
            protocolMajor: 1
        )
        try expect(
            CompanionPeerMatcher.match(identity: first, peers: [peerA, peerB]) == peerA,
            "the first of two same-model phones must map to its own persisted identity"
        )
        try expect(
            CompanionPeerMatcher.match(identity: second, peers: [peerA, peerB]) == peerB,
            "the second of two same-model phones must map to its own persisted identity"
        )
        let firstEndpointID = "GalaxyBridge SM-S928B._galaxybridge._tcp.local."
        let secondEndpointID = "GalaxyBridge SM-S928B (2)._galaxybridge._tcp.local."
        try expect(
            CompanionPeerMatcher.logicalDeviceID(
                discoveryID: firstEndpointID,
                identity: first,
                peers: [peerA, peerB]
            ) == "device:\(peerA.deviceID)",
            "the first same-model endpoint must route to the first logical device"
        )
        try expect(
            CompanionPeerMatcher.logicalDeviceID(
                discoveryID: secondEndpointID,
                identity: second,
                peers: [peerA, peerB]
            ) == "device:\(peerB.deviceID)",
            "an NSD-suffixed same-model endpoint must route to the second logical device"
        )

        let substitutedFingerprint = BonjourCompanionIdentity(
            deviceID: peerA.deviceID,
            publicKeyFingerprint: Data(SHA256.hash(data: keyB)),
            protocolMajor: 1
        )
        try expect(
            CompanionPeerMatcher.match(identity: substitutedFingerprint, peers: [peerA, peerB]) == nil,
            "a UUID with another phone's public-key fingerprint must never select a pinned peer"
        )
        try expect(
            CompanionPeerMatcher.match(
                identity: BonjourCompanionIdentity(
                    deviceID: peerA.deviceID,
                    publicKeyFingerprint: nil,
                    protocolMajor: 1
                ),
                peers: [peerA, peerB]
            ) == nil,
            "an advertisement without verifiable identity must remain unpaired instead of name-matching"
        )
        try expect(
            CompanionPeerMatcher.logicalDeviceID(
                discoveryID: secondEndpointID,
                identity: BonjourCompanionIdentity(
                    deviceID: nil,
                    publicKeyFingerprint: nil,
                    protocolMajor: nil
                ),
                peers: [peerA, peerB]
            ) == "lan:\(secondEndpointID)",
            "an unknown phone must retain its concrete Bonjour endpoint so it remains pairable"
        )
        try expect(
            CompanionPeerMatcher.match(
                identity: BonjourCompanionIdentity(
                    deviceID: peerA.deviceID,
                    publicKeyFingerprint: Data(SHA256.hash(data: keyA)),
                    protocolMajor: 2
                ),
                peers: [peerA, peerB]
            ) == nil,
            "an incompatible protocol advertisement must not start a pinned TLS attempt"
        )

        let parsed = BonjourAdvertisementParser.parse(
            entries: [
                "id": peerA.deviceID.uppercased(),
                "pkfp": Data(SHA256.hash(data: keyA)).map { String(format: "%02x", $0) }.joined(),
                "v": "1",
                "name": "SM-S928B",
            ]
        )
        try expect(parsed.identity == first, "valid TXT identity fields must parse canonically")
        try expect(parsed.displayName == "SM-S928B", "TXT model name must be UI-only display copy")
        try expect(
            BonjourAdvertisementParser.displayName(
                txtName: nil,
                serviceName: "GalaxyBridge SM-S928B (37)"
            ) == "SM-S928B",
            "NSD conflict suffixes must not leak into the device display name"
        )
        try expect(
            BonjourAdvertisementParser.parse(entries: ["id": "not-a-uuid", "pkfp": "00", "v": "1"]).identity.deviceID == nil,
            "malformed public identity fields must not become matchable"
        )

        print("PASS Bonjour TXT identity distinguishes identical models and rejects substituted peers")
        print("PASS Bonjour display copy ignores Android NSD conflict suffixes")
    }

    private static func peer(id: String, key: Data) -> PairedPeer {
        PairedPeer(
            deviceID: id,
            displayName: "Galaxy S24 Ultra",
            identityPublicKey: key,
            tlsCertificateSHA256: Data(repeating: 0x33, count: 32),
            pairedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw BonjourSpecFailure(message: message) }
}

private struct BonjourSpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
