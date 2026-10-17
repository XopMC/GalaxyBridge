import Foundation
import GalaxyBridgeCore

final class RecoveryADBState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLaunches = 0
    private var shellUnavailable = false
    let firstAttemptSucceeds: Bool
    let transportExit: Int
    init(firstAttemptSucceeds: Bool = false, transportExit: Int = 0) {
        self.firstAttemptSucceeds = firstAttemptSucceeds; self.transportExit = transportExit
    }
    func disconnectShell() { lock.withLock { shellUnavailable = true } }
    var runningChildren: Int { lock.withLock { processes.filter(\.isRunning).count } }
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
sys.exit(TRANSPORT_EXIT)
"""#.replacingOccurrences(of: "ATTEMPT", with: String(firstAttemptSucceeds ? attempt + 1 : attempt)).replacingOccurrences(of: "TRANSPORT_EXIT", with: String(transportExit))]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run(); lock.lock(); processes.append(child); lock.unlock(); return child
    }
    func run(_ arguments: [String]) throws -> String {
        lock.lock(); let all = processes; let unavailable = shellUnavailable; lock.unlock()
        if unavailable { throw NSError(domain: "synthetic USB detached", code: 1) }
        let request = arguments.joined(separator: " ")
        guard let process = all.first(where: { request.contains("/proc/\($0.processIdentifier)/stat") }), process.isRunning else { return "GONE\n" }
        return "\(process.processIdentifier) (app_process) S " + Array(repeating: "0", count: 18).joined(separator: " ") + " 1\n"
    }
}
struct ADBClient: Sendable {
    let state: RecoveryADBState
    func push(serial: String, localURL: URL, remotePath: String) throws {}
    func run(arguments: [String], timeout: TimeInterval) throws -> String { try state.run(arguments) }
    func launch(serial: String, arguments: [String], inputPipe: Pipe?, outputPipe: Pipe?) throws -> Process { try state.launch(input: inputPipe, output: outputPipe) }
}
enum ScrcpyServerLocator { static func locate() throws -> URL { URL(fileURLWithPath: "/synthetic-pinned-producer.jar") } }
@MainActor final class ShellCapabilityBridgeLease {}
@MainActor final class ShellCapabilityBridgeProvider {
    var begins = 0
    func beginPanelOwnership() async throws -> ShellCapabilityBridgeLease { begins += 1; return .init() }
    func panelPower() async throws -> PhonePanelPowerState { .off }
    func setPanelPower(on: Bool, lease: ShellCapabilityBridgeLease?) async throws -> ShellCapabilityBridgeLease { .init() }
    func retire(_ lease: ShellCapabilityBridgeLease) async throws {}
}
@MainActor final class RetirementProofState { var permit = false; var accepted = 0; var resources = 0 }
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
        let detached = RecoveryADBState(firstAttemptSucceeds: true, transportExit: 37)
        let next = ShellCapabilityBridgeProvider()
        let proofState = RetirementProofState()
        let migrating = ScrcpyDisplayPowerSession(serial: "captured-usb", adb: ADBClient(state: detached),
            shellProviderResolver: { $0 == "shell:phone" ? next : nil },
            retirementProof: { identity, initial in
                guard proofState.permit else { throw NSError(domain: "unconfirmed same-phone proof", code: 1) }
                let expected = try PhonePanelPowerSnapshot(validating: [.init(id: "17", on: false), .init(id: "22", on: true)])
                precondition(identity.pid > 1 && identity.startTime == "1" && initial == expected)
                proofState.accepted += 1
            }, resourceRelease: { identity, resource in
                precondition(identity.pid > 1 && UUID(uuidString: resource)?.uuidString.lowercased() == resource)
                proofState.resources += 1
            })
        try await migrating.start(); try await migrating.setPanelPower(on: false)
        detached.disconnectShell()
        var rejected = false
        do { _ = try await migrating.useRoute(serial: "shell:phone") } catch { rejected = true }
        precondition(rejected && next.begins == 0 && proofState.accepted == 0 && proofState.resources == 0,
            "unconfirmed restoration admitted a new panel owner")
        proofState.permit = true
        let rebased = try await migrating.useRoute(serial: "shell:phone")
        if case .rebased = rebased {} else { preconditionFailure("confirmed controller did not rebase") }
        precondition(proofState.accepted == 1 && proofState.resources == 1 && detached.runningChildren == 0,
            "independent PID/start+mixed-state proof must reap the local transport and release only its exact runtime")
        try await migrating.start(); try await migrating.stop()
        precondition(next.begins == 1, "the prepared Helper must become the next owner after confirmed retirement")
        let roundTripState = RecoveryADBState(firstAttemptSucceeds: true, transportExit: 37)
        let roundTripProof = RetirementProofState()
        let initialShell = ShellCapabilityBridgeProvider()
        let roundTrip = ScrcpyDisplayPowerSession(serial: "shell:phone", adb: ADBClient(state: roundTripState),
            shellProvider: initialShell, shellProviderResolver: { $0 == "shell:phone" ? initialShell : nil },
            retirementProofResolver: { serial in
                precondition(serial == "verified-usb", "controller proof must freeze the current raw launch route")
                return { _, _ in roundTripProof.accepted += 1 }
            }, resourceReleaseResolver: { serial in
                precondition(serial == "verified-usb")
                return { _, _ in roundTripProof.resources += 1 }
            })
        try await roundTrip.start()
        _ = try await roundTrip.useRoute(serial: "verified-usb")
        try await roundTrip.start(); try await roundTrip.setPanelPower(on: false)
        roundTripState.disconnectShell()
        _ = try await roundTrip.useRoute(serial: "shell:phone")
        try await roundTrip.start(); try await roundTrip.stop()
        precondition(initialShell.begins == 2 && roundTripProof.accepted == 1 && roundTripProof.resources == 1
            && roundTripState.runningChildren == 0, "Shell -> verified ADB -> Helper lost controller retirement authority")
        print("PASS actual power handoff: lost USB/nonzero transport exit, rejected proof fence, exact mixed-state proof, local reap and scoped resource cleanup")

    }
}
