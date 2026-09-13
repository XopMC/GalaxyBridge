import CryptoKit
import Foundation

public struct SealedPayload: Sendable, Equatable {
    public let combined: Data

    public init(combined: Data) {
        self.combined = combined
    }
}

public enum EncryptedPayload {
    public static func seal(
        _ plaintext: Data,
        using key: SymmetricKey,
        authenticatedData: Data = Data()
    ) throws -> SealedPayload {
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: authenticatedData
        )
        guard let combined = sealedBox.combined else {
            throw EncryptedPayloadError.missingCombinedRepresentation
        }
        return SealedPayload(combined: combined)
    }

    public static func open(
        _ payload: SealedPayload,
        using key: SymmetricKey,
        authenticatedData: Data = Data()
    ) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: payload.combined)
        return try AES.GCM.open(
            sealedBox,
            using: key,
            authenticating: authenticatedData
        )
    }
}

public enum EncryptedPayloadError: Error, Equatable {
    case missingCombinedRepresentation
}
