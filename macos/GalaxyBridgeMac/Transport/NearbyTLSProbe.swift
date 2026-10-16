import CryptoKit
import Foundation
@preconcurrency import Network
import Security

private final class NearbyTLSProbeOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private let connection: NWConnection
    init(address: String, port: UInt16, pin: Data, continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificate = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first else { complete(false); return }
            complete(Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data)) == pin)
        }, .global(qos: .utility))
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        connection = NWConnection(host: .init(address), port: .init(rawValue: port)!, using: parameters)
    }
    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: finish(nil)
            case .failed, .cancelled: finish(NearbyTransportFailure.authentication)
            default: break
            }
        }
        connection.start(queue: .global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { [self] in finish(NearbyTransportFailure.timeout) }
    }
    private func finish(_ error: Error?) {
        let pending = lock.withLock { let result = continuation; continuation = nil; return result }
        guard let pending else { return }
        connection.stateUpdateHandler = nil; connection.cancel()
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}

enum NearbyTLSProbe {
    static func verify(address: String, port: UInt16, pin: Data) async throws {
        guard pin.count == 32, port > 0,
              IPv4Address(address) != nil || IPv6Address(address) != nil else { throw NearbyTransportFailure.descriptor }
        try await withCheckedThrowingContinuation { continuation in
            NearbyTLSProbeOwner(address: address, port: port, pin: pin, continuation: continuation).start()
        }
    }
}
