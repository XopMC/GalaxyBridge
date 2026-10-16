import Foundation

/// Session-generation tokens, never advertisement identities, own creation.
struct NearbyGroupAdmission {
    enum Decision { case create, join, wait }
    private(set) var creator: UUID?
    private(set) var queued: [UUID] = []
    private var creatorRetiring = false
    mutating func request(_ session: UUID, sharedGroup: Bool, cleanupPending: Bool) -> Decision {
        if !cleanupPending, !creatorRetiring, creator == nil || creator == session {
            queued.removeAll { $0 == session }
            if sharedGroup { return .join }
            creator = session; return .create
        }
        // A retired creator can outlive its physical session until remote TTL
        // proves cleanup. All five new live sessions must retain a queue slot.
        let waitingLimit = creatorRetiring || cleanupPending ? 5 : 4
        if !queued.contains(session), queued.count < waitingLimit { queued.append(session) }
        return .wait
    }
    mutating func verified(_ session: UUID) {
        guard creator == session, !creatorRetiring else { return }
        creator = nil
    }
    mutating func retiring(_ session: UUID) {
        queued.removeAll { $0 == session }
        if creator == session { creatorRetiring = true }
    }
    mutating func settled(_ session: UUID) {
        guard creator == session else { return }
        creator = nil; creatorRetiring = false
    }
}

struct NearbyGroupRetirementState {
    var wifiSettled: Bool
    var remoteSafeAfter: ContinuousClock.Instant
    var remoteAcknowledged = false
    func settled(at now: ContinuousClock.Instant, taskRunning: Bool, bluetoothRetiring: Bool) -> Bool {
        wifiSettled && now >= remoteSafeAfter && !taskRunning && !bluetoothRetiring
    }
}

enum NearbyRemoteLeaseDeadline {
    static func delivered(at time: ContinuousClock.Instant, previous: ContinuousClock.Instant?) -> ContinuousClock.Instant {
        max(previous ?? time, time + .seconds(50)) //45s phone TTL plus5s margin after observation/outcome
    }
    static func retiring(at time: ContinuousClock.Instant, previous: ContinuousClock.Instant?) -> ContinuousClock.Instant {
        guard let previous else { return time }
        return max(previous, time + .seconds(60)) //45s TTL +8s request +2s close +5s margin
    }
}
