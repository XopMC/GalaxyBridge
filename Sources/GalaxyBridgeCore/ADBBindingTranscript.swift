import CryptoKit
import Foundation

/// Canonical signed proof that an ADB serial and an already paired companion
/// identity refer to the same physical Android device.
public enum ADBBindingTranscript {
    private static let domain = Data("GalaxyBridge/ADBBinding/v1".utf8)

    public static func make(
        hostID: String,
        adbSerial: String,
        nonce: Data,
        androidPublicKey: Data
    ) -> Data {
        encode([
            domain,
            Data(hostID.utf8),
            Data(adbSerial.utf8),
            nonce,
            androidPublicKey,
        ])
    }

    public static func verify(
        signatureDER: Data,
        hostID: String,
        adbSerial: String,
        nonce: Data,
        androidPublicKey: Data
    ) throws -> Bool {
        let publicKey = try P256.Signing.PublicKey(x963Representation: androidPublicKey)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        return publicKey.isValidSignature(
            signature,
            for: make(
                hostID: hostID,
                adbSerial: adbSerial,
                nonce: nonce,
                androidPublicKey: androidPublicKey
            )
        )
    }

    private static func encode(_ fields: [Data]) -> Data {
        var result = Data()
        for field in fields {
            precondition(field.count <= Int(UInt32.max))
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }
}
