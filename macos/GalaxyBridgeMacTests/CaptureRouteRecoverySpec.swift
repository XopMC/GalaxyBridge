import Foundation

@MainActor final class ADBOwnedRuntime {
    static let shared = ADBOwnedRuntime()
    var activeGeneration: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
struct Peer: Sendable { let deviceID: String; var identityPublicKey: Data }
@MainActor struct PairedPeerStore {
    static var rows: [Peer] = []
    func peers() throws -> [Peer] { Self.rows }
}
struct DeviceRow { let id: String; var isReady = true; var adbSerial: String? }
@MainActor final class Events { var values: [String] = [] }
@MainActor final class Signal { func send() {} }
@MainActor final class Gate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
struct Control { var peer: Peer; var authenticatedSessionID: String; var supportsCaptureRetirementProof = true; var supportsFeatureConfiguration = true }
@MainActor final class Provider { var bootGeneration: String? = "prepared-boot"; var needsRuntimeUpgrade = false; var available = true }
@MainActor final class Session {
    let serial: String
    let capturedADBGeneration: UUID? = ADBOwnedRuntime.shared.activeGeneration
    var cleanupPhysicallySettled = false
    var canSettle = true
    init(_ serial: String) { self.serial = serial }
    func installVerifiedCleanupRoute(_ route: VerifiedEnhancedRetirementRoute) {}
    func retryOwnedCleanup() { if canSettle { cleanupPhysicallySettled = true } }
    func waitForScheduledCleanup() async { await Task.yield() }
}
struct Application { let packageName: String }
@MainActor final class ApplicationWindowCoordinator {
    struct RouteResume { let application: Application; let frame: Int }
    struct Suspension { let windows: [RouteResume]; let settled: Bool }
    @MainActor struct Record { let serial: String; let window: RouteResume; var generation: UUID? = ADBOwnedRuntime.shared.activeGeneration }
    var active: [String: [Record]] = [:]
    var retiring: [String: [Record]] = [:]
    var canSettle: [String: Bool] = [:]
    var gates: [String: Gate] = [:]
    var suspendCount: [String: Int] = [:]
    var resumed: [String: [RouteResume]] = [:]
    let events: Events
    init(_ events: Events) { self.events = events }
    func captureSerials(deviceID: String) -> Set<String> { Set(((active[deviceID] ?? []) + (retiring[deviceID] ?? [])).map(\.serial)) }
    func hasStaleADBGeneration(deviceID: String, currentGeneration: UUID) -> Bool {
        ((active[deviceID] ?? []) + (retiring[deviceID] ?? [])).contains {
            !$0.serial.hasPrefix("shell:") && $0.generation.map { $0 != currentGeneration } == true
        }
    }
    func hasRetiringOwners(deviceID: String) -> Bool { !(retiring[deviceID] ?? []).isEmpty }
    func installRetirementRoute(_ route: VerifiedEnhancedRetirementRoute, deviceID: String) {}
    func suspendForRouteChange(deviceID: String) async -> Suspension {
        suspendCount[deviceID, default: 0] += 1; events.values.append("apps-stop:" + deviceID)
        let old = active.removeValue(forKey: deviceID) ?? []
        retiring[deviceID, default: []] += old
        if let gate = gates.removeValue(forKey: deviceID) { await gate.wait() }
        let settled = await retryRetiringOwners(deviceID: deviceID)
        return .init(windows: old.map(\.window), settled: settled)
    }
    func retryRetiringOwners(deviceID: String) async -> Bool {
        if canSettle[deviceID] != false { retiring.removeValue(forKey: deviceID) }
        return !hasRetiringOwners(deviceID: deviceID)
    }
    func resumeAfterRouteChange(_ windows: [RouteResume], device: DeviceRow, model: AppModel, activate: Bool) {
        precondition(!activate && !model.captureRouteTransitionDevices.contains(device.id) && !model.preparingDirectDevices.contains(device.id))
        resumed[device.id, default: []] += windows
        active[device.id] = windows.map { .init(serial: model.destination(device.id)!, window: $0) }
        events.values.append("apps-resume:" + device.id)
    }
}
@MainActor final class Privacy {
    enum Status { case idle, failed(String) }
    var failures = Set<String>()
    let events: Events
    init(_ events: Events) { self.events = events }
    func setEnabled(_ enabled: Bool, deviceID: String, serial: String) { precondition(!enabled); events.values.append("power-drain:" + deviceID) }
    func waitForSettlement(deviceID: String) async { await Task.yield() }
    func status(deviceID: String) -> Status { failures.contains(deviceID) ? .failed("synthetic") : .idle }
}
@MainActor final class Clipboard { func stopAndWait() async {} }
@MainActor final class Setup {
    enum State { case acknowledged, pending }
    var waiting = Set<String>()
    func synchronization(deviceID: String) -> State { waiting.contains(deviceID) ? .pending : .acknowledged }
}
@MainActor final class Demand {
    var devices = Set<String>()
    func hasDemand(_ id: String) -> Bool { devices.contains(id) }
    func finishRetirement(_ permit: UUID) -> String? { nil }
}
enum ShellCapabilityBridgeFailure: Error { case operationFailed, unavailable }
@MainActor final class AppModel {
    struct Admission { var admitsWork = true }
    struct Preparation { let deviceID: String }
    var terminationAdmission = Admission()
    var devices: [DeviceRow] = []
    var selectedDeviceID: String?
    var lastError: String?
    let events = Events(), objectWillChange = Signal(), primaryScreenDemand = Demand(), clientSetup = Setup()
    lazy var applicationWindowCoordinator: ApplicationWindowCoordinator? = .init(events)
    lazy var phoneDisplayPrivacy = Privacy(events)
    var controls: [String: Control] = [:]
    var shellProviders: [String: Provider] = [:]
    var scrcpySessions: [String: Session] = [:]
    var enhancedRetirements: [UUID: Task<Void, Never>] = [:]
    var unsettledEnhancedRetirements: [UUID: Session] = [:]
    var enhancedRetirementDeviceIDs: [UUID: String] = [:]
    var nearbyPreparationTasks: [String: Task<Void, Never>] = [:]
    var preparingDirectDevices = Set<String>()
    var shellReadinessTasks: [String: Preparation] = [:]
    var phonePrivacyManualPower: [String: Bool] = [:]
    var clipboardSessions: [String: Clipboard] = [:]
    var clipboardReconnectTasks: [String: Task<Void, Never>] = [:]
    var clipboardReconnectAttempts: [String: Int] = [:]
    // ACTUAL_STORAGE
    // ACTUAL_METHODS
    func row(id: String) -> DeviceRow? { devices.first { $0.id == id } }
    func companionControl(for id: String) -> Control? { controls[id] }
    func availableShellProvider(deviceID: String) -> Provider? { shellProviders[deviceID]?.available == true ? shellProviders[deviceID] : nil }
    func verifiedEnhancedRetirementRoute(deviceID: String, captureSerial: String) -> VerifiedEnhancedRetirementRoute? { nil }
    func retireEnhancedScreenSession(deviceID: String) {
        guard let session = scrcpySessions.removeValue(forKey: deviceID) else { return }
        events.values.append("primary-stop:" + deviceID)
        let permit = UUID(); unsettledEnhancedRetirements[permit] = session; enhancedRetirementDeviceIDs[permit] = deviceID
    }
    // ACTUAL_PRIMARY_RELEASE
    func destination(_ id: String) -> String? {
        let device = row(id: id)!
        return CaptureRouteHandoffPlan.destination(adbSerial: device.adbSerial, helperDeviceID: controls[id]?.peer.deviceID,
            capturedSerials: applicationWindowCoordinator?.captureSerials(deviceID: id) ?? [])
    }
    func ensureEnhancedSessionForPrimaryDemand(for device: DeviceRow) {
        guard primaryScreenDemand.hasDemand(device.id), scrcpySessions[device.id] == nil else { return }
        precondition(!captureRouteTransitionDevices.contains(device.id) && !preparingDirectDevices.contains(device.id))
        precondition(!unsettledEnhancedRetirements.keys.contains { enhancedRetirementDeviceIDs[$0] == device.id })
        precondition(applicationWindowCoordinator?.hasRetiringOwners(deviceID: device.id) != true)
        events.values.append("primary-start:" + device.id)
        scrcpySessions[device.id] = Session(destination(device.id)!)
    }
    func reconcileEnhancedClipboardSessions() {}
    func reconcilePhoneDisplayPrivacyRoutes() {}
    func install(_ name: String, frame: Int = 42) {
        let id = "device:" + name, serial = "usb-" + name
        let peer = Peer(deviceID: name, identityPublicKey: Data(name.utf8))
        PairedPeerStore.rows.append(peer); devices.append(.init(id: id, adbSerial: nil))
        controls[id] = .init(peer: peer, authenticatedSessionID: "session-" + name)
        shellProviders[id] = Provider(); scrcpySessions[id] = Session(serial); primaryScreenDemand.devices.insert(id)
        applicationWindowCoordinator!.active[id] = [.init(serial: serial, window: .init(application: .init(packageName: "synthetic." + name), frame: frame))]
    }
    func recover() { reconcileCaptureRouteHandoffs() }
    func stopTests() {
        terminationAdmission.admitsWork = false
        for work in captureRouteRetryTasks.values { work.cancel() }
        for work in captureRouteHandoffTasks.values { work.cancel() }
    }
}
@main struct CaptureRouteRecoverySpec {
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    @MainActor static func main() async throws {
        PairedPeerStore.rows = []
        let sameSerial = AppModel(); sameSerial.install("generation", frame: 73)
        sameSerial.devices[0].adbSerial = "usb-generation"
        sameSerial.recover()
        try expect(sameSerial.captureRouteHandoffTasks.isEmpty, "healthy same-serial owners were unnecessarily replaced")
        let oldGeneration = sameSerial.scrcpySessions["device:generation"]!.capturedADBGeneration
        ADBOwnedRuntime.shared.activeGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        sameSerial.recover(); await sameSerial.captureRouteHandoffTasks["device:generation"]?.value
        try expect(sameSerial.applicationWindowCoordinator!.resumed["device:generation"]?.first?.frame == 73,
            "replacement daemon with unchanged USB serial did not retire/recreate app ownership with geometry")
        try expect(sameSerial.scrcpySessions["device:generation"]?.capturedADBGeneration != oldGeneration
            && sameSerial.events.values.contains("power-drain:device:generation"),
            "replacement daemon retained the old primary or physical panel owner")
        let starts = sameSerial.events.values.filter { $0 == "primary-start:device:generation" }.count
        sameSerial.recover()
        try expect(sameSerial.captureRouteHandoffTasks.isEmpty && starts == 1,
            "generation recovery duplicated successor ownership")
        sameSerial.stopTests()

        PairedPeerStore.rows = []
        let parallel = AppModel(); parallel.install("a", frame: 42); parallel.install("b", frame: 43)
        let gate = Gate(); parallel.applicationWindowCoordinator!.gates["device:a"] = gate
        parallel.recover(); parallel.recover()
        for _ in 0..<1000 where !gate.entered { await Task.yield() }
        try expect(gate.entered, "first phone never reached its deterministic ownership barrier")
        await parallel.captureRouteHandoffTasks["device:b"]?.value
        try expect(parallel.applicationWindowCoordinator!.resumed["device:b"]?.first?.frame == 43,
            "one blocked phone prevented the other phone's independent recovery")
        try expect(parallel.applicationWindowCoordinator!.suspendCount["device:a"] == 1,
            "duplicate reconciliation created overlapping capture handoffs")
        gate.release(); await parallel.captureRouteHandoffTasks["device:a"]?.value
        try expect(parallel.scrcpySessions["device:a"]?.serial == "shell:a" && parallel.scrcpySessions["device:b"]?.serial == "shell:b",
            "handoff used another phone's prepared broker")
        try expect(parallel.applicationWindowCoordinator!.resumed["device:a"]?.first?.frame == 42,
            "first phone's exact app/frame was lost")
        parallel.stopTests()

        PairedPeerStore.rows = []
        let blocked = AppModel(); blocked.install("a"); blocked.applicationWindowCoordinator!.canSettle["device:a"] = false
        blocked.recover(); await blocked.captureRouteHandoffTasks["device:a"]?.value
        try expect(blocked.applicationWindowCoordinator!.resumed.isEmpty && blocked.captureRoutePendingWindows["device:a"]?.count == 1
            && blocked.captureRouteTransitionDevices.contains("device:a"), "unconfirmed owner lost its resume intent or admitted a successor")
        blocked.applicationWindowCoordinator!.canSettle["device:a"] = true; blocked.devices[0].adbSerial = "usb-a"
        blocked.recover(); await blocked.captureRouteHandoffTasks["device:a"]?.value
        try expect(blocked.scrcpySessions["device:a"]?.serial == "usb-a" && blocked.applicationWindowCoordinator!.resumed["device:a"]?.count == 1,
            "a returned verified route failed to interrupt backoff and finish a partial handoff")
        blocked.stopTests()

        PairedPeerStore.rows = []
        let waiting = AppModel(); waiting.install("a"); waiting.clientSetup.waiting.insert("device:a")
        waiting.recover(); await waiting.captureRouteHandoffTasks["device:a"]?.value
        try expect(waiting.applicationWindowCoordinator!.resumed.isEmpty && waiting.captureRouteTransitionDevices.contains("device:a"),
            "Shell windows started before current feature configuration acknowledgement")
        waiting.clientSetup.waiting.remove("device:a"); waiting.recover(); await waiting.captureRouteHandoffTasks["device:a"]?.value
        try expect(waiting.applicationWindowCoordinator!.resumed["device:a"]?.count == 1, "feature ACK did not restore the exact pending window")
        waiting.stopTests()

        PairedPeerStore.rows = []
        let power = AppModel(); power.install("a"); power.selectedDeviceID = "device:b"
        power.phoneDisplayPrivacy.failures.insert("device:a")
        power.recover(); await power.captureRouteHandoffTasks["device:a"]?.value
        try expect(power.applicationWindowCoordinator!.resumed.isEmpty && power.lastError == nil,
            "failed power retirement admitted media or replaced another phone's visible diagnostic")
        power.phoneDisplayPrivacy.failures.remove("device:a")
        await power.captureRouteRetryTasks["device:a"]?.value
        await power.captureRouteHandoffTasks["device:a"]?.value
        try expect(power.applicationWindowCoordinator!.resumed["device:a"]?.count == 1,
            "settled power owner could not recover without another discovery event")
        power.stopTests()

        PairedPeerStore.rows = []
        let replaced = AppModel(); replaced.install("a"); let replacementGate = Gate()
        replaced.applicationWindowCoordinator!.gates["device:a"] = replacementGate
        replaced.recover()
        for _ in 0..<1000 where !replacementGate.entered { await Task.yield() }
        PairedPeerStore.rows[0].identityPublicKey = Data("different-key".utf8)
        replacementGate.release(); await replaced.captureRouteHandoffTasks["device:a"]?.value
        try expect(replaced.applicationWindowCoordinator!.resumed.isEmpty
            && !replaced.events.values.contains("primary-start:device:a"), "old capture work resumed under a replacement phone key")
        replaced.stopTests()
        print("PASS actual capture recovery: unchanged-serial daemon generation replacement, parallel phones, coalescing, partial retry/USB return, pending window geometry, power/native fences, feature ACK, no focus stealing and peer-key replacement")
    }
}
