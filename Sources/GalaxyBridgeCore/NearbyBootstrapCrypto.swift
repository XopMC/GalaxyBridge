import CryptoKit
import Foundation

public enum NearbyBootstrapFailure: Error { case invalidHello, identityMismatch, signature, frame, replay, exhausted }
public enum NearbyBootstrapRole: UInt8, Codable, Sendable { case initiator = 0, responder = 1 }
public struct NearbyBootstrapHello: Codable, Sendable {
    public let version: Int
    public let role: NearbyBootstrapRole
    public let deviceID: String
    public let context: Data
    public let identity: Data
    public let ephemeral: Data
    public let nonce: Data
    public let signature: Data
    public func wireEncoded() -> Data {
        NearbyBootstrapEncoding.fields([Data([UInt8(version)]), Data([role.rawValue]), Data(deviceID.utf8),
            context, identity, ephemeral, nonce, signature])
    }
    public init(wire: Data) throws {
        guard wire.count <= 8192 else { throw NearbyBootstrapFailure.invalidHello }
        var offset = 0
        func field() throws -> Data {
            guard offset + 4 <= wire.count else { throw NearbyBootstrapFailure.invalidHello }
            let n = wire[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; offset += 4
            guard n <= 8192, offset + Int(n) <= wire.count else { throw NearbyBootstrapFailure.invalidHello }
            defer { offset += Int(n) }; return wire.subdata(in: offset..<offset+Int(n))
        }
        let v = try field(), r = try field(), id = try field()
        guard v == Data([1]), r.count == 1, let role = NearbyBootstrapRole(rawValue: r[0]),
              let name = String(data: id, encoding: .utf8) else { throw NearbyBootstrapFailure.invalidHello }
        version = 1; self.role = role; deviceID = name
        context = try field(); identity = try field(); ephemeral = try field(); nonce = try field(); signature = try field()
        guard offset == wire.count else { throw NearbyBootstrapFailure.invalidHello }
    }
    public init(version: Int, role: NearbyBootstrapRole, deviceID: String, context: Data,
                identity: Data, ephemeral: Data, nonce: Data, signature: Data) {
        self.version = version; self.role = role; self.deviceID = deviceID; self.context = context
        self.identity = identity; self.ephemeral = ephemeral; self.nonce = nonce; self.signature = signature
    }
    public var transcript: Data {
        NearbyBootstrapEncoding.fields([Data("GalaxyBridge/Nearby/Hello/v1".utf8), Data([role.rawValue]),
            Data(deviceID.utf8), context, identity, ephemeral, nonce])
    }
    public func validated(expectedIdentity: Data) throws {
        guard version == 1, !deviceID.isEmpty, deviceID.utf8.count <= 256,
              context.count == 32, nonce.count == 32, identity.count == 65,
              ephemeral.count == 65, (8...80).contains(signature.count) else { throw NearbyBootstrapFailure.invalidHello }
        guard identity == expectedIdentity else { throw NearbyBootstrapFailure.identityMismatch }
        let key = try P256.Signing.PublicKey(x963Representation: identity)
        guard key.isValidSignature(try .init(derRepresentation: signature), for: transcript)
        else { throw NearbyBootstrapFailure.signature }
    }
}

public final class NearbyBootstrapAgreement {
    private let role: NearbyBootstrapRole
    private let deviceID: String
    private let context: Data
    private let identity: Data
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    private let sign: (Data) throws -> Data
    public init(role: NearbyBootstrapRole, deviceID: String, context: Data, identity: Data,
                sign: @escaping (Data) throws -> Data) {
        self.role = role; self.deviceID = deviceID; self.context = context; self.identity = identity; self.sign = sign
    }
    public func hello() throws -> NearbyBootstrapHello {
        let h = NearbyBootstrapHello(version: 1, role: role, deviceID: deviceID, context: context,
            identity: identity, ephemeral: ephemeral.publicKey.x963Representation, nonce: nonce, signature: Data())
        let signed = NearbyBootstrapHello(version: 1, role: role, deviceID: deviceID, context: context,
            identity: identity, ephemeral: h.ephemeral, nonce: nonce, signature: try sign(h.transcript))
        try signed.validated(expectedIdentity: identity)
        return signed
    }
    public func complete(remote: NearbyBootstrapHello, expectedIdentity: Data, pairingToken: Data? = nil) throws -> NearbyBootstrapSession {
        try remote.validated(expectedIdentity: expectedIdentity)
        guard remote.role != role, remote.context == context,
              pairingToken == nil || pairingToken?.count == 32 else { throw NearbyBootstrapFailure.invalidHello }
        let local = try hello()
        let first = role == .initiator ? local : remote
        let second = role == .responder ? local : remote
        let transcript = NearbyBootstrapEncoding.fields([first.transcript, second.transcript])
        let binding = Data(SHA256.hash(data: transcript))
        let salt = Data(SHA256.hash(data: NearbyBootstrapEncoding.fields([binding, pairingToken ?? Data()])))
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: .init(x963Representation: remote.ephemeral))
        let material = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("GalaxyBridge/Nearby/Keys/v1".utf8), outputByteCount: 64).withUnsafeBytes { Data($0) }
        let forward = SymmetricKey(data: material.prefix(32)), reverse = SymmetricKey(data: material.suffix(32))
        return NearbyBootstrapSession(send: role == .initiator ? forward : reverse,
            receive: role == .initiator ? reverse : forward, binding: binding, role: role)
    }
}

/// One owner per GATT connection; counters advance only after successful AEAD.
public struct NearbyBootstrapSession {
    private let send: SymmetricKey
    private let receive: SymmetricKey
    private let binding: Data
    private let role: NearbyBootstrapRole
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    fileprivate init(send: SymmetricKey, receive: SymmetricKey, binding: Data, role: NearbyBootstrapRole) {
        self.send = send; self.receive = receive; self.binding = binding; self.role = role
    }
    public mutating func seal(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 8192 else { throw NearbyBootstrapFailure.frame }
        guard sendCounter < UInt64.max else { throw NearbyBootstrapFailure.exhausted }
        let counter = NearbyBootstrapEncoding.counter(sendCounter)
        let direction = role.rawValue
        let nonce = try AES.GCM.Nonce(data: Data([0, 0, 0, direction]) + counter)
        let sealed = try AES.GCM.seal(data, using: send, nonce: nonce, authenticating: binding + Data([direction]) + counter)
        sendCounter += 1
        return counter + sealed.ciphertext + sealed.tag
    }
    public mutating func open(_ frame: Data) throws -> Data {
        guard (25...8216).contains(frame.count) else { throw NearbyBootstrapFailure.frame }
        guard receiveCounter < UInt64.max else { throw NearbyBootstrapFailure.exhausted }
        let counter = NearbyBootstrapEncoding.counter(receiveCounter)
        guard frame.prefix(8) == counter else { throw NearbyBootstrapFailure.replay }
        let direction: UInt8 = role == .initiator ? 1 : 0
        let nonce = try AES.GCM.Nonce(data: Data([0, 0, 0, direction]) + counter)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: frame.dropFirst(8).dropLast(16), tag: frame.suffix(16))
        let data = try AES.GCM.open(box, using: receive, authenticating: binding + Data([direction]) + counter)
        receiveCounter += 1
        return data
    }
}

private enum NearbyBootstrapEncoding {
    static func fields(_ values: [Data]) -> Data {
        var out = Data()
        for value in values {
            var length = UInt32(value.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }; out.append(value)
        }
        return out
    }
    static func counter(_ value: UInt64) -> Data {
        var v = value.bigEndian; return withUnsafeBytes(of: &v) { Data($0) }
    }
}
