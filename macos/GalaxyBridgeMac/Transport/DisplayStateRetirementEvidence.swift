#if !GALAXYBRIDGE_APP_STORE
import Foundation

/// Composite evidence is never interchangeable with a legacy Boolean-panel proof.
struct DisplayStateRetirementEvidence: Sendable {
    enum Disposition: Equatable, Sendable { case restored, yieldedActivity, yieldedExternal, neverMutated }
    var kind: Int
    var scid: UInt32 = 0
    var identity: DisplayStateControllerIdentity
    var supported: Bool
    var absent: Bool
    var legacyPanelCount = 0
    var ownedResourceID = ""
    var resourceRemoved = false
    var snapshotData = Data()
    var terminalAcknowledgement = Data()

    func validating(identity expected: DisplayStateControllerIdentity, initial: DisplayStateSnapshot,
                    lastConfirmedRevision: UInt64, lastAttemptedRevision: UInt64) throws -> Disposition {
        try validateEnvelope()
        guard identity == expected, lastConfirmedRevision <= lastAttemptedRevision,
              lastAttemptedRevision <= UInt64(Int64.max) else { throw DisplayStateProtocolError.unexpectedReply }
        let observed = try decodedSnapshot()
        if !terminalAcknowledgement.isEmpty {
            let terminal = try DisplayStateControllerAcknowledgement.decode(terminalAcknowledgement)
                .validatingTerminal(identity: expected, initial: initial,
                    lastConfirmedRevision: lastConfirmedRevision, lastAttemptedRevision: lastAttemptedRevision)
            switch terminal.state {
            case .restored: return .restored
            case .yieldedActivity: return .yieldedActivity
            case .yieldedExternal: return .yieldedExternal
            default: throw DisplayStateProtocolError.unexpectedReply
            }
        }
        guard let observed, observed.hasSameOwnedState(as: initial) else { throw DisplayStateProtocolError.unexpectedReply }
        return .restored
    }
    /// A lost read-only startup header cannot authorize any policy. Once the
    /// exact typed STOP has proven absence, cleanup need not invent a baseline.
    func validatingProvisional(mayHaveMutated: Bool) throws -> Disposition {
        guard !mayHaveMutated else { throw DisplayStateProtocolError.unexpectedReply }
        try validateEnvelope()
        _ = try decodedSnapshot()
        if !terminalAcknowledgement.isEmpty {
            let terminal = try DisplayStateControllerAcknowledgement.decode(terminalAcknowledgement)
            guard let initial = terminal.initial else { throw DisplayStateProtocolError.unexpectedReply }
            _ = try terminal.validatingTerminal(identity: identity, initial: initial,
                lastConfirmedRevision: 0, lastAttemptedRevision: 0)
        }
        return .neverMutated
    }
    private func validateEnvelope() throws {
        guard kind == 3, scid == 0, supported, absent, legacyPanelCount == 0, ownedResourceID.isEmpty, !resourceRemoved,
              identity.pid > 1, identity.startTicks > 0, identity.startTicks <= UInt64(Int64.max),
              snapshotData.count <= 8192, terminalAcknowledgement.count <= 8192,
              !snapshotData.isEmpty || !terminalAcknowledgement.isEmpty else {
            throw DisplayStateProtocolError.unexpectedReply
        }
    }
    private func decodedSnapshot() throws -> DisplayStateSnapshot? {
        guard !snapshotData.isEmpty else { return nil }
        return try JSONDecoder().decode(DisplayStateSnapshot.self, from: snapshotData)
    }
}
#endif
