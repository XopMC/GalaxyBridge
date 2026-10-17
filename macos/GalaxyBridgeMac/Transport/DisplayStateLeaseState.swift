#if !GALAXYBRIDGE_APP_STORE
import Foundation

/// One immutable child owner. Draining is irreversible, including when a
/// delayed startup/policy reply arrives after cancellation.
struct DisplayStateLeaseState: Sendable {
    private(set) var header: DisplayStateControllerAcknowledgement?
    private(set) var draining = false
    private(set) var retired = false
    private(set) var lastConfirmedRevision: UInt64 = 0
    private(set) var lastAttemptedRevision: UInt64 = 0
    private(set) var pendingRevision: UInt64?
    var mayHaveMutated: Bool { lastAttemptedRevision != 0 }

    mutating func acceptSnapshot(_ reply: DisplayStateControllerAcknowledgement) throws {
        guard !retired, header == nil, !mayHaveMutated,
              reply.event == .ready, reply.state == .snapshotted, reply.revision == 0,
              reply.ok, !reply.draining, reply.mutationSettled,
              let initial = reply.initial, reply.current == initial else {
            throw DisplayStateProtocolError.unexpectedReply
        }
        header = reply
    }
    mutating func beginPolicy() throws -> UInt64 {
        guard header != nil, !draining, !retired, pendingRevision == nil,
              lastAttemptedRevision < UInt64(Int64.max) else { throw DisplayStateProtocolError.unexpectedReply }
        lastAttemptedRevision += 1
        pendingRevision = lastAttemptedRevision
        return lastAttemptedRevision
    }
    mutating func acceptPolicy(_ reply: DisplayStateControllerAcknowledgement,
                               revision: UInt64, policy: DisplayStateControllerAcknowledgement.PanelPolicy) throws {
        guard !retired, let header, let initial = header.initial,
              pendingRevision == revision else { throw DisplayStateProtocolError.unexpectedReply }
        _ = try reply.validatingPolicyReply(identity: header.identity, initial: initial,
                                            revision: revision, requiresInteractive: true, policy: policy)
        lastConfirmedRevision = revision
        pendingRevision = nil
    }
    mutating func beginDraining() { draining = true }
    mutating func confirmNotStarted() throws {
        guard draining, !retired, header == nil, !mayHaveMutated else { throw DisplayStateProtocolError.unexpectedReply }
        retired = true
    }
    mutating func confirmRetirement(_ evidence: DisplayStateRetirementEvidence) throws -> DisplayStateRetirementEvidence.Disposition {
        guard draining, !retired else { throw DisplayStateProtocolError.unexpectedReply }
        let disposition: DisplayStateRetirementEvidence.Disposition
        if let header, let initial = header.initial {
            disposition = try evidence.validating(identity: header.identity, initial: initial,
                lastConfirmedRevision: lastConfirmedRevision, lastAttemptedRevision: lastAttemptedRevision)
        } else {
            disposition = try evidence.validatingProvisional(mayHaveMutated: mayHaveMutated)
        }
        retired = true
        pendingRevision = nil
        return disposition
    }
}
#endif
