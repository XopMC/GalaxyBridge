import Foundation

@main
enum DisplayStateControllerProtocolSpec {
    enum Failure: Error { case expectation(String) }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.expectation(message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        var rejected = false
        do { try action() } catch { rejected = true }
        try require(rejected, message)
    }
    static func changed(_ source: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var value = try JSONSerialization.jsonObject(with: source) as! [String: Any]
        edit(&value)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    static func snapshotChanged(_ source: Data, name: String = "current", _ edit: (inout [String: Any]) -> Void) throws -> Data {
        try changed(source) { value in
            var snapshot = value[name] as! [String: Any]
            edit(&snapshot)
            value[name] = snapshot
        }
    }
    static func main() {
        do { try run() }
        catch { print("FAIL composite display wire: \(error)"); exit(1) }
    }
    static func run() throws {
        let wire = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let frames = String(decoding: wire, as: UTF8.self).split(separator: "\n").map { Data($0.utf8) }
        try require(frames.count == 6, "The real native controller must emit its full policy lifecycle")
        let decoded = try frames.map(DisplayStateControllerAcknowledgement.decode)
        let startup = decoded[0], first = decoded[1], terminal = decoded[5]
        let initial = startup.initial!
        var localOnly = DisplayStateLeaseState()
        localOnly.beginDraining(); try localOnly.confirmNeverDispatched()
        try require(localOnly.retired && !localOnly.confirmedNotStarted,
                    "A never-dispatched local reservation has no remote child, but is not typed remote no-start evidence")
        var queued = DisplayStateLeaseState()
        queued.markSnapshotDispatched(); queued.beginDraining()
        try rejects("A queued SNAPSHOT remains uncertain after timeout; no header does not prove no child") {
            try queued.confirmNeverDispatched()
        }
        var leaseState = DisplayStateLeaseState()
        try rejects("No APPLY can precede the immutable startup snapshot") { _ = try leaseState.beginPolicy() }
        try leaseState.acceptSnapshot(startup)
        let revision = try leaseState.beginPolicy()
        try require(revision == 1 && leaseState.mayHaveMutated && leaseState.lastConfirmedRevision == 0,
                    "Possible mutation must be recorded before the first policy leaves the host")
        try rejects("Concurrent policy writes cannot share or reorder a revision") { _ = try leaseState.beginPolicy() }
        try leaseState.acceptPolicy(first, revision: revision, policy: .hide)
        try require(leaseState.lastConfirmedRevision == 1, "Only the correlated READY advances confirmed policy")
        try leaseState.validateStatus(decoded[2])
        try require(leaseState.lastAttemptedRevision == 1 && leaseState.lastConfirmedRevision == 1,
                    "Native poll renews without allocating or advancing a policy revision")
        try rejects("An unrelated revision cannot renew a different policy") { try leaseState.validateStatus(decoded[3]) }
        try rejects("A repeated startup may not rebase an existing owner") { try leaseState.acceptSnapshot(startup) }
        let secondRevision = try leaseState.beginPolicy()
        leaseState.beginDraining()
        try leaseState.acceptPolicy(decoded[3], revision: secondRevision, policy: .preserve)
        try require(leaseState.draining && leaseState.lastConfirmedRevision == 2,
                    "A late policy reply can retain evidence but cannot reopen draining admission")
        try rejects("Cancellation remains sticky after a late policy reply") { _ = try leaseState.beginPolicy() }
        var cancelledStartup = DisplayStateLeaseState()
        cancelledStartup.beginDraining()
        try cancelledStartup.acceptSnapshot(startup)
        try require(cancelledStartup.header?.initial == initial && cancelledStartup.draining,
                    "Late startup evidence is retained for cleanup after cancellation")
        try rejects("Late startup cannot authorize APPLY after cancellation") { _ = try cancelledStartup.beginPolicy() }
        var unknownStartup = DisplayStateLeaseState()
        unknownStartup.beginDraining()
        try unknownStartup.confirmNotStarted()
        try require(unknownStartup.retired && unknownStartup.confirmedNotStarted,
                    "Exact typed no-start cleanup settles a lost read-only startup with specific evidence")
        try rejects("A retired no-start lease must not accept a resurrected startup") { try unknownStartup.acceptSnapshot(startup) }
        try rejects("Typed no-start cannot erase a known native child") { try cancelledStartup.confirmNotStarted() }
        try rejects("Typed no-start cannot erase a possible policy") { try leaseState.confirmNotStarted() }
        var retirement = DisplayStateRetirementEvidence(kind: 3, identity: startup.identity, supported: true, absent: true)
        retirement.terminalAcknowledgement = frames[5]
        try rejects("A terminal revision beyond any attempted write cannot settle the owner") {
            _ = try leaseState.confirmRetirement(retirement)
        }
        var secondTerminal = retirement
        secondTerminal.terminalAcknowledgement = try changed(frames[5]) { $0["revision"] = 2 }
        try require(try leaseState.confirmRetirement(secondTerminal) == .restored && leaseState.retired,
                    "Draining cancellation settles only with the exact observed child and bounded terminal revision")
        try rejects("Retired state cannot accept another late policy") {
            try leaseState.acceptPolicy(decoded[3], revision: secondRevision, policy: .preserve)
        }
        var partial = DisplayStateLeaseState()
        try partial.acceptSnapshot(startup)
        _ = try partial.beginPolicy()
        partial.beginDraining()
        var partialTerminal = retirement
        partialTerminal.terminalAcknowledgement = try changed(frames[5]) { $0["revision"] = 0 }
        try require(try partial.confirmRetirement(partialTerminal) == .restored,
                    "A first APPLY lost before acknowledgement may retire at revision zero without losing its frozen baseline")
        try require(try retirement.validating(identity: startup.identity, initial: initial,
            lastConfirmedRevision: 3, lastAttemptedRevision: 3) == .restored,
            "Composite retirement must accept the actual settled native terminal plus exact absence")

        try require(startup.event == .ready && startup.state == .snapshotted && startup.revision == 0,
                    "Native startup captures evidence before any wake")
        _ = try first.validatingPolicyReply(identity: startup.identity, initial: initial, revision: 1,
                                           requiresInteractive: true, policy: .hide)
        _ = try decoded[2].validatingPolicyReply(identity: startup.identity, initial: initial, revision: 1,
                                                requiresInteractive: true, policy: .hide)
        _ = try decoded[3].validatingPolicyReply(identity: startup.identity, initial: initial, revision: 2,
                                                requiresInteractive: true, policy: .preserve)
        _ = try decoded[4].validatingPolicyReply(identity: startup.identity, initial: initial, revision: 3,
                                                requiresInteractive: true, policy: .hide)
        _ = try terminal.validatingTerminal(identity: startup.identity, initial: initial,
                                            lastConfirmedRevision: 3, lastAttemptedRevision: 3)
        try require(terminal.state == .restored && terminal.current!.hasSameOwnedState(as: initial),
                    "Real native terminal frame preserves exact owned raw/logical state")
        try require(terminal.current != initial, "Historical stamps really advance during a successful native restore")
        var independent = retirement
        independent.terminalAcknowledgement = Data()
        independent.snapshotData = try JSONEncoder().encode(terminal.current!)
        try require(try independent.validating(identity: startup.identity, initial: initial,
            lastConfirmedRevision: 3, lastAttemptedRevision: 3) == .restored,
            "Independent exact restoration compares owned raw/logical state, not historical timestamps")
        try require(try independent.validatingProvisional(mayHaveMutated: false) == .neverMutated,
            "Lost read-only header cleanup must not invent an initial snapshot")
        try rejects("Provisional absence cannot erase a possible policy write") { _ = try independent.validatingProvisional(mayHaveMutated: true) }
        try rejects("A terminal after real policies is not a read-only provisional receipt") { _ = try retirement.validatingProvisional(mayHaveMutated: false) }
        var missingAbsence = retirement; missingAbsence.absent = false
        var legacy = retirement; legacy.kind = 2
        var booleanProjection = retirement; booleanProjection.legacyPanelCount = 1
        var resourceOnly = retirement; resourceOnly.resourceRemoved = true
        var noPayload = retirement; noPayload.terminalAcknowledgement = Data()
        var wrongIdentity = retirement; wrongIdentity.identity = .init(pid: 124, startTicks: startup.identity.startTicks)
        var captureSCID = retirement; captureSCID.scid = 1
        for invalid in [missingAbsence, legacy, booleanProjection, resourceOnly, noPayload, wrongIdentity, captureSCID] {
            try rejects("Legacy, incomplete or wrong-owner evidence cannot retire a composite lease") {
                _ = try invalid.validating(identity: startup.identity, initial: initial, lastConfirmedRevision: 3, lastAttemptedRevision: 3)
            }
        }
        var malformedTerminal = independent; malformedTerminal.terminalAcknowledgement = Data("{}".utf8)
        try rejects("Malformed terminal must not silently fall back to a snapshot") {
            _ = try malformedTerminal.validating(identity: startup.identity, initial: initial, lastConfirmedRevision: 3, lastAttemptedRevision: 3)
        }
        var oversized = retirement; oversized.terminalAcknowledgement = Data(repeating: 32, count: 8193)
        try rejects("Oversized retirement evidence must remain fenced") {
            _ = try oversized.validating(identity: startup.identity, initial: initial, lastConfirmedRevision: 3, lastAttemptedRevision: 3)
        }
        var yielded = retirement
        yielded.terminalAcknowledgement = try snapshotChanged(changed(frames[5]) { $0["state"] = "YIELDED_ACTIVITY" }) {
            $0["defaultInteractive"] = true; $0["defaultWakefulness"] = "AWAKE"; $0["globalWakefulness"] = "AWAKE"
        }
        try require(try yielded.validating(identity: startup.identity, initial: initial, lastConfirmedRevision: 3,
            lastAttemptedRevision: 3) == .yieldedActivity, "A typed yielded disposition preserves subsequent user activity")
        print("PASS separate v2 retirement: exact child absence, raw/logical restoration, typed yields, provisional cleanup and no v1/resource-only shortcuts")

        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try require(try JSONDecoder().decode(DisplayStateSnapshot.self, from: encoder.encode(initial)) == initial,
                    "Retirement-query encoding preserves the entire initial snapshot")
        print("PASS actual native v2 lifecycle is accepted by the separate Swift decoder")

        try rejects("Startup ready must never admit capture") {
            _ = try startup.validatingPolicyReply(identity: startup.identity, initial: initial, revision: 1,
                                                  requiresInteractive: true, policy: .preserve)
        }
        for (field, value) in [("version", 1), ("revision", -1), ("pid", 1)] {
            try rejects("Invalid numeric field \(field) was accepted") {
                _ = try DisplayStateControllerAcknowledgement.decode(changed(frames[1]) { $0[field] = value })
            }
        }
        for text in ["", "00", "-1", "+1", "18446744073709551616"] {
            try rejects("Noncanonical process identity was accepted") {
                _ = try DisplayStateControllerAcknowledgement.decode(changed(frames[1]) { $0["startTime"] = text })
            }
        }
        try rejects("Truncated lifecycle fields were accepted") {
            _ = try DisplayStateControllerAcknowledgement.decode(changed(frames[1]) { $0.removeValue(forKey: "mutation_settled") })
        }
        try rejects("Oversized frames were accepted") { _ = try DisplayStateControllerAcknowledgement.decode(Data(repeating: 32, count: 8193)) }
        for field in ["panels", "activeID", "defaultWakefulness", "globalWakefulness", "transitionScope", "defaultActivityTime"] {
            try rejects("Missing snapshot field \(field) was accepted") {
                _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { $0.removeValue(forKey: field) })
            }
        }
        try rejects("Unknown snapshot fields must not silently disappear from the restoration baseline") {
            _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { $0["newUnownedGroup"] = true })
        }
        try rejects("A numeric Boolean was accepted") {
            _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { $0["defaultInteractive"] = 1 })
        }
        try rejects("Contradictory scoped interactivity was accepted") {
            _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { $0["defaultWakefulness"] = "DOZING" })
        }
        try rejects("Unknown active physical display was accepted") {
            _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { $0["activeID"] = "99" })
        }
        try rejects("Duplicate physical panels were accepted") {
            _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { value in
                let panels = value["panels"] as! [[String: Any]]; value["panels"] = [panels[0], panels[0]]
            })
        }
        try rejects("A collapsed Boolean panel mode was accepted") {
            _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { value in
                var panels = value["panels"] as! [[String: Any]]; panels[0]["mode"] = true; value["panels"] = panels
            })
        }
        for time in ["-1", "01", "9223372036854775808", "1.5"] {
            try rejects("An invalid Android timestamp was accepted") {
                _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { $0["defaultActivityTime"] = time })
            }
        }
        for field in ["draining", "mutation_settled"] {
            let malformed = try changed(frames[1]) { $0[field] = field == "draining" }
            let acknowledgement = try DisplayStateControllerAcknowledgement.decode(malformed)
            try rejects("Unsettled/draining policy reply admitted capture") {
                _ = try acknowledgement.validatingPolicyReply(identity: startup.identity, initial: initial, revision: 1,
                                                                requiresInteractive: true, policy: .hide)
            }
        }
        try rejects("A stale policy revision admitted capture") {
            _ = try first.validatingPolicyReply(identity: startup.identity, initial: initial, revision: 2,
                                                requiresInteractive: true, policy: .hide)
        }
        try rejects("A foreign child identity admitted capture") {
            _ = try first.validatingPolicyReply(identity: .init(pid: startup.identity.pid, startTicks: startup.identity.startTicks + 1),
                                                initial: initial, revision: 1, requiresInteractive: true, policy: .hide)
        }
        let differentInitial = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1], name: "initial") {
            $0["defaultActivityTime"] = "999"
        })
        try rejects("The initial ownership snapshot changed after an await") {
            _ = try differentInitial.validatingPolicyReply(identity: startup.identity, initial: initial, revision: 1,
                                                           requiresInteractive: true, policy: .hide)
        }
        let suspended = try DisplayStateControllerAcknowledgement.decode(changed(frames[1]) { $0["state"] = "SUSPENDED" })
        try rejects("An ok status in a suspended state admitted capture") {
            _ = try suspended.validatingPolicyReply(identity: startup.identity, initial: initial, revision: 1,
                                                    requiresInteractive: true, policy: .hide)
        }
        try rejects("An unobserved terminal revision retired a newer policy") {
            _ = try terminal.validatingTerminal(identity: startup.identity, initial: initial,
                                                lastConfirmedRevision: 1, lastAttemptedRevision: 2)
        }
        let firstObject = try JSONSerialization.jsonObject(with: frames[1]) as! [String: Any]
        for state in ["YIELDED_EXTERNAL", "YIELDED_ACTIVITY"] {
            let bytes = try changed(frames[5]) { value in value["state"] = state
                value["current"] = firstObject["current"]
            }
            let yielded = try DisplayStateControllerAcknowledgement.decode(bytes)
            _ = try yielded.validatingTerminal(identity: startup.identity, initial: initial,
                                               lastConfirmedRevision: 3, lastAttemptedRevision: 3)
            try require(!yielded.current!.hasSameOwnedState(as: initial), "Yielded disposition must retain differing state")
        }
        let startupFailureBytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let startupFailure = try DisplayStateControllerAcknowledgement.decode(startupFailureBytes)
        try require(startupFailure.event == .startupFailed && startupFailure.state == .notStarted && !startupFailure.ok,
                    "The real native startup failure is retained as a failure disposition")
        try require(startupFailure.initial == nil && startupFailure.current == nil && startupFailure.mutationSettled,
                    "Startup failure must not invent an ownership baseline")
        try rejects("A startup failure admitted a producer") {
            _ = try startupFailure.validatingPolicyReply(identity: startup.identity, initial: initial, revision: 1,
                                                         requiresInteractive: true, policy: .preserve)
        }
        let malformedStartup: [(String, Any)] = [("state", "READY"), ("draining", false), ("mutation_settled", false),
            ("initial", firstObject["initial"]!), ("current", firstObject["current"]!), ("revision", 1), ("reason", "command")]
        for (key, value) in malformedStartup {
            try rejects("Malformed startup failure field \(key) was accepted") {
                _ = try DisplayStateControllerAcknowledgement.decode(changed(startupFailureBytes) { $0[key] = value })
            }
        }
        try rejects("Unknown scoped wakefulness must not be inferred from global state") {
            _ = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[1]) { $0["defaultWakefulness"] = NSNull() })
        }
        for revision in [0, 1] {
            let recovered = try DisplayStateControllerAcknowledgement.decode(changed(frames[5]) { $0["revision"] = revision })
            _ = try recovered.validatingTerminal(identity: startup.identity, initial: initial,
                                                 lastConfirmedRevision: 0, lastAttemptedRevision: 1)
        }
        let oldTerminal = try DisplayStateControllerAcknowledgement.decode(changed(frames[5]) { $0["revision"] = 0 })
        try rejects("A terminal reply below the confirmed revision retired the owner") {
            _ = try oldTerminal.validatingTerminal(identity: startup.identity, initial: initial,
                                                   lastConfirmedRevision: 1, lastAttemptedRevision: 2)
        }
        let unrelatedActivity = try DisplayStateControllerAcknowledgement.decode(snapshotChanged(frames[5]) { value in
            value["globalWakefulness"] = "AWAKE"
            value["defaultActivityNoChangeLightsTime"] = String(UInt64(value["defaultActivityNoChangeLightsTime"] as! String)! + 1)
        })
        _ = try unrelatedActivity.validatingTerminal(identity: startup.identity, initial: initial,
                                                      lastConfirmedRevision: 3, lastAttemptedRevision: 3)
        print("PASS v2 admission, scoped raw state, identity/revision fences and conditional terminal dispositions")
        print("PASS actual native startup failure, unknown group rejection and partial first-policy retirement bounds")
    }
}
