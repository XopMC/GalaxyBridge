import Foundation
import GalaxyBridgeCore

final class RecoveryADBState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLaunches = 0
    private var processes: [Process] = []
    var launches: Int { lock.lock(); defer { lock.unlock() }; return storedLaunches }
    func launch(input: Pipe?, output: Pipe?) throws -> Process {
        lock.lock(); storedLaunches += 1; let attempt = storedLaunches; lock.unlock()
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["python3", "-u", "-c", #"""
import json,os,sys
if ATTEMPT==1:
 print(json.dumps(dict(version=1,pid=os.getpid(),startTime="1",initial=[],current=[],ok=False,error="panel_inventory_unavailable")),flush=True)
 sys.exit(1)
initial=[{"id":"17","on":False},{"id":"22","on":True}]
current=[dict(p) for p in initial]
def ack(): print(json.dumps(dict(version=1,pid=os.getpid(),startTime="1",initial=initial,current=current,ok=True,error="")),flush=True)
ack()
while True:
 b=sys.stdin.buffer.read(1)
 if not b: break
 if b==bytes([0]): current=[dict(id=p["id"],on=False) for p in initial]
 elif b==bytes([1]): current=[dict(p) for p in initial]
 elif b==bytes([2]):
  current=[dict(p) for p in initial]
  ack()
  break
 ack()
"""#.replacingOccurrences(of: "ATTEMPT", with: String(attempt))]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run(); lock.lock(); processes.append(child); lock.unlock(); return child
    }
    func run(_ arguments: [String]) -> String {
        lock.lock(); let all = processes; lock.unlock()
        let request = arguments.joined(separator: " ")
        guard let process = all.first(where: { request.contains("/proc/\($0.processIdentifier)/stat") }), process.isRunning else { return "GONE\n" }
        return "\(process.processIdentifier) (app_process) S " + Array(repeating: "0", count: 18).joined(separator: " ") + " 1\n"
    }
}
struct ADBClient: Sendable {
    let state: RecoveryADBState
    func push(serial: String, localURL: URL, remotePath: String) throws {}
    func run(arguments: [String], timeout: TimeInterval) throws -> String { state.run(arguments) }
    func launch(serial: String, arguments: [String], inputPipe: Pipe?, outputPipe: Pipe?) throws -> Process { try state.launch(input: inputPipe, output: outputPipe) }
}
enum ScrcpyServerLocator { static func locate() throws -> URL { URL(fileURLWithPath: "/synthetic-pinned-producer.jar") } }
@MainActor final class ShellCapabilityBridgeLease {}
@MainActor final class ShellCapabilityBridgeProvider {
    func beginPanelOwnership() async throws -> ShellCapabilityBridgeLease { .init() }
    func panelPower() async throws -> PhonePanelPowerState { .off }
    func setPanelPower(on: Bool, lease: ShellCapabilityBridgeLease?) async throws -> ShellCapabilityBridgeLease { .init() }
    func retire(_ lease: ShellCapabilityBridgeLease) async throws {}
}
@main enum DisplayPowerOwnerRecoverySpec {
    @MainActor static func main() async throws {
        let state = RecoveryADBState(), adb = ADBClient(state: state)
        let coordinator = PhoneDisplayPrivacyCoordinator { serial in ScrcpyDisplayPowerSession(serial: serial, adb: adb) }
        let lease = UUID()
        coordinator.acquireLease(deviceID: "phone", leaseID: lease)
        coordinator.setEnabled(true, deviceID: "phone", serial: "synthetic")
        await coordinator.waitForSettlement(deviceID: "phone")
        if case .failed = coordinator.status(deviceID: "phone") {} else { preconditionFailure("Startup failure must remain a failed privacy attempt") }
        coordinator.setEnabled(true, deviceID: "phone", serial: "synthetic")
        await coordinator.waitForSettlement(deviceID: "phone")
        precondition(state.launches == 2 && coordinator.status(deviceID: "phone") == .hidden,
            "A harmless startup failure permanently quarantined the phone's next privacy attempt")
        coordinator.releaseLease(deviceID: "phone", leaseID: lease)
        await coordinator.waitForSettlement(deviceID: "phone")
        precondition(coordinator.status(deviceID: "phone") == .waitingForSession, "Recovered owner did not restore and retire")
        print("PASS actual snapshot owner startup failure exit1 without mutation, explicit retry, mixed-panel hide and final retirement")
    }
}
