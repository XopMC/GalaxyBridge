import Foundation
import OSLog

struct ApplicationCatalogItem: Equatable, Sendable { let label: String; let iconPNG: Data? = nil }
enum ApplicationCatalogUnavailableReason { case storeBuildUnsupported, directConnectionRequired }
enum ApplicationCatalogState {
    case idle, loading, available([ApplicationCatalogItem]), unavailable(ApplicationCatalogUnavailableReason), failed(String)
}
enum Feature { case applications }
enum ShellCapabilityBridgeFailure: Error { case unavailable, timeout, invalidResult, sessionChanged, operationFailed }
struct DeviceRow { let id: String; var adbSerial: String?; var isReady = true }
@MainActor final class Control { var authenticatedSessionID = "session-1" }
@MainActor final class ShellCapabilityBridgeProvider {
    var available = true, currentRuntimeVerified = true, suspended = false
    var calls = 0
    var returned = 0
    var items = [ApplicationCatalogItem(label: "broker")]
    var failure: ShellCapabilityBridgeFailure?
    var pending: CheckedContinuation<[ApplicationCatalogItem], Error>?
    func fetchApplicationCatalog() async throws -> [ApplicationCatalogItem] {
        calls += 1
        defer { returned += 1 }
        if suspended { return try await withCheckedThrowingContinuation { pending = $0 } }
        if let failure { throw failure }
        return items
    }
}
final class ADBProbe: @unchecked Sendable {
    static let shared = ADBProbe()
    private let lock = NSLock()
    private var loads: [(String, String)] = []
    func reset() { lock.withLock { loads.removeAll() } }
    func load(_ device: String, _ serial: String) -> [ApplicationCatalogItem] {
        lock.withLock { loads.append((device, serial)) }
        return [.init(label: "adb:" + serial)]
    }
    var count: Int { lock.withLock { loads.count } }
}
struct ADBClient: Sendable { init() throws {} }
struct ApplicationCatalogEnhancedClient: Sendable {
    init(adb: ADBClient) {}
    func load(deviceID: String, serial: String) throws -> [ApplicationCatalogItem] {
        ADBProbe.shared.load(deviceID, serial)
    }
}
@MainActor final class AppModel {
    struct Admission { var admitsWork = true }
    var terminationAdmission = Admission()
    var devices: [String: DeviceRow] = [:]
    var providers: [String: ShellCapabilityBridgeProvider] = [:]
    var controls: [String: Control] = [:]
    var applicationCatalogsByDevice: [String: ApplicationCatalogState] = [:]
    var applicationCatalogRequestsByDevice: [String: UUID] = [:]
    var disabled = Set<String>()
    var primaryMediaDiagnosticsEnabled = false
    var lastError: String?
    func featureEnabled(_ feature: Feature, deviceID: String) -> Bool { !disabled.contains(deviceID) }
    func row(id: String) -> DeviceRow? { devices[id] }
    func companionControl(for id: String) -> Control? { controls[id] }
    func availableShellProvider(deviceID: String) -> ShellCapabilityBridgeProvider? {
        providers[deviceID].flatMap { $0.available ? $0 : nil }
    }
    func shellBridgeProvider(deviceID: String) -> ShellCapabilityBridgeProvider? { providers[deviceID] }
    func install(_ id: String, serial: String?) -> ShellCapabilityBridgeProvider {
        devices[id] = .init(id: id, adbSerial: serial)
        controls[id] = Control()
        let provider = ShellCapabilityBridgeProvider()
        providers[id] = provider
        return provider
    }
    // ACTUAL_LOAD
}
@main enum CatalogLoaderSpec {
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Catalog task did not settle")
    }
    @MainActor static func labels(_ model: AppModel, _ id: String) -> [String] {
        guard case let .available(items) = model.applicationCatalogsByDevice[id] else { return [] }
        return items.map(\.label)
    }
    @MainActor static func main() async {
        let id = "device:catalog-a"
        do {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            model.terminationAdmission.admitsWork = false
            model.loadApplicationCatalog(deviceID: id)
            precondition(model.applicationCatalogRequestsByDevice.isEmpty && provider.calls == 0 && ADBProbe.shared.count == 0,
                         "Termination must refuse new catalog work")
        }
        do {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            model.loadApplicationCatalog(deviceID: id)
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(provider.calls == 1 && ADBProbe.shared.count == 0,
                         "A verified prepared broker must avoid ADB export even when ADB is present")
            precondition(labels(model, id) == ["broker"])
            model.loadApplicationCatalog(deviceID: id)
            precondition(provider.calls == 1, "A cached non-forced load must stay local")
        }
        for unverified in [false, true] {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            if unverified { provider.currentRuntimeVerified = false } else { provider.available = false }
            model.loadApplicationCatalog(deviceID: id)
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(provider.calls == 0 && ADBProbe.shared.count == 1)
            precondition(labels(model, id) == ["adb:synthetic-adb-a"])
        }
        do {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: nil)
            model.loadApplicationCatalog(deviceID: id)
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(provider.calls == 1 && labels(model, id) == ["broker"])
        }
        for failure in [ShellCapabilityBridgeFailure.timeout, .unavailable] {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            provider.failure = failure
            model.loadApplicationCatalog(deviceID: id)
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(provider.calls == 1 && ADBProbe.shared.count == 1)
            precondition(labels(model, id) == ["adb:synthetic-adb-a"])
        }
        do {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            model.applicationCatalogsByDevice[id] = .available([.init(label: "retained")])
            provider.failure = .invalidResult
            model.loadApplicationCatalog(deviceID: id, force: true)
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(provider.calls == 1 && ADBProbe.shared.count == 0)
            precondition(labels(model, id) == ["retained"] && model.lastError != nil,
                         "Rejected data must retain the previous catalog without an ADB bypass")
        }
        for sameSessionID in [false, true] {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            provider.suspended = true
            model.loadApplicationCatalog(deviceID: id)
            await until { provider.pending != nil }
            let replacement = Control()
            if !sameSessionID { replacement.authenticatedSessionID = "session-2" }
            model.controls[id] = replacement
            provider.suspended = false
            provider.items = [.init(label: "current-session")]
            provider.pending?.resume(returning: [.init(label: "old-session")])
            provider.pending = nil
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(provider.calls == 2 && ADBProbe.shared.count == 0)
            precondition(labels(model, id) == ["current-session"],
                         "A broker reply bound to an old control session must not publish through an ADB-ready row")
        }
        do {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            provider.suspended = true
            model.loadApplicationCatalog(deviceID: id)
            await until { provider.pending != nil }
            model.disabled.insert(id)
            provider.pending?.resume(throwing: ShellCapabilityBridgeFailure.timeout)
            provider.pending = nil
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(ADBProbe.shared.count == 0 && labels(model, id).isEmpty,
                         "Disabling applications during RPC must fence fallback and publication")
        }
        do {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            provider.suspended = true
            model.loadApplicationCatalog(deviceID: id)
            await until { provider.pending != nil }
            model.terminationAdmission.admitsWork = false
            provider.pending?.resume(throwing: ShellCapabilityBridgeFailure.timeout)
            provider.pending = nil
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(ADBProbe.shared.count == 0 && labels(model, id).isEmpty)
            if case .idle = model.applicationCatalogsByDevice[id] {} else { preconditionFailure("A retired loading owner must not leave an unclickable spinner") }
            model.terminationAdmission.admitsWork = true
            provider.suspended = false
            model.loadApplicationCatalog(deviceID: id)
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(labels(model, id) == ["broker"])
        }
        do {
            ADBProbe.shared.reset()
            let model = AppModel(), provider = model.install(id, serial: "synthetic-adb-a")
            provider.suspended = true
            model.loadApplicationCatalog(deviceID: id)
            await until { provider.pending != nil }
            let newer = UUID()
            model.applicationCatalogRequestsByDevice[id] = newer
            model.applicationCatalogsByDevice[id] = .available([.init(label: "newer-owner")])
            provider.pending?.resume(returning: [.init(label: "old-owner")])
            provider.pending = nil
            await until { provider.returned == 1 }
            precondition(model.applicationCatalogRequestsByDevice[id] == newer && labels(model, id) == ["newer-owner"])
        }
        do {
            ADBProbe.shared.reset()
            let other = "device:catalog-b"
            let model = AppModel(), first = model.install(id, serial: "synthetic-adb-a")
            let second = model.install(other, serial: "synthetic-adb-b")
            first.suspended = true
            second.items = [.init(label: "second-phone")]
            model.loadApplicationCatalog(deviceID: id)
            model.loadApplicationCatalog(deviceID: other)
            await until { first.pending != nil && model.applicationCatalogRequestsByDevice[other] == nil }
            precondition(labels(model, other) == ["second-phone"] && labels(model, id).isEmpty)
            model.controls[id] = Control()
            first.suspended = false
            first.items = [.init(label: "first-current")]
            first.pending?.resume(returning: [.init(label: "first-stale")])
            first.pending = nil
            await until { model.applicationCatalogRequestsByDevice.isEmpty }
            precondition(labels(model, id) == ["first-current"] && labels(model, other) == ["second-phone"])
            precondition(ADBProbe.shared.count == 0)
        }
        print("PASS actual catalog loader: prepared fast path, verified fallback, cache, session replacement and feature fences")
    }
}
