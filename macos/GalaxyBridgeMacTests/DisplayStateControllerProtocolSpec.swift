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
