import Foundation
import OSLog

struct GBShellBridgeResult {
    var available = true
    var errorCode = ""
    var state = "stopped"
    var streamIds: [String] = []
}
struct TestContext { var sessionID: String }
struct TestControl { var authenticatedSessionID: String }
struct GBShellBridgeRequest { enum Operation { case stop, status } }
@MainActor final class ShellCapabilityBridgeLease {
    let id = "181892ff-7429-4d94-95b6-f425e01f4b06"
    let generation = "db8a61a9-4a81-4e6d-aeca-53bd446ae776"
    let diagnosticID: UInt64 = 1
    let context = TestContext(sessionID: "initial-session")
    var localCancelled = false
    func cancelLocal() { localCancelled = true }
}
@MainActor class StopFixture {
    let cleanupLogger = Logger(subsystem: "com.xopmc.GalaxyBridge.fixture", category: "ShellStopDiagnostic")
    var leases: [String: ShellCapabilityBridgeLease] = [:]
    var current = "initial-session"
    var replies: [Result<GBShellBridgeResult, Error>] = []
    var operations: [String] = []
    func control() -> TestControl? { TestControl(authenticatedSessionID: current) }
    func context() throws -> TestContext { TestContext(sessionID: current) }
    func perform(operation: GBShellBridgeRequest.Operation, lease: String, generation: String,
                 context: TestContext) async throws -> GBShellBridgeResult {
        operations.append(operation == .stop ? "stop" : "status")
        precondition(!replies.isEmpty)
        return try replies.removeFirst().get()
    }
    func retire(_ lease: ShellCapabilityBridgeLease) async throws { fatalError("Override actual source body") }
}
// ACTUAL_STOP_PROVIDER

@main struct RetirementBehaviourSpec {
    @MainActor static func run(_ fixture: StopFixture, scenario: Int) async -> String {
        let lease = ShellCapabilityBridgeLease(); fixture.leases[lease.id] = lease
        switch scenario {
        case 0: fixture.replies = [.success(GBShellBridgeResult())]
        case 1: fixture.replies = [.failure(ShellCapabilityBridgeFailure.timeout), .success(GBShellBridgeResult())]
        case 2: fixture.replies = [.success(GBShellBridgeResult(available: false)), .success(GBShellBridgeResult(state: "ready"))]
        case 3: fixture.current = "replacement-session"; fixture.replies = [.success(GBShellBridgeResult())]
        case 4: fixture.current = "replacement-session"; fixture.replies = [.success(GBShellBridgeResult(state: "ready"))]
        case 5: fixture.replies = [.failure(NSError(domain: "untrusted-secret-domain", code: 77)), .failure(ShellCapabilityBridgeFailure.timeout)]
        default: fatalError()
        }
        var outcome = "stopped"
        do { try await fixture.retire(lease) } catch { outcome = "fenced" }
        precondition(lease.localCancelled)
        let retained = fixture.leases[lease.id] != nil
        precondition(retained == [2,4,5].contains(scenario))
        precondition(outcome == ([2,4,5].contains(scenario) ? "fenced" : "stopped"))
        return "\(outcome):\(retained):\(fixture.operations.joined(separator: ","))"
    }
    @MainActor static func main() async {
        for scenario in 0...5 {
            let actual = await run(ActualStopProvider(), scenario: scenario)
            let expected = ["stopped:false:stop", "stopped:false:stop,status", "fenced:true:stop,status",
                            "stopped:false:status", "fenced:true:status", "fenced:true:stop,status"][scenario]
            precondition(actual == expected, "Incorrect STOP/status ownership flow")
        }
        print("PASS six actual retirement paths unchanged: STOP, fallback proof, old session and unconfirmed retention")
    }
}
