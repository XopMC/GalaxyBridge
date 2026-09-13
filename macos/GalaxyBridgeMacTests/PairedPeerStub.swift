import Foundation

struct PairedPeer: Equatable, Sendable {
    let deviceID: String
    let displayName: String
    let identityPublicKey: Data
    let tlsCertificateSHA256: Data
    let pairedAt: Date
}
