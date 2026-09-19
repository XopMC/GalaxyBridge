#if !GALAXYBRIDGE_APP_STORE
import Combine
import Foundation
import Network

protocol WirelessSetupClient: Sendable {
    func discover() async throws -> [WirelessADBService]
    func pair(_ service: WirelessADBService, code: WirelessADBPairingCode) async throws
    func connect(_ service: WirelessADBService) async throws -> Bool
}

private actor WirelessADBOperationQueue {
    static let shared = WirelessADBOperationQueue()
    private var tail: Task<Void, Never>?
    func perform<T: Sendable>(cancellation: ADBProcessCancellation,
                             operation: @escaping @Sendable () throws -> T) async throws -> T {
        let previous = tail
        let work = Task.detached(priority: .utility) {
            await previous?.value
            if cancellation.isCancelled { throw CancellationError() }
            return try operation()
        }
        tail = Task { _ = await work.result }
        return try await work.value
    }
}

private struct WirelessADBAdvertisement: Sendable {
    let name: String
    let type: String
    let domain: String
    var kind: WirelessADBService.Kind { type == "_adb-tls-pairing._tcp" ? .pairing : .connection }
}

final class LocalWirelessSetupClient: @unchecked Sendable, WirelessSetupClient {
    private let lock = NSLock()
    private var advertisements: [String: WirelessADBAdvertisement] = [:]
    private var browsers: [NWBrowser] = []

    init() {
        for type in ["_adb-tls-pairing._tcp", "_adb-tls-connect._tcp"] {
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let found = results.compactMap { result -> WirelessADBAdvertisement? in
                    guard case let .service(name, serviceType, domain, _) = result.endpoint else { return nil }
                    return WirelessADBAdvertisement(name: name, type: serviceType, domain: domain)
                }
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.advertisements = self.advertisements.filter { $0.value.type != type }
                for advertisement in found {
                    self.advertisements["\(advertisement.name)|\(advertisement.type)|\(advertisement.domain)"] = advertisement
                }
            }
            browser.start(queue: DispatchQueue(label: "com.xopmc.GalaxyBridge.wireless-adb.\(type)"))
            browsers.append(browser)
        }
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable (ADBClient) throws -> T) async throws -> T {
        let cancellation = ADBProcessCancellation()
        return try await withTaskCancellationHandler {
            try await WirelessADBOperationQueue.shared.perform(cancellation: cancellation) {
                try operation(ADBClient().cancelling(with: cancellation))
            }
        } onCancel: { cancellation.cancel() }
    }
    private func discoveredAdvertisements() -> [WirelessADBAdvertisement] {
        lock.lock()
        defer { lock.unlock() }
        return Array(advertisements.values)
    }
    func discover() async throws -> [WirelessADBService] {
        let pending = discoveredAdvertisements()
        return try await withThrowingTaskGroup(of: WirelessADBService?.self) { group in
            for advertisement in pending { group.addTask { Self.resolve(advertisement) } }
            var services: [WirelessADBService] = []
            for try await service in group { if let service { services.append(service) } }
            return services
        }
    }

    private static func resolve(_ advertisement: WirelessADBAdvertisement) -> WirelessADBService? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = ["-L", advertisement.name, advertisement.type, advertisement.domain]
        process.standardOutput = output; process.standardError = output
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { process.terminate() } }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return WirelessADBService.parseBonjourResolution(
            name: advertisement.name, kind: advertisement.kind, output: text
        )
    }
    func pair(_ service: WirelessADBService, code: WirelessADBPairingCode) async throws {
        try await perform { try $0.pair(service: service, code: code) }
    }
    func connect(_ service: WirelessADBService) async throws -> Bool {
        try await perform { client in
            _ = try client.connect(endpoint: service.endpoint)
            return try client.devices().contains {
                $0.state == .device && ($0.serial == service.endpoint || $0.serial == service.name)
            }
        }
    }
}

/// Owns a bounded Wi-Fi setup attempt, not logical-device identity. A paired
/// ADB endpoint must still pass the existing signed Companion binding in AppModel.
@MainActor
final class WirelessSetupCoordinator: ObservableObject {
    enum Phase: Equatable {
        case searching, enterCode, multiplePhones, pairing, connecting
        case connected(String)
        case failed(String)
    }
    @Published private(set) var phase: Phase = .searching
    @Published private(set) var service: WirelessADBService?
    private let client: any WirelessSetupClient
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let pollDelay: Duration
    private let connectionAttempts: Int

    init(client: any WirelessSetupClient = LocalWirelessSetupClient(), pollDelay: Duration = .seconds(1), connectionAttempts: Int = 15) {
        self.client = client
        self.pollDelay = pollDelay
        self.connectionAttempts = connectionAttempts
    }

    func search() {
        cancel()
        phase = .searching
        let ticket = generation
        task = Task { [weak self, client, pollDelay] in
            // Discovery is finite and user-restartable; never churn indefinitely
            // when debugging is disabled or the local-network permission is denied.
            for _ in 0..<120 {
                do {
                    let candidates = try await client.discover().filter { $0.kind == .pairing }
                    guard !Task.isCancelled, let self, self.generation == ticket else { return }
                    self.service = candidates.count == 1 ? candidates[0] : nil
                    self.phase = candidates.isEmpty ? .searching : candidates.count == 1 ? .enterCode : .multiplePhones
                    try await Task.sleep(for: pollDelay)
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, let self, self.generation == ticket else { return }
                    self.phase = .failed("WIFI_SETUP_DISCOVERY_FAILED")
                    return
                }
            }
            guard let self, self.generation == ticket else { return }
            self.service = nil
            self.phase = .failed("WIFI_SETUP_DISCOVERY_TIMEOUT")
        }
    }

    func submit(code: String) {
        guard phase == .enterCode, let selected = service,
              let pairingCode = WirelessADBPairingCode(code) else { return }
        cancel()
        phase = .pairing
        let ticket = generation
        task = Task { [weak self, client, pollDelay, connectionAttempts] in
            do {
                try await client.pair(selected, code: pairingCode)
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                self.phase = .connecting
                for _ in 0..<connectionAttempts {
                    let candidates = try await client.discover().filter {
                        $0.kind == .connection && $0.host == selected.host
                    }
                    guard !Task.isCancelled, self.generation == ticket else { return }
                    if candidates.count == 1, try await client.connect(candidates[0]) {
                        guard !Task.isCancelled, self.generation == ticket else { return }
                        self.phase = .connected(candidates[0].endpoint)
                        return
                    }
                    try await Task.sleep(for: pollDelay)
                }
                self.phase = .failed("WIFI_SETUP_CONNECT_RETRY")
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, let self, self.generation == ticket else { return }
                self.phase = .failed(self.phase == .pairing ? "WIFI_SETUP_CODE_REJECTED" : "WIFI_SETUP_CONNECT_RETRY")
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        service = nil
    }
}
#endif
