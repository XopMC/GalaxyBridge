import Foundation

public struct PairingPayload: Equatable, Sendable {
    public let version: UInt32
    public let hostID: UUID
    public let addresses: [String]
    public let port: UInt16
    public let token: Data
    public let publicKeyFingerprint: Data
    public let expiresAt: Date

    public init(
        version: UInt32,
        hostID: UUID,
        addresses: [String],
        port: UInt16,
        token: Data,
        publicKeyFingerprint: Data,
        expiresAt: Date
    ) {
        self.version = version
        self.hostID = hostID
        self.addresses = addresses
        self.port = port
        self.token = token
        self.publicKeyFingerprint = publicKeyFingerprint
        self.expiresAt = expiresAt
    }
}

public enum PairingQRCodeError: Error, Equatable {
    case invalidURL
    case invalidField(String)
    case expired
}

public enum PairingQRCode {
    public static let supportedVersion: UInt32 = 1
    public static let tokenLength = 32
    public static let fingerprintLength = 32
    public static let maximumAddressCount = 8
    public static let maximumLifetime: TimeInterval = 120

    public static func encode(_ payload: PairingPayload) throws -> URL {
        try validate(payload, now: nil)
        var components = URLComponents()
        components.scheme = "galaxybridge"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(payload.version)),
            URLQueryItem(name: "host", value: payload.hostID.uuidString.lowercased()),
            URLQueryItem(name: "port", value: String(payload.port)),
            URLQueryItem(name: "token", value: payload.token.base64URLEncodedString()),
            URLQueryItem(
                name: "fp",
                value: payload.publicKeyFingerprint.base64URLEncodedString()
            ),
            URLQueryItem(
                name: "exp",
                value: String(Int64(payload.expiresAt.timeIntervalSince1970))
            ),
        ] + payload.addresses.map { URLQueryItem(name: "addr", value: $0) }

        guard let url = components.url else {
            throw PairingQRCodeError.invalidURL
        }
        return url
    }

    public static func decode(_ url: URL, now: Date) throws -> PairingPayload {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "galaxybridge",
              components.host == "pair"
        else {
            throw PairingQRCodeError.invalidURL
        }

        let items = components.queryItems ?? []
        func value(_ name: String) throws -> String {
            guard let value = items.first(where: { $0.name == name })?.value else {
                throw PairingQRCodeError.invalidField(name)
            }
            return value
        }

        guard let version = UInt32(try value("v")) else {
            throw PairingQRCodeError.invalidField("v")
        }
        guard let hostID = UUID(uuidString: try value("host")) else {
            throw PairingQRCodeError.invalidField("host")
        }
        guard let port = UInt16(try value("port")), port > 0 else {
            throw PairingQRCodeError.invalidField("port")
        }
        guard let token = Data(base64URLString: try value("token")) else {
            throw PairingQRCodeError.invalidField("token")
        }
        guard let fingerprint = Data(base64URLString: try value("fp")) else {
            throw PairingQRCodeError.invalidField("fp")
        }
        guard let expiresAtSeconds = TimeInterval(try value("exp")) else {
            throw PairingQRCodeError.invalidField("exp")
        }

        let expiresAt = Date(timeIntervalSince1970: expiresAtSeconds)
        let payload = PairingPayload(
            version: version,
            hostID: hostID,
            addresses: items.filter { $0.name == "addr" }.compactMap(\.value),
            port: port,
            token: token,
            publicKeyFingerprint: fingerprint,
            expiresAt: expiresAt
        )
        try validate(payload, now: now)
        return payload
    }

    private static func validate(_ payload: PairingPayload, now: Date?) throws {
        guard payload.version == supportedVersion else {
            throw PairingQRCodeError.invalidField("v")
        }
        guard payload.port > 0 else {
            throw PairingQRCodeError.invalidField("port")
        }
        guard payload.token.count == tokenLength else {
            throw PairingQRCodeError.invalidField("token")
        }
        guard payload.publicKeyFingerprint.count == fingerprintLength else {
            throw PairingQRCodeError.invalidField("fp")
        }
        guard !payload.addresses.isEmpty,
              payload.addresses.count <= maximumAddressCount,
              payload.addresses.allSatisfy(isSafeAddress)
        else {
            throw PairingQRCodeError.invalidField("addr")
        }
        if let now {
            guard payload.expiresAt > now else {
                throw PairingQRCodeError.expired
            }
            guard payload.expiresAt.timeIntervalSince(now) <= maximumLifetime else {
                throw PairingQRCodeError.invalidField("exp")
            }
        }
    }

    private static func isSafeAddress(_ address: String) -> Bool {
        guard !address.isEmpty, address.utf8.count <= 255 else { return false }
        return address.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || ".:-_%".unicodeScalars.contains($0)
        }
    }
}

private extension Data {
    init?(base64URLString: String) {
        var base64 = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
