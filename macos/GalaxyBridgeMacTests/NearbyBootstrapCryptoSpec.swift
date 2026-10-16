import CryptoKit
import Foundation

@main struct NearbyBootstrapCryptoSpec {
    static func main() throws {
        let a = P256.Signing.PrivateKey(), b = P256.Signing.PrivateKey()
        let context = Data(repeating: 9, count: 32)
        let left = NearbyBootstrapAgreement(role: .initiator, deviceID: "mac", context: context,
            identity: a.publicKey.x963Representation, sign: { try a.signature(for: $0).derRepresentation })
        let right = NearbyBootstrapAgreement(role: .responder, deviceID: "phone", context: context,
            identity: b.publicKey.x963Representation, sign: { try b.signature(for: $0).derRepresentation })
        let lh = try left.hello(), rh = try right.hello()
        let token = Data(repeating: 17, count: 32)
        var ls = try left.complete(remote: rh, expectedIdentity: b.publicKey.x963Representation, pairingToken: token)
        var rs = try right.complete(remote: lh, expectedIdentity: a.publicKey.x963Representation, pairingToken: token)
        let plain = Data("private network credentials".utf8)
        let encrypted = try ls.seal(plain)
        let opened = try rs.open(encrypted); precondition(opened == plain)
        do { _ = try rs.open(encrypted); fatalError("replay accepted") } catch {}
        let response = try rs.seal(Data("ready".utf8))
        let ready = try ls.open(response); precondition(ready == Data("ready".utf8))
        do { _ = try left.complete(remote: rh, expectedIdentity: a.publicKey.x963Representation, pairingToken: token); fatalError("wrong peer") } catch {}
        var wrong = try right.complete(remote: lh, expectedIdentity: a.publicKey.x963Representation, pairingToken: Data(repeating: 2, count: 32))
        var tokenProbe = try left.complete(remote: rh, expectedIdentity: b.publicKey.x963Representation, pairingToken: token)
        do { _ = try wrong.open(try tokenProbe.seal(plain)); fatalError("wrong QR token") } catch {}
        let next = try ls.seal(Data("next".utf8)); var damaged = next; damaged[damaged.count - 1] ^= 1
        do { _ = try rs.open(damaged); fatalError("tamper accepted") } catch {}
        let final = try rs.open(next); precondition(final == Data("next".utf8), "failed authentication must not advance counter")
        do { _ = try ls.seal(Data(repeating: 0, count: 8193)); fatalError("oversize") } catch {}
        print("PASS nearby signed P256 agreement, QR binding, directional AES-GCM, tamper, replay and bounds")
    }
}
