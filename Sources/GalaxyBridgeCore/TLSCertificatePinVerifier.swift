import CryptoKit
import Foundation

public enum TLSCertificatePinVerifier {
    public static let sha256Length = 32

    public static func fingerprint(certificateDER: Data) -> Data {
        Data(SHA256.hash(data: certificateDER))
    }

    public static func matches(certificateDER: Data, expectedSHA256: Data) -> Bool {
        guard expectedSHA256.count == sha256Length else { return false }
        return fingerprint(certificateDER: certificateDER) == expectedSHA256
    }
}
