import Foundation

private enum SpecFailure: Error { case failed(String) }
enum ShellCapabilityBridgeFailure: Error { case unavailable, operationFailed }
struct DeviceRow { var id = "device:phone"; var adbSerial: String? = "verified-usb" }
struct CompanionControl { let peer = "paired-phone" }
struct ADBClient {}
@MainActor struct ADBBindingStore {
    static var verified = true
    func isVerified(serial: String, peer: String) -> Bool { Self.verified }
}
@MainActor enum ShellCapabilityBridgeActivation {
    enum Outcome { case success, failure, cancelledFailure }
    static var outcome = Outcome.success
    static var calls = 0
    static func activate(adb: ADBClient, serial: String) async throws {
        calls += 1
        switch outcome {
        case .success: return
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
    func refresh() async -> Bool { refreshResults.isEmpty ? false : refreshResults.removeFirst() }
}
@MainActor final class EventLog { var values: [String] = [] }
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
    init(log: EventLog) { self.log = log }
    func suspendForRouteChange(deviceID: String) async -> Suspension {
        suspendCalls += 1; log.values.append("suspend")
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
@MainActor final class AppModel {
    struct TerminationAdmission { var admitsWork = true }
    let log = EventLog()
    var terminationAdmission = TerminationAdmission()
    var nearbyPreparationTasks: [String: Task<Void, Never>] = [:]
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
    var lastError: String?
    lazy var nearbyConnection = NearbyConnection(log: log)
    lazy var applicationWindowCoordinator: ApplicationWindowCoordinator? = ApplicationWindowCoordinator(log: log)
    lazy var phoneDisplayPrivacy = PhoneDisplayPrivacy(log: log)
    func row(id: String) -> DeviceRow? { device }
    func shellBridgeProvider(deviceID: String) -> Provider? { provider }
    func companionControl(for deviceID: String) -> CompanionControl? { .init() }
    func reconcileEnhancedClipboardSessions() {}
    func reconcilePhoneDisplayPrivacyRoutes() {}
    func ensureEnhancedSessionForPrimaryDemand(for device: DeviceRow) {}
    func retireEnhancedScreenSession(deviceID: String) { log.values.append("screen-retire") }
    func begin(automatic: Bool, connect: Bool) {
        prepareNearbyConnection(deviceID: "device:phone", automatic: automatic, connectAfterPreparation: connect)
    }
    // ACTUAL_NEARBY_PREPARATION
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
    }
    @MainActor static func main() async throws {
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
        print("PASS actual nearby preparation: optional activation/refresh/authority failure fallback, cancellation, preparation-only mode, ordered owner migration and terminal settlement failures; no ADB or network")
    }
}
