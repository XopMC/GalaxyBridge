#if !GALAXYBRIDGE_APP_STORE
import Foundation

struct ADBBindingRecoveryPolicy: Equatable, Sendable {
    let requestTimeout: TimeInterval
    let retryBackoffs: [TimeInterval]
    let attemptLimit: Int

    static let production = ADBBindingRecoveryPolicy(
        requestTimeout: 8,
        retryBackoffs: [4, 12],
        attemptLimit: 3
    )

    init(requestTimeout: TimeInterval, retryBackoffs: [TimeInterval], attemptLimit: Int) {
        precondition(requestTimeout > 0)
        precondition(attemptLimit > 0)
        precondition(retryBackoffs.count >= max(0, attemptLimit - 1))
        precondition(retryBackoffs.allSatisfy { $0 >= 0 })
        self.requestTimeout = requestTimeout
        self.retryBackoffs = retryBackoffs
        self.attemptLimit = attemptLimit
    }

    func backoff(afterAttempt attempt: Int) -> TimeInterval {
        guard !retryBackoffs.isEmpty else { return 0 }
        return retryBackoffs[min(max(0, attempt - 1), retryBackoffs.count - 1)]
    }
}

struct ADBBindingSession: Equatable, Hashable, Sendable {
    let companionID: String
    let generation: UInt64
}

struct ADBBindingCandidate: Sendable {
    let serial: String
    let peer: PairedPeer
    let hostID: String
    let nameMatches: Bool
    let revalidate: Bool
}

struct ADBBindingRecoveryExhaustion: Equatable, Sendable {
    let serial: String
    let peerID: String
    let attempts: Int
}
#endif
