import Foundation
import OSLog

// ACTUAL_ITEM
enum ShellCapabilityBridgeFailure: Error { case invalidResult, sessionChanged }
final class DecodeGate: @unchecked Sendable {
    static let shared = DecodeGate()
    private let lock = NSLock()
    private var semaphore: DispatchSemaphore?
    private var didStart = false, didTimeout = false
    func arm() { lock.withLock { semaphore = DispatchSemaphore(value: 0); didStart = false; didTimeout = false } }
    var started: Bool { lock.withLock { didStart } }
    var timedOut: Bool { lock.withLock { didTimeout } }
    func release() { lock.withLock { semaphore }?.signal() }
    func beforeDecode() {
        let gate = lock.withLock { () -> DispatchSemaphore? in didStart = true; return semaphore }
        if gate?.wait(timeout: .now() + 2) == .timedOut { lock.withLock { didTimeout = true } }
    }
    func reset() { lock.withLock { semaphore = nil; didStart = false; didTimeout = false } }
}
enum ApplicationCatalogExportManifest {
    static func decode(_ data: Data, maximumApplications: Int) throws -> ActualApplicationCatalogExportManifest {
        DecodeGate.shared.beforeDecode()
        return try ActualApplicationCatalogExportManifest.decode(data, maximumApplications: maximumApplications)
    }
}
@MainActor final class Control { var authenticatedSessionID = "session-1" }
@MainActor final class CatalogBrokerHarness {
    struct Context { let control: Control; let sessionID: String }
    struct Response { let applicationCatalogJson: Data; var errorCode = "" }
    enum Operation { case listApplications }
    var currentControl = Control()
    var response: Response
    init(data: Data) { response = .init(applicationCatalogJson: data) }
    func control() -> Control? { currentControl }
    func context() throws -> Context { .init(control: currentControl, sessionID: currentControl.authenticatedSessionID) }
    func perform(operation: Operation, lease: String, generation: String, context: Context) async throws -> Response { response }
    // ACTUAL_FETCH
}
@main enum CatalogBrokerDecodeSpec {
    static func png(width: UInt32 = 128, height: UInt32 = 128) -> Data {
        var bytes: [UInt8] = [137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82]
        for n in [width, height] { for shift in [24,16,8,0] { bytes.append(UInt8((n >> UInt32(shift)) & 255)) } }
        return Data(bytes)
    }
    static func payload(icon: Data?, count: Int = 1) throws -> Data {
        let rows: [[String: Any]] = (0..<count).map { i in
            var row: [String: Any] = ["package":"com.example.app\(i)", "component":"com.example.app\(i)/.Main",
                                      "label":"Synthetic \(i)", "system":false]
            if let icon { row["icon_png_base64"] = icon.base64EncodedString() }
            return row
        }
        return try JSONSerialization.data(withJSONObject: ["version":1, "applications":rows])
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Decode test did not settle")
    }
    @MainActor static func main() async throws {
        let golden = png()
        let valid = try payload(icon: golden)
        let harness = CatalogBrokerHarness(data: valid)
        let items = try await harness.fetchApplicationCatalog()
        precondition(items.count == 1 && items[0].packageName == "com.example.app0")
        precondition(items[0].componentName == "com.example.app0/.Main" && items[0].iconPNG == golden)
        let unordered = try JSONSerialization.data(withJSONObject: ["version": 1, "applications": [
            ["package": "com.example.zulu", "component": "com.example.zulu/.Main", "label": "Zulu", "system": false],
            ["package": "com.example.alpha", "component": "com.example.alpha/.Main", "label": "alpha", "system": false]
        ]])
        let ordered = try await CatalogBrokerHarness(data: unordered).fetchApplicationCatalog()
        precondition(ordered.map(\.label) == ["alpha", "Zulu"], "Broker and ADB routes must keep the same localized ordering")
        for badIcon in [Data([1,2,3]), png(width: 257), png(height: 0), golden + Data(repeating: 0, count: 65_537)] {
            let invalid = CatalogBrokerHarness(data: try payload(icon: badIcon))
            let result = try await invalid.fetchApplicationCatalog()
            precondition(result.count == 1 && result[0].iconPNG == nil, "Invalid icon must not discard valid app metadata")
        }
        for data in [Data(), Data(repeating: 0, count: 2 * 1024 * 1024 + 1), try payload(icon: nil, count: 513)] {
            do {
                _ = try await CatalogBrokerHarness(data: data).fetchApplicationCatalog()
                preconditionFailure("Catalog bound was not enforced")
            } catch {}
        }
        let denied = CatalogBrokerHarness(data: valid)
        denied.response.errorCode = "feature_disabled"
        do {
            _ = try await denied.fetchApplicationCatalog()
            preconditionFailure("A rejected broker reply was accepted")
        } catch {}
        for sameSession in [false, true] {
            DecodeGate.shared.arm()
            let scoped = CatalogBrokerHarness(data: valid)
            var finished = false, sessionRejected = false
            Task { @MainActor in
                defer { finished = true }
                do { _ = try await scoped.fetchApplicationCatalog() }
                catch ShellCapabilityBridgeFailure.sessionChanged { sessionRejected = true }
                catch { preconditionFailure("Unexpected error \(error)") }
            }
            await until { DecodeGate.shared.started }
            precondition(!DecodeGate.shared.timedOut, "Catalog decode blocked the main actor")
            let replacement = Control()
            if !sameSession { replacement.authenticatedSessionID = "session-2" }
            scoped.currentControl = replacement
            DecodeGate.shared.release()
            await until { finished }
            precondition(sessionRejected, "The async decode must retain exact control-object and session ownership")
            DecodeGate.shared.reset()
        }
        DecodeGate.shared.arm()
        let canceled = CatalogBrokerHarness(data: valid)
        var canceledFinished = false, cancellationObserved = false
        let task = Task { @MainActor in
            defer { canceledFinished = true }
            do { _ = try await canceled.fetchApplicationCatalog() }
            catch is CancellationError { cancellationObserved = true }
            catch { preconditionFailure("Unexpected cancellation error \(error)") }
        }
        await until { DecodeGate.shared.started }
        precondition(!DecodeGate.shared.timedOut)
        task.cancel()
        DecodeGate.shared.release()
        await until { canceledFinished }
        precondition(cancellationObserved, "A canceled caller must not receive decoded items")
        DecodeGate.shared.reset()
        print("PASS actual broker catalog decode: bounds, icons, off-main execution and session/control replacement")
    }
}
