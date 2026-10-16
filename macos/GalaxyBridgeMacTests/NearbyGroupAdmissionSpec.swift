import Foundation

@main enum NearbyGroupAdmissionSpec {
    static func main() {
        let ownerToken = UUID(), dependentToken = UUID(), independentToken = UUID()
        let ownerFact = NearbyGroupMember(generation: ownerToken, deviceID: "A", target: "A", ownerDeviceID: "A", anchor: false)
        let dependentFact = NearbyGroupMember(generation: dependentToken, deviceID: "B", target: "B", ownerDeviceID: "A", anchor: false)
        let independentFact = NearbyGroupMember(generation: independentToken, deviceID: "C", target: "C", ownerDeviceID: "C", anchor: false)
        let members = [independentFact, ownerFact, dependentFact]
        precondition(NearbyGroupOwnership.retainsAnchor(ownerFact, disconnecting: "A", members: members), "ordinary disconnect must preserve a shared owner")
        let revoked = NearbyGroupOwnership.revokedSessions(deviceID: "A", members: members)
        precondition(revoked == [dependentToken, ownerToken], "revocation must retire only dependent B then owner A")
        var oldLifetime = NearbyLinkLifetime(); precondition(oldLifetime.markVerified())
        if revoked.contains(ownerToken) { oldLifetime.retire() }
        precondition(!oldLifetime.markVerified(), "a late ACK cannot restart a revoked lifetime")
        precondition(!revoked.contains(independentToken))
        precondition(NearbyGroupOwnership.revokedSessions(deviceID: "B", members: members) == [dependentToken], "revoking a consumer must not revoke its still-requested owner")
        let probing = NearbyGroupMember(generation: UUID(), deviceID: nil, target: "A", ownerDeviceID: nil, anchor: false)
        precondition(NearbyGroupOwnership.revokedSessions(deviceID: "A", members: [probing]) == [probing.generation])
        var revocationGate = NearbyGroupAdmission()
        precondition(revocationGate.request(ownerToken, sharedGroup: false, cleanupPending: false) == .create)
        precondition(revocationGate.request(dependentToken, sharedGroup: false, cleanupPending: false) == .wait)
        for token in revoked { revocationGate.retiring(token) }
        revocationGate.verified(ownerToken)
        precondition(revocationGate.queued.isEmpty && revocationGate.creator == ownerToken)
        revocationGate.settled(ownerToken)
        precondition(revocationGate.request(independentToken, sharedGroup: false, cleanupPending: false) == .create)
        revocationGate.verified(ownerToken)
        precondition(revocationGate.creator == independentToken, "late revoked ACK cannot release the independent successor")
        precondition(NearbyGroupOwnership.trusted(identity: Data([1]), pin: Data([2]), currentIdentity: Data([1]), currentPin: Data([2])))
        precondition(!NearbyGroupOwnership.trusted(identity: Data([1]), pin: Data([2]), currentIdentity: nil, currentPin: nil))
        precondition(!NearbyGroupOwnership.trusted(identity: Data([1]), pin: Data([2]), currentIdentity: Data([3]), currentPin: Data([2])))
        precondition(!NearbyGroupOwnership.trusted(identity: Data([1]), pin: Data([2]), currentIdentity: Data([1]), currentPin: Data([3])))
        // Explicit and automatic paths both reach this same admission state;
        // probe/authentication order may differ from the UI request order.
        for explicitFirst in [true, false] {
            var gate = NearbyGroupAdmission()
            let explicit = UUID(), automatic = UUID()
            let first = explicitFirst ? explicit : automatic
            let second = explicitFirst ? automatic : explicit
            precondition(gate.request(first, sharedGroup: false, cleanupPending: false) == .create)
            precondition(gate.request(second, sharedGroup: false, cleanupPending: false) == .wait,
                "a simultaneous second connection must not create a second owner group")
            precondition(gate.request(second, sharedGroup: false, cleanupPending: false) == .wait)
            precondition(gate.queued == [second])
            gate.verified(first)
            precondition(gate.request(second, sharedGroup: true, cleanupPending: false) == .join)
            precondition(gate.queued.isEmpty)
        }
        var failed = NearbyGroupAdmission()
        var fivePhones = NearbyGroupAdmission()
        let five = (0..<5).map { _ in UUID() }
        precondition(fivePhones.request(five[0], sharedGroup: false, cleanupPending: false) == .create)
        for phone in five.dropFirst() { precondition(fivePhones.request(phone, sharedGroup: false, cleanupPending: false) == .wait) }
        precondition(fivePhones.queued.count == 4, "five phones need one creator and four bounded waiting leases")
        _ = fivePhones.request(UUID(), sharedGroup: false, cleanupPending: false)
        precondition(fivePhones.queued.count == 4, "a sixth request cannot grow the queue")
        fivePhones.verified(five[0])
        for phone in five.dropFirst() { precondition(fivePhones.request(phone, sharedGroup: true, cleanupPending: false) == .join) }
        precondition(fivePhones.queued.isEmpty)
        var cleanupWaiting = NearbyGroupAdmission()
        let retiredCreator = UUID()
        precondition(cleanupWaiting.request(retiredCreator, sharedGroup: false, cleanupPending: false) == .create)
        cleanupWaiting.retiring(retiredCreator)
        for phone in five { precondition(cleanupWaiting.request(phone, sharedGroup: false, cleanupPending: true) == .wait) }
        precondition(cleanupWaiting.queued == five, "all five live sessions must remain queued behind a retired creator's cleanup fence")
        _ = cleanupWaiting.request(UUID(), sharedGroup: false, cleanupPending: true)
        precondition(cleanupWaiting.queued.count == 5)
        cleanupWaiting.settled(retiredCreator)
        precondition(cleanupWaiting.request(five[0], sharedGroup: false, cleanupPending: false) == .create)
        cleanupWaiting.verified(five[0])
        for phone in five.dropFirst() { precondition(cleanupWaiting.request(phone, sharedGroup: true, cleanupPending: false) == .join) }
        precondition(cleanupWaiting.queued.isEmpty)
        let old = UUID(), queued = UUID(), stale = UUID()
        precondition(failed.request(old, sharedGroup: false, cleanupPending: false) == .create)
        precondition(failed.request(queued, sharedGroup: false, cleanupPending: false) == .wait)
        failed.retiring(old); failed.verified(old)
        precondition(failed.request(queued, sharedGroup: false, cleanupPending: true) == .wait)
        failed.settled(stale)
        precondition(failed.creator == old, "stale retirement cannot release the current creator")
        failed.settled(old)
        precondition(failed.request(queued, sharedGroup: false, cleanupPending: false) == .create)
        failed.verified(old); failed.settled(old)
        precondition(failed.creator == queued, "late old verification/settlement cannot release its successor")
        failed.retiring(queued); failed.settled(queued)
        precondition(failed.queued.isEmpty)
        var canceled = NearbyGroupAdmission()
        let owner = UUID(), abandoned = UUID(), replacement = UUID()
        precondition(canceled.request(owner, sharedGroup: false, cleanupPending: false) == .create)
        precondition(canceled.request(abandoned, sharedGroup: false, cleanupPending: false) == .wait)
        canceled.retiring(abandoned); canceled.verified(owner)
        precondition(canceled.queued.isEmpty, "a canceled waiting session cannot be drained later")
        precondition(canceled.request(replacement, sharedGroup: true, cleanupPending: true) == .wait)
        precondition(canceled.request(replacement, sharedGroup: true, cleanupPending: false) == .join)
        let now = ContinuousClock.now
        var remoteExpiry: ContinuousClock.Instant? = NearbyRemoteLeaseDeadline.delivered(at: now, previous: nil)
        remoteExpiry = NearbyRemoteLeaseDeadline.delivered(at: now + .seconds(7), previous: remoteExpiry)
        precondition(remoteExpiry! >= now + .seconds(52), "ACK received at7s proves a remote lease may remain until52s; old50s deadline is unsafe")
        let safeRetirement = NearbyRemoteLeaseDeadline.retiring(at: now + .seconds(8), previous: remoteExpiry)
        precondition(safeRetirement >= now + .seconds(68), "retirement covers45s TTL,8s outstanding delivery,2s close and5s margin")
        let delayed = NearbyGroupRetirementState(wifiSettled: true, remoteSafeAfter: safeRetirement)
        precondition(!delayed.settled(at: now + .seconds(50), taskRunning: false, bluetoothRetiring: false))
        precondition(!delayed.settled(at: now + .seconds(52), taskRunning: false, bluetoothRetiring: false))
        let laterOutcome = NearbyRemoteLeaseDeadline.delivered(at: now + .seconds(30), previous: remoteExpiry)
        precondition(laterOutcome >= now + .seconds(80), "a timed-out renewal may have reached the phone before its outcome")
        precondition(NearbyRemoteLeaseDeadline.delivered(at: now, previous: laterOutcome) == laterOutcome, "stale outcomes cannot shorten expiry")
        precondition(NearbyRemoteLeaseDeadline.retiring(at: now, previous: nil) == now, "a session that sent no group request needs no remote expiry fence")
        var retirement = NearbyGroupRetirementState(wifiSettled: false, remoteSafeAfter: now + .seconds(50))
        precondition(!retirement.settled(at: now + .seconds(60), taskRunning: false, bluetoothRetiring: false))
        retirement.wifiSettled = true
        precondition(!retirement.settled(at: now + .seconds(49), taskRunning: false, bluetoothRetiring: false))
        precondition(!retirement.settled(at: now + .seconds(50), taskRunning: true, bluetoothRetiring: false))
        precondition(!retirement.settled(at: now + .seconds(50), taskRunning: false, bluetoothRetiring: true))
        precondition(retirement.settled(at: now + .seconds(50), taskRunning: false, bluetoothRetiring: false))
        retirement.remoteSafeAfter = now // exact STOP acknowledgement
        precondition(retirement.settled(at: now, taskRunning: false, bluetoothRetiring: false))
        print("PASS Nearby revocation dependencies/trust fences, shared creation serialization, explicit/automatic ordering and physical cleanup/expiry barriers")
    }
}
