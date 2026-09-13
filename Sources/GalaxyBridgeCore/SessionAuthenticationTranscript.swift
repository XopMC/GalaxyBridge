import Foundation

public enum SessionAuthenticationTranscript {
    private static let domain = Data("GalaxyBridge/SessionAuthentication/v1".utf8)

    public static func make(
        deviceID: String,
        sessionID: String,
        nonce: Data,
        timestampUnixSeconds: Int64,
        identityPublicKey: Data
    ) -> Data {
        var timestamp = UInt64(bitPattern: timestampUnixSeconds).bigEndian
        let timestampData = withUnsafeBytes(of: &timestamp) { Data($0) }
        var result = Data()
        for field in [
            domain,
            Data(deviceID.utf8),
            Data(sessionID.utf8),
            nonce,
            timestampData,
            identityPublicKey,
        ] {
            precondition(field.count <= Int(UInt32.max))
            var length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }
}
