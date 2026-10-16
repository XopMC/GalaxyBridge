import Foundation
import Combine

private enum SpecFailure: Error { case failed(String) }
enum ShellCapabilityBridgeFailure: Error { case unavailable, operationFailed }
struct DeviceRow { var id = "device:phone"; var adbSerial: String? = "verified-usb"; var isReady = true }
struct CompanionControl { var peer = "paired-phone"; var authenticatedSessionID = "session"; var supportsShellBridge = true }
struct ADBClient {}
@MainActor struct ADBBindingStore {
    static var verified = true
    func isVerified(serial: String, peer: String) -> Bool { Self.verified }
}
@MainActor enum ShellCapabilityBridgeActivation {
    enum Outcome { case success, failure, cancelledFailure }
    static var outcome = Outcome.success
    static var calls = 0
    static var gates: [String: PreparationGate] = [:]
    static var activeBySerial: [String: Int] = [:]
    static var maximumBySerial: [String: Int] = [:]
    static var readySerials = Set<String>()
    static func activate(adb: ADBClient, serial: String) async throws {
        calls += 1
        activeBySerial[serial, default: 0] += 1
        maximumBySerial[serial] = max(maximumBySerial[serial, default: 0], activeBySerial[serial, default: 0])
        readySerials.remove(serial)
        defer { activeBySerial[serial, default: 0] -= 1 }
        if let gate = gates.removeValue(forKey: serial) { await gate.wait() }
        switch outcome {
        case .success: readySerials.insert(serial); return
        case .failure: throw ShellCapabilityBridgeFailure.operationFailed
        case .cancelledFailure:
            // The real activation boundary maps its errors to operationFailed.
            withUnsafeCurrentTask { $0?.cancel() }
            throw ShellCapabilityBridgeFailure.operationFailed
        }
    }
}
@MainActor final class Provider {
    var refreshResults = [false, true]
    var bootGeneration: String? = "original-generation"
    var refreshCalls = 0
    var runtimeSerial: String?
    var refreshGate: PreparationGate?
    func refresh() async -> Bool {
        refreshCalls += 1
        if let gate = refreshGate { refreshGate = nil; await gate.wait() }
        if let runtimeSerial { return ShellCapabilityBridgeActivation.readySerials.contains(runtimeSerial) }
        return refreshResults.isEmpty ? false : refreshResults.removeFirst()
    }
}
typealias ShellCapabilityBridgeProvider = Provider
@MainActor final class EventLog { var values: [String] = [] }
@MainActor final class PreparationGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
@MainActor final class NearbyConnection {
    let log: EventLog
    var connections: [String] = []
    init(log: EventLog) { self.log = log }
    func connect(deviceID: String) { connections.append(deviceID); log.values.append("connect") }
    func autoConnectIfUnassociated(deviceID: String) { connections.append(deviceID); log.values.append("auto-connect") }
}
@MainActor final class ApplicationWindowCoordinator {
    struct RouteResume {}
    struct Suspension { let windows: [RouteResume]; let settled: Bool }
    let log: EventLog
    var settled = true
    var suspendCalls = 0
    var gate: PreparationGate?
    init(log: EventLog) { self.log = log }
    func suspendForRouteChange(deviceID: String) async -> Suspension {
        suspendCalls += 1; log.values.append("suspend")
        if let gate { await gate.wait() }
        return Suspension(windows: [.init()], settled: settled)
    }
    func resumeAfterRouteChange(_ windows: [RouteResume], device: DeviceRow, model: AppModel) { log.values.append("resume") }
}
@MainActor final class ClipboardSession {
    let log: EventLog
    init(log: EventLog) { self.log = log }
    func stopAndWait() async { log.values.append("clipboard-stop") }
}
@MainActor final class PhoneDisplayPrivacy {
    enum Status { case idle, failed }
    let log: EventLog
    var fails = false
    init(log: EventLog) { self.log = log }
    func waitForSettlement(deviceID: String) async { log.values.append("privacy-settle") }
    func status(deviceID: String) -> Status { fails ? .failed : .idle }
}
@MainActor final class AppModel: ObservableObject {
    struct TerminationAdmission { var admitsWork = true }
    let log = EventLog()
    var terminationAdmission = TerminationAdmission()
    // ACTUAL_SHELL_READINESS_STORAGE
    // ACTUAL_PREPARATION_TASK_STORAGE
    var nearbyPreparationTickets: [String: UUID] = [:]
    var preparingDirectDevices = Set<String>()
    var requestedDirectDevices = Set<String>()
    var shellPreferredDevices = Set<String>()
    var phonePrivacyManualPower: [String: Bool] = [:]
    var enhancedRetirements: [UUID: Task<Void, Never>] = [:]
    var enhancedRetirementDeviceIDs: [UUID: String] = [:]
    var unsettledEnhancedRetirements: [UUID: Bool] = [:]
    var clipboardSessions: [String: ClipboardSession] = [:]
    var device = DeviceRow()
    var provider: Provider? = Provider()
    var control: CompanionControl? = .init()
    var deleted = false
    var additionalDevices: [DeviceRow] = []
    var additionalProviders: [String: Provider] = [:]
    var additionalControls: [String: CompanionControl] = [:]
    var devices: [DeviceRow] { (deleted ? [] : [device]) + additionalDevices }
    var shellProviders: [String: Provider] {
        var values = additionalProviders
        if !deleted { values[device.id] = provider }
        return values
    }
    var reconciliations = 0
    var shellProbeTasks: [String: Task<Void, Never>] = [:]
    var shellProbeSessions: [String: String] = [:]
    var shellProbeTickets: [String: UUID] = [:]
    var lastError: String?
    lazy var nearbyConnection = NearbyConnection(log: log)
    lazy var applicationWindowCoordinator: ApplicationWindowCoordinator? = ApplicationWindowCoordinator(log: log)
    lazy var phoneDisplayPrivacy = PhoneDisplayPrivacy(log: log)
    func row(id: String) -> DeviceRow? { devices.first { $0.id == id } }
    func shellBridgeProvider(deviceID: String) -> Provider? { shellProviders[deviceID] }
    func companionControl(for deviceID: String) -> CompanionControl? { deviceID == device.id ? (deleted ? nil : control) : additionalControls[deviceID] }
    func canConnectNearby(deviceID: String) -> Bool { true }
    func nearbyAutoConnect(deviceID: String) -> Bool { false }
    func reconcileEnhancedClipboardSessions() {}
    func reconcilePhoneDisplayPrivacyRoutes() {}
    func ensureEnhancedSessionForPrimaryDemand(for device: DeviceRow) {}
    func reconcileEnhancedPrimaryRoutes() { reconciliations += 1 }
    func loadApplicationCatalog(deviceID: String, force: Bool) {}
    func retireEnhancedScreenSession(deviceID: String) { log.values.append("screen-retire") }
    func begin(automatic: Bool, connect: Bool) {
        prepareNearbyConnection(deviceID: "device:phone", automatic: automatic, connectAfterPreparation: connect)
    }
    func probe() { reconcileShellCapabilities() }
    // ACTUAL_SHELL_READINESS
    // ACTUAL_NEARBY_PREPARATION
    // ACTUAL_PREPARATION_PRESENTATION
    // ACTUAL_SHELL_RECONCILIATION
}
private extension String {
    func removingPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}

