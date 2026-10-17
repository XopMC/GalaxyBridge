import Foundation
@MainActor final class Control {
 var authenticatedSessionID: String; var supportsCompositeDisplayState = true
 init(_ session: String) { authenticatedSessionID = session }
}
struct Context { var sessionID: String; var control: Control }
enum ShellCapabilityBridgeFailure: Error { case operationFailed, sessionChanged, invalidResult, unavailable, timeout }
struct GBCaptureRetirementQuery {
 enum Kind: Int { case probeSupport, scrcpyCapture, displayPowerController, displayStateController }
 var kind = Kind.probeSupport; var scid: UInt32 = 0; var pid: UInt32 = 0; var processStartTicks: UInt64 = 0
}
struct GBCaptureRetirementProof {
 var kind = GBCaptureRetirementQuery.Kind.displayStateController; var scid: UInt32 = 0
 var pid: UInt32 = 123; var processStartTicks: UInt64 = 456; var supported = true; var absent = true
 var panels: [Bool] = []; var ownedResourceID = ""; var resourceRemoved = false
 var displayStateSnapshot = Data(); var displayStateTerminalAcknowledgement = Data()
}
struct GBDisplayStateCommand {
 enum Action { case snapshot, apply, status }; enum PanelPolicy: Int { case preserve, hide, show }
 var action = Action.snapshot; var interactive = false; var panelPolicy = PanelPolicy.preserve; var revision: UInt64 = 0
}
struct GBShellBridgeRequest { enum Operation: Equatable { case stop, status, verifyRetirement, startDisplayState } }
struct GBShellBridgeResult {
 var available = true; var errorCode = ""; var state = "display_state_retired"; var streamIds: [String] = []
 var bootGeneration = "boot-one"; var hasRetirementProof = true; var retirementProof = GBCaptureRetirementProof()
 var displayStateAcknowledgement = Data()
}
@MainActor final class ShellCapabilityBridgeLease {
 let id: String; let generation = "boot-one"; let context: Context
 var displayState: DisplayStateLeaseState? = .init()
 init(_ id: String, context: Context) { self.id = id; self.context = context }
}
@MainActor final class Provider {
 var currentControl = Control("old-session")
 var currentSession: String { get { currentControl.authenticatedSessionID } set { currentControl.authenticatedSessionID = newValue } }
 var bootGeneration: String? = "boot-one"
 var available = true; var currentRuntimeVerified = true
 var commands: [GBDisplayStateCommand] = []
 var onPerform: (() throws -> Void)?
 var leases: [String: ShellCapabilityBridgeLease] = [:]
 var result = GBShellBridgeResult(); var operations: [GBShellBridgeRequest.Operation] = []
 var queries: [GBCaptureRetirementQuery] = []
 func control() -> Control? { currentControl }
 func beginPanelOwnership() async throws -> ShellCapabilityBridgeLease {
  let lease = ShellCapabilityBridgeLease(UUID().uuidString.lowercased(), context: .init(sessionID: currentSession, control: currentControl))
  lease.displayState = nil; leases[lease.id] = lease; return lease
 }
 func perform(operation: GBShellBridgeRequest.Operation, lease: String, generation: String, context: Context, displayState: GBDisplayStateCommand? = nil) async throws -> GBShellBridgeResult {
  precondition((operation == .stop || operation == .startDisplayState) && generation == "boot-one" && context.sessionID == "old-session")
  operations.append(operation)
  if let displayState { commands.append(displayState) }
  try onPerform?()
  return result
 }
 func verifiedRetirementResult(_ query: GBCaptureRetirementQuery) async throws -> GBCaptureRetirementProof {
  operations.append(.verifyRetirement); queries.append(query)
  guard result.available && result.errorCode.isEmpty && result.hasRetirementProof else { throw ShellCapabilityBridgeFailure.operationFailed }
  return result.retirementProof
 }
 func notifyRuntimeUpgradeIfIdle() {}
 // ACTUAL_BEGIN_DISPLAY_STATE
 // ACTUAL_SNAPSHOT_DISPLAY_STATE
 // ACTUAL_APPLY_DISPLAY_STATE
 // ACTUAL_VALIDATE_DISPLAY_STATE
 // ACTUAL_POLL_DISPLAY_STATE
 // ACTUAL_RETIRE_DISPLAY_STATE
}
@main enum CompositeProviderSpec {
 static func require(_ value: Bool, _ text: String) throws { if !value { throw NSError(domain: text, code: 1) } }
 @MainActor static func owner(_ provider: Provider, header: DisplayStateControllerAcknowledgement?, policy: Bool = false) throws -> ShellCapabilityBridgeLease {
  let lease = ShellCapabilityBridgeLease(UUID().uuidString.lowercased(), context: .init(sessionID: provider.currentSession, control: provider.currentControl))
  if let header { try lease.displayState!.acceptSnapshot(header) }
  if policy { _ = try lease.displayState!.beginPolicy() }
  provider.leases[lease.id] = lease; return lease
 }
 @MainActor static func rejects(_ p: Provider, _ lease: ShellCapabilityBridgeLease) async throws {
  var rejected = false; do { try await p.retireDisplayState(lease) } catch { rejected = true }
  try require(rejected && p.leases[lease.id] === lease && lease.displayState!.draining,
              "Unconfirmed composite cleanup must retain exact ownership")
  try require(!p.operations.contains(.status), "Legacy status must never retire a composite owner")
 }
 @MainActor static func main() async {
  do {
   let frames = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
   let header = try DisplayStateControllerAcknowledgement.decode(frames[0])
   do {
    let p = Provider(); let lease = try await p.beginDisplayStateOwnership()
    try require(lease.displayState != nil && lease.displayState!.header == nil && p.operations.isEmpty,
                "Caller retains the exact cleanup handle before SNAPSHOT or any mutation")
    p.result.state = "display_state_snapshotted"; p.result.displayStateAcknowledgement = frames[0]
    try await p.snapshotDisplayState(lease)
    p.result.state = "display_state_reply"; p.result.displayStateAcknowledgement = frames[1]
    try await p.applyDisplayState(lease, policy: .preserve)
    try require(p.commands.count == 2 && p.commands[0].action == .snapshot && p.commands[0].revision == 0 && !p.commands[0].interactive &&
                p.commands[1].action == .apply && p.commands[1].interactive && p.commands[1].revision == 1 && p.commands[1].panelPolicy == .preserve &&
                lease.displayState!.lastConfirmedRevision == 1,
                "Actual provider sends typed read-only startup then exact interactive policy")
    p.result.displayStateAcknowledgement = frames[2]
    try await p.pollDisplayState(lease)
    try require(p.commands.count == 3 && p.commands[2].action == .status && p.commands[2].revision == 0 &&
                !p.commands[2].interactive && p.commands[2].panelPolicy == .preserve && lease.displayState!.lastConfirmedRevision == 1,
                "Typed STATUS renews the existing native owner without issuing another policy")
   }
   do {
    let p = Provider(); p.currentControl.supportsCompositeDisplayState = false
    var rejected = false; do { _ = try await p.beginDisplayStateOwnership() } catch { rejected = true }
    try require(rejected && p.leases.isEmpty && p.operations.isEmpty, "An older Helper cannot allocate a composite owner")
   }
   for replacement in [false, true] {
    let p = Provider(); let lease = try await p.beginDisplayStateOwnership()
    p.result.state = "display_state_snapshotted"; p.result.displayStateAcknowledgement = frames[0]
    p.onPerform = { if replacement { p.currentControl = Control("old-session") } else { lease.displayState!.beginDraining() } }
    var rejected = false; do { try await p.snapshotDisplayState(lease) } catch { rejected = true }
    try require(rejected && lease.displayState!.draining && lease.displayState!.header?.initial == header.initial && p.commands.count == 1,
                "Late startup retains baseline but cancellation/replaced control forbids admission")
   }
   do {
    let p = Provider(); let lease = try owner(p, header: header)
    p.result.state = "display_state_reply"; p.result.displayStateAcknowledgement = frames[1]
    p.onPerform = { lease.displayState!.beginDraining() }
    var rejected = false; do { try await p.applyDisplayState(lease, policy: .hide) } catch { rejected = true }
    try require(rejected && lease.displayState!.draining && lease.displayState!.lastConfirmedRevision == 1,
                "Late APPLY evidence cannot authorize a cancelled producer")
   }
   do {
    let p = Provider(); let lease = try owner(p, header: header)
    p.onPerform = { throw ShellCapabilityBridgeFailure.timeout }
    var rejected = false; do { try await p.applyDisplayState(lease, policy: .preserve) } catch { rejected = true }
    try require(rejected && lease.displayState!.draining && lease.displayState!.mayHaveMutated && lease.displayState!.lastConfirmedRevision == 0 && p.leases[lease.id] === lease,
                "Lost APPLY preserves uncertain mutation and exact cleanup ownership")
   }
   var terminal = try JSONSerialization.jsonObject(with: frames[5]) as! [String: Any]; terminal["revision"] = 0
   let data = try JSONSerialization.data(withJSONObject: terminal)
   do {
    let p = Provider(); let lease = try owner(p, header: header, policy: true)
    p.result.retirementProof.displayStateTerminalAcknowledgement = data
    try await p.retireDisplayState(lease)
    try require(p.leases.isEmpty && lease.displayState!.retired && p.operations == [.stop], "Typed STOP settles a possible first APPLY")
   }
   for state in ["stopped", "panel_on", ""] {
    let p = Provider(); let lease = try owner(p, header: header, policy: true)
    p.result.state = state; p.result.hasRetirementProof = false
    try await rejects(p, lease)
   }
   do {
    let p = Provider(); let lease = try owner(p, header: nil)
    p.result.state = "display_state_not_started"; p.result.hasRetirementProof = false
    try await p.retireDisplayState(lease)
    try require(p.leases.isEmpty && lease.displayState!.retired, "Lost read-only startup accepts only typed no-start cleanup")
   }
   do {
    let p = Provider(); let lease = try owner(p, header: header, policy: true)
    p.result.state = "display_state_not_started"; p.result.hasRetirementProof = false
    try await rejects(p, lease)
   }
   do {
    let p = Provider(); let lease = try owner(p, header: header, policy: true)
    p.currentSession = "replacement-session"; p.bootGeneration = "boot-two"
    p.result.retirementProof.displayStateTerminalAcknowledgement = data
    try await p.retireDisplayState(lease)
    try require(p.leases.isEmpty && p.operations == [.verifyRetirement] && p.queries[0].kind == .displayStateController && p.queries[0].pid == 123 && p.queries[0].processStartTicks == 456,
                "A replacement session has only exact read-only kind3 proof authority")
   }
   do {
    let p = Provider(); let lease = try owner(p, header: nil); p.currentSession = "replacement-session"
    try await rejects(p, lease)
    try require(p.operations.isEmpty, "A missing identity cannot invent cross-session ownership")
   }
   for change in 0..<4 {
    let p = Provider(); let lease = try owner(p, header: header, policy: true)
    p.result.retirementProof.displayStateTerminalAcknowledgement = data
    switch change { case 0: p.result.bootGeneration = "boot-two"; case 1: p.result.retirementProof.scid = 1
      case 2: p.result.streamIds = ["unexpected"]; default: p.result.retirementProof.kind = .displayPowerController }
    try await rejects(p, lease)
   }
   print("PASS actual composite provider retirement: lost ACK, typed no-start, exact proof, cross-session read-only recovery and no v1 fallback")
  } catch { print("FAIL composite provider retirement: \(error)"); exit(1) }
 }
}
