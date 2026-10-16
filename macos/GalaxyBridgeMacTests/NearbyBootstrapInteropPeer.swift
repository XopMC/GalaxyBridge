import Foundation
import CryptoKit
@main struct NearbyBootstrapInteropPeer {
    static func main() throws {
        let identity = P256.Signing.PrivateKey()
        let a = NearbyBootstrapAgreement(role: .initiator, deviceID: "neutral-mac", context: Data(repeating: 3, count: 32),
            identity: identity.publicKey.x963Representation, sign: { try identity.signature(for: $0).derRepresentation })
        print(try a.hello().wireEncoded().base64EncodedString()); fflush(stdout)
        let remote = try NearbyBootstrapHello(wire: Data(base64Encoded: readLine()!)!)
        var session = try a.complete(remote: remote, expectedIdentity: remote.identity, pairingToken: Data(repeating: 17, count: 32))
        print(try session.seal(Data("cross-platform credentials".utf8)).base64EncodedString()); fflush(stdout)
        let plain = try session.open(Data(base64Encoded: readLine()!)!)
        guard plain == Data("Android ready".utf8) else { fatalError("wrong Android response") }
        print("PASS Swift/JCE signed P256 and AES-GCM byte interoperability")
    }
}
