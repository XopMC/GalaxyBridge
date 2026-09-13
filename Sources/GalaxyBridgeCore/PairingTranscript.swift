import CryptoKit
import Foundation

public enum PairingTranscript {
    private static let domain = Data("GalaxyBridge/Pairing/v1".utf8)
    private static let requestDomain = Data("GalaxyBridge/PairingRequest/v1".utf8)
    private static let commitDomain = Data("GalaxyBridge/PairingCommit/v1".utf8)
    private static let commitAcknowledgementDomain = Data("GalaxyBridge/PairingCommitAck/v1".utf8)

    public static func makeRequest(
        token: Data,
        clientNonce: Data,
        macPublicKey: Data,
        displayName: Data
    ) -> Data {
        encode([requestDomain, token, clientNonce, macPublicKey, displayName])
    }

    public static func make(
        token: Data,
        clientNonce: Data,
        serverNonce: Data,
        macPublicKey: Data,
        androidPublicKey: Data
    ) -> Data {
        encode([domain, token, clientNonce, serverNonce, macPublicKey, androidPublicKey])
    }

    public static func makeCommit(
        token: Data,
        clientNonce: Data,
        serverNonce: Data,
        macPublicKey: Data,
        androidPublicKey: Data,
        hostID: String,
        deviceID: String,
        sessionID: String
    ) -> Data {
        encode([
            commitDomain,
            token,
            clientNonce,
            serverNonce,
            macPublicKey,
            androidPublicKey,
            Data(hostID.utf8),
            Data(deviceID.utf8),
            Data(sessionID.utf8),
        ])
    }

    public static func makeCommitAcknowledgement(
        commitTranscript: Data,
        commitSignature: Data
    ) -> Data {
        encode([commitAcknowledgementDomain, commitTranscript, commitSignature])
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

    public static func verify(
        signatureDER: Data,
        transcript: Data,
        publicKeyX963: Data
    ) throws -> Bool {
        let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyX963)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureDER)
        return publicKey.isValidSignature(signature, for: transcript)
    }
}