@main enum NearbyPreparationSpec {
    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SpecFailure.failed(message) }
    }
    @MainActor private static func run(_ model: AppModel, automatic: Bool = false, connect: Bool = true) async {
        model.begin(automatic: automatic, connect: connect)
        let work = model.nearbyPreparationTasks["device:phone"]
        await work?.value
    }
    @MainActor private static func reset() {
        ADBBindingStore.verified = true
        ShellCapabilityBridgeActivation.outcome = .success
        ShellCapabilityBridgeActivation.calls = 0
        ShellCapabilityBridgeActivation.gates = [:]
        ShellCapabilityBridgeActivation.activeBySerial = [:]
        ShellCapabilityBridgeActivation.maximumBySerial = [:]
        ShellCapabilityBridgeActivation.readySerials = []
    }
    @MainActor static func main() async throws {
        // Removing shared admission between automatic probing and manual preparation
        // must expose overlapping runtime.prepare calls for the same verified phone.
        for probeFirst in [true, false] {
            reset()
            let model = AppModel(), activation = PreparationGate()
            model.provider?.runtimeSerial = "verified-usb"
            ShellCapabilityBridgeActivation.gates["verified-usb"] = activation
            if probeFirst { model.probe() } else { model.begin(automatic: false, connect: true) }
            for _ in 0..<200 where !activation.entered { await Task.yield() }
            try expect(activation.entered, "The first activation must reach its deterministic prepare/attach gate")
            if probeFirst { model.begin(automatic: false, connect: true) } else { model.probe() }
            for _ in 0..<100 { await Task.yield() }
            let overlap = ShellCapabilityBridgeActivation.maximumBySerial["verified-usb", default: 0]
            activation.release()
            await model.shellProbeTasks["device:phone"]?.value
            await model.nearbyPreparationTasks["device:phone"]?.value
            try expect(overlap == 1 && ShellCapabilityBridgeActivation.calls == 1,
                "Automatic probing and manual nearby preparation must share one activation for the same verified phone")
            try expect(model.nearbyConnection.connections == ["phone"] && model.shellPreferredDevices.contains("device:phone") && model.reconciliations > 0,
                "Both consumers must receive usable shell readiness from the shared activation")
        }

        // Different phones must not be serialized behind another phone's attach.
        reset()
        let independent = AppModel(), firstGate = PreparationGate(), secondGate = PreparationGate()
        independent.provider?.runtimeSerial = "verified-usb"
        let otherProvider = Provider(); otherProvider.runtimeSerial = "other-usb"
        independent.additionalDevices = [DeviceRow(id: "device:other", adbSerial: "other-usb")]
        independent.additionalProviders["device:other"] = otherProvider
        independent.additionalControls["device:other"] = .init(peer: "other-phone")
        ShellCapabilityBridgeActivation.gates = ["verified-usb": firstGate, "other-usb": secondGate]
        independent.probe()
        for _ in 0..<200 where !firstGate.entered || !secondGate.entered { await Task.yield() }
        let bothEntered = firstGate.entered && secondGate.entered
        firstGate.release(); secondGate.release()
        for work in Array(independent.shellProbeTasks.values) { await work.value }
        try expect(bothEntered && independent.reconciliations == 2,
            "An unrelated phone's shell activation must progress while the first phone is attaching")

        // Canceling one consumer must not destroy readiness still needed by another.
        reset()
        let cancelledWaiter = AppModel(), sharedGate = PreparationGate()
        cancelledWaiter.provider?.runtimeSerial = "verified-usb"
        ShellCapabilityBridgeActivation.gates["verified-usb"] = sharedGate
        cancelledWaiter.probe()
        for _ in 0..<200 where !sharedGate.entered { await Task.yield() }
        cancelledWaiter.begin(automatic: false, connect: true)
        for _ in 0..<50 { await Task.yield() }
        let cancelledWork = cancelledWaiter.nearbyPreparationTasks["device:phone"]
        cancelledWaiter.requestedDirectDevices.remove("device:phone")
        cancelledWork?.cancel()
        sharedGate.release()
        await cancelledWork?.value
        await cancelledWaiter.shellProbeTasks["device:phone"]?.value
        try expect(cancelledWaiter.nearbyConnection.connections.isEmpty && cancelledWaiter.shellPreferredDevices.isEmpty && cancelledWaiter.reconciliations > 0,
            "A cancelled manual consumer must not connect or prevent the automatic consumer from completing")
        try expect(ShellCapabilityBridgeActivation.calls == 1,
            "Cancellation of a waiter must retain the shared activation until settlement")

        // Each suspension point must fence the identity that obtained readiness.
        // Provider replacement models pairing deletion/recreation under the same ID.
        for change in ["session", "serial", "provider", "deleted", "termination", "cancel"] {
            reset()
            let stale = AppModel(), attachGate = PreparationGate()
            stale.provider?.runtimeSerial = "verified-usb"
            let oldProvider = stale.provider!
            ShellCapabilityBridgeActivation.gates["verified-usb"] = attachGate
            stale.probe()
            for _ in 0..<200 where !attachGate.entered { await Task.yield() }
            stale.begin(automatic: false, connect: true)
            for _ in 0..<50 { await Task.yield() }
            let probeWork = stale.shellProbeTasks["device:phone"]
            let manualWork = stale.nearbyPreparationTasks["device:phone"]
            switch change {
            case "session": stale.control?.authenticatedSessionID = "replacement"
            case "serial": stale.device.adbSerial = "replacement-usb"
            case "provider": stale.provider = Provider()
            case "deleted": stale.deleted = true
            case "termination": stale.terminationAdmission.admitsWork = false
            default: stale.requestedDirectDevices.remove("device:phone"); probeWork?.cancel(); manualWork?.cancel()
            }
            attachGate.release()
            await probeWork?.value; await manualWork?.value
            try expect(stale.nearbyConnection.connections.isEmpty && stale.shellPreferredDevices.isEmpty && stale.reconciliations == 0,
                "An obsolete \(change) result must never install shell owners or start nearby")
            try expect(oldProvider.refreshCalls == (change == "cancel" ? 2 : 1),
                "An obsolete \(change) result must refresh only a provider whose route remains current")
            try expect(stale.nearbyPreparationTasks.isEmpty && stale.shellProbeTasks.isEmpty,
                "An obsolete \(change) consumer must retire its admission")
        }

        // Revocation/reconnection can replace a probe while its old worker settles.
        for replacement in ["serial", "provider"] {
            reset()
            let replacing = AppModel(), oldAttach = PreparationGate(), newStatus = PreparationGate()
            replacing.provider?.runtimeSerial = "verified-usb"
            ShellCapabilityBridgeActivation.gates["verified-usb"] = oldAttach
            replacing.probe()
            for _ in 0..<200 where !oldAttach.entered { await Task.yield() }
            let oldProbe = replacing.shellProbeTasks.removeValue(forKey: "device:phone")
            oldProbe?.cancel()
            replacing.shellProbeSessions.removeValue(forKey: "device:phone")
            if replacement == "serial" { replacing.device.adbSerial = "replacement-usb" }
            let replacementProvider = Provider()
            replacementProvider.runtimeSerial = replacing.device.adbSerial
            replacementProvider.refreshGate = newStatus
            replacing.provider = replacementProvider
            replacing.probe()
            let replacementProbe = replacing.shellProbeTasks["device:phone"]
            for _ in 0..<50 { await Task.yield() }
            let overtookOldActivation = newStatus.entered
            oldAttach.release()
            await oldProbe?.value
            for _ in 0..<200 where !newStatus.entered { await Task.yield() }
            let replacementStillAdmitted = replacing.shellProbeTasks["device:phone"] != nil
            newStatus.release(); await replacementProbe?.value
            try expect(!overtookOldActivation,
                "A replacement \(replacement) must wait for the old phone activation to settle")
            try expect(replacementStillAdmitted && replacing.reconciliations == 1,
                "An obsolete \(replacement) probe must not retire its replacement's admission")
        }

        // A valid initial STATUS cannot authorize migration after a later route change.
        for change in ["session", "serial", "provider", "generation", "deleted"] {
            reset()
            let migrating = AppModel(), settlement = PreparationGate()
            migrating.provider?.refreshResults = [true]
            migrating.applicationWindowCoordinator?.gate = settlement
            migrating.begin(automatic: false, connect: true)
            for _ in 0..<200 where !settlement.entered { await Task.yield() }
            let work = migrating.nearbyPreparationTasks["device:phone"]
            switch change {
            case "session": migrating.control?.authenticatedSessionID = "replacement"
            case "serial": migrating.device.adbSerial = "replacement-usb"
            case "provider": migrating.provider = Provider()
            case "generation": migrating.provider?.bootGeneration = "replacement-generation"
            default: migrating.deleted = true
            }
            settlement.release(); await work?.value
            try expect(migrating.nearbyConnection.connections.isEmpty && migrating.shellPreferredDevices.isEmpty,
                "A \(change) change while owners settle must invalidate the prepared shell route")
        }

        reset()
        ShellCapabilityBridgeActivation.outcome = .failure
        let sharedFailure = AppModel(), failureGate = PreparationGate()
        sharedFailure.provider?.runtimeSerial = "verified-usb"
        ShellCapabilityBridgeActivation.gates["verified-usb"] = failureGate
        sharedFailure.probe()
        for _ in 0..<200 where !failureGate.entered { await Task.yield() }
        sharedFailure.begin(automatic: false, connect: true)
        for _ in 0..<50 { await Task.yield() }
        failureGate.release()
        await sharedFailure.shellProbeTasks["device:phone"]?.value
        await sharedFailure.nearbyPreparationTasks["device:phone"]?.value
        try expect(ShellCapabilityBridgeActivation.calls == 1 && sharedFailure.nearbyConnection.connections == ["phone"] && sharedFailure.reconciliations == 1,
            "A shared activation failure must preserve basic nearby fallback and automatic route reconciliation")
        try expect(sharedFailure.shellReadinessTasks.isEmpty && sharedFailure.shellProbeTasks.isEmpty && sharedFailure.nearbyPreparationTasks.isEmpty,
            "A failed shared operation must retire admission for a future retry")

        reset()
        let oldHelper = AppModel(); oldHelper.control?.supportsShellBridge = false
        oldHelper.probe()
        await oldHelper.shellProbeTasks["device:phone"]?.value
        try expect(oldHelper.provider?.refreshCalls == 0,
            "An old Helper without negotiated shell protocol must not receive unsolicited STATUS requests")

        reset()
        let preparing = AppModel(), gate = PreparationGate()
        preparing.provider?.refreshResults = [true]
        preparing.applicationWindowCoordinator?.gate = gate
        preparing.clipboardSessions["device:phone"] = ClipboardSession(log: preparing.log)
        var publications = 0
        let observation = preparing.objectWillChange.sink { publications += 1 }
        preparing.begin(automatic: false, connect: true)
        let work = preparing.nearbyPreparationTasks["device:phone"]
        for _ in 0..<40 { await Task.yield() }
        try expect(preparing.nearbyIsPreparing(deviceID: "phone") && publications > 0,
            "Preparation must publish a cancelable state before Bluetooth begins")
        work?.cancel()
        try expect(preparing.nearbyIsPreparing(deviceID: "device:phone"),
            "Cancellation must retain admission until suspended owners settle")
        gate.release(); await work?.value
        try expect(!preparing.nearbyIsPreparing(deviceID: "phone") && publications >= 2,
            "Settlement must publish the end of preparation")
        try expect(preparing.log.values == ["suspend", "screen-retire", "clipboard-stop", "privacy-settle", "resume"],
            "Cancellation must settle and restore advanced owners without starting Bluetooth")
        observation.cancel()

        reset()
        ShellCapabilityBridgeActivation.outcome = .failure
        let failedActivation = AppModel()
        await run(failedActivation)
        try expect(failedActivation.nearbyConnection.connections == ["phone"], "Optional shell activation failure must still reach basic nearby connect")
        try expect(failedActivation.applicationWindowCoordinator?.suspendCalls == 0 && failedActivation.shellPreferredDevices.isEmpty,
            "Failed optional activation must not suspend or migrate existing advanced owners")

        reset()
        let failedRefresh = AppModel(); failedRefresh.provider?.refreshResults = [false, false]
        await run(failedRefresh, automatic: true)
        try expect(failedRefresh.log.values.contains("auto-connect"), "Unavailable post-activation shell refresh must preserve automatic basic nearby")
        try expect(failedRefresh.applicationWindowCoordinator?.suspendCalls == 0, "Unavailable shell must not begin advanced owner migration")

        reset(); ADBBindingStore.verified = false
        let unverified = AppModel()
        await run(unverified)
        try expect(unverified.nearbyConnection.connections == ["phone"] && ShellCapabilityBridgeActivation.calls == 0,
            "Basic nearby must remain available without verified shell activation authority")

        reset(); ShellCapabilityBridgeActivation.outcome = .cancelledFailure
        let cancelled = AppModel()
        await run(cancelled)
        try expect(cancelled.nearbyConnection.connections.isEmpty, "Cancellation hidden by the activation boundary must never start nearby")

        reset(); ShellCapabilityBridgeActivation.outcome = .failure
        let preflight = AppModel()
        await run(preflight, connect: false)
        try expect(preflight.nearbyConnection.connections.isEmpty, "Optional USB preparation alone must never join a network")

        reset()
        let succeeded = AppModel()
        succeeded.clipboardSessions["device:phone"] = ClipboardSession(log: succeeded.log)
        await run(succeeded)
        try expect(succeeded.log.values == ["suspend", "screen-retire", "clipboard-stop", "privacy-settle", "resume", "connect"],
            "Successful shell migration must settle every advanced owner before connecting")
        try expect(succeeded.shellPreferredDevices.contains("device:phone"), "Successful migration must select the shell route")

        reset()
        let unsettled = AppModel(); unsettled.applicationWindowCoordinator?.settled = false
        await run(unsettled)
        try expect(unsettled.nearbyConnection.connections.isEmpty && !unsettled.shellPreferredDevices.contains("device:phone"),
            "Window retirement failure must remain terminal instead of entering basic fallback")

        reset()
        let privacyFailure = AppModel(); privacyFailure.phoneDisplayPrivacy.fails = true
        await run(privacyFailure)
        try expect(privacyFailure.nearbyConnection.connections.isEmpty && !privacyFailure.shellPreferredDevices.contains("device:phone"),
            "Privacy retirement failure must remain terminal instead of entering basic fallback")
        try expect(privacyFailure.nearbyPreparationTasks.isEmpty && privacyFailure.preparingDirectDevices.isEmpty,
            "Failure must retire its preparation admission")
        print("PASS actual nearby preparation: coalesced activation in both entry orders, parallel phones, consumer cancellation, replacement probe admission, stale route/boot generation fences, old-Helper gating, optional shell fallback and ordered owner settlement; no ADB or network")
    }
}
