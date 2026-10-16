#if !GALAXYBRIDGE_APP_STORE
import AppKit
import Combine
import CryptoKit
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeProtocol

struct InternetSharingPresentation: Equatable {
    var enabled = false
    var key = "INTERNET_UNAVAILABLE"
    var upstream = "unavailable"
    var bytesSent: UInt64 = 0
    var bytesReceived: UInt64 = 0
}

@MainActor
final class InternetSharingCoordinator: ObservableObject {
    @Published private(set) var devices: [String: InternetSharingPresentation] = [:]
    @Published private(set) var helperError: String?
    @Published private(set) var uninstalling = false
    @Published var selection = "automatic" { didSet { updatePolicy(); scheduleRebuild() } }
    private let driver = InternetTunnelDriver()
    private final class Device {
        let generation = UUID()
        let control: CompanionTLSClient
        let leaseID = UUID().uuidString.lowercased()
        var requestID = ""
        var relay: PairedInternetRelay?
        var preparingRelay: PairedInternetRelay?
        var healthy = false
        var preparationGeneration = UUID()
        var upstream = "unavailable"
        var preparation: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        init(control: CompanionTLSClient) { self.control = control }
    }
    private struct VerifiedGateway {
        let id: String
        let device: Device
        let preparation: UUID
        let relay: PairedInternetRelay
    }
    private var sessions: [String: Device] = [:]
    private var wanted = Set<String>()
    private var knownPeers: [String: String] = [:]
    private let username = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).map { String(format: "%02x", $0) }.joined()
    private let password = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).map { String(format: "%02x", $0) }.joined()
    private var rebuilding: Task<Void, Never>?
    private var rebuildRevision: UInt64 = 0
    private var rebuildToken: UUID?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var subscriptions = Set<AnyCancellable>()

    init() {
        driver.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            for device in self.sessions.values {
                var request = GBInternetSharingRequest(); request.requestID = UUID().uuidString.lowercased()
                request.leaseID = device.leaseID; request.enabled = true
                try? device.control.sendInternetSharing(request)
            }
        }.store(in: &subscriptions)
        driver.$state.sink { [weak self] state in
            guard case .failed = state, let self, self.rebuilding?.isCancelled != true else { return }
            let revision = self.rebuildRevision
            let affected = self.sessions.map { ($0.key, $0.value, $0.value.preparationGeneration) }
            Task { @MainActor [weak self] in
                guard let self, self.rebuildRevision == revision else { return }
                for (id, device, preparation) in affected where self.sessions[id] === device && device.preparationGeneration == preparation {
                    self.fail(deviceID: id, device: device, key: "INTERNET_FAILED")
                }
            }
        }.store(in: &subscriptions)
    }
    func setEnabled(_ enabled: Bool, deviceID: String, control: CompanionTLSClient?) {
        if !enabled { disable(deviceID: deviceID); return }
        guard !uninstalling, sessions[deviceID] == nil else { return }
        guard let control, control.supportsInternetGateway, sessions.count < 2 else {
            devices[deviceID] = wanted.contains(deviceID) ? .init(enabled: true, key: "INTERNET_WAITING") : .init(key: "INTERNET_UNAVAILABLE")
            return
        }
        wanted.insert(deviceID); knownPeers[deviceID] = control.peer.deviceID
        let device = Device(control: control); sessions[deviceID] = device
        var request = GBInternetSharingRequest(); request.requestID = UUID().uuidString.lowercased()
        request.enabled = true; request.leaseID = device.leaseID; device.requestID = request.requestID
        devices[deviceID] = .init(enabled: true, key: "INTERNET_WAITING")
        do { try control.sendInternetSharing(request) }
        catch { fail(deviceID: deviceID, device: device, key: "INTERNET_UNAVAILABLE"); return }
        device.timeout = Task { [weak self, weak device] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, let device, self.sessions[deviceID] === device else { return }
            self.fail(deviceID: deviceID, device: device, key: "INTERNET_FAILED")
        }
    }
    func receive(_ status: GBInternetSharingStatus, deviceID: String, control: CompanionTLSClient) {
        guard let device = sessions[deviceID], device.control === control, status.leaseID == device.leaseID else { return }
        if status.enabled { device.timeout?.cancel(); device.timeout = nil }
        let changed = device.upstream != status.upstream
        let wasHealthy = device.healthy
        let waitingForUpstream = status.enabled && ["no_validated_upstream", "vpn_upstream_unavailable", "upstream_binding_failed", "native_gateway_unavailable"].contains(status.errorCode)
        var presentation = devices[deviceID] ?? .init(enabled: true, key: "INTERNET_WAITING")
        presentation.upstream = status.upstream
        presentation.bytesSent = status.bytesSent; presentation.bytesReceived = status.bytesReceived
        if waitingForUpstream || changed { presentation.key = "INTERNET_WAITING" }
        if devices[deviceID] != presentation { devices[deviceID] = presentation }
        device.upstream = status.upstream
        if changed || !status.errorCode.isEmpty {
            device.preparationGeneration = UUID(); device.preparation?.cancel(); device.preparation = nil
            device.preparingRelay?.stop(); device.preparingRelay = nil
        }
        if waitingForUpstream {
            device.healthy = false; updateHealth()
            if wasHealthy { scheduleRebuild() }
            return
        }
        if changed { device.healthy = false; updateHealth(); scheduleRebuild() }
        guard status.enabled, status.errorCode.isEmpty else {
            fail(deviceID: deviceID, device: device, key: status.errorCode == "internet_sharing_not_allowed"
                ? "INTERNET_PHONE_PERMISSION_REQUIRED" : "INTERNET_FAILED")
            return
        }
        guard !device.healthy, device.preparation == nil else { return }
        let preparation = UUID(); device.preparationGeneration = preparation
        device.preparation = Task { [weak self, weak device] in
            guard let self, let device else { return }
            let host = UserDefaults.standard.string(forKey: "com.xopmc.GalaxyBridge.host-id") ?? ""
            let relay = device.relay ?? PairedInternetRelay(endpoint: control.resolvedEndpoint, peer: control.peer,
                hostID: host, sessionID: control.authenticatedSessionID, leaseID: device.leaseID, username: self.username, password: self.password)
            if device.relay == nil { device.preparingRelay = relay }
            defer {
                if device.preparationGeneration == preparation {
                    device.preparation = nil
                    if device.preparingRelay === relay { device.preparingRelay = nil }
                }
            }
            do {
                _ = try await relay.start()
                guard self.sessions[deviceID] === device, device.preparationGeneration == preparation, !Task.isCancelled else {
                    if device.relay !== relay { relay.stop() }; return
                }
                device.relay = relay; device.preparingRelay = nil
                try await InternetGatewayProbe.verify(relay: relay)
                guard self.sessions[deviceID] === device, device.preparationGeneration == preparation, !Task.isCancelled else { return }
                device.healthy = true; self.updateHealth(); self.scheduleRebuild()
            } catch {
                guard self.sessions[deviceID] === device, device.preparationGeneration == preparation, !Task.isCancelled else {
                    // A newer probe may borrow the same live relay. Stale cleanup must not close it.
                    if device.relay !== relay { relay.stop() }; return
                }
                relay.stop(); if device.relay === relay { device.relay = nil }
                self.fail(deviceID: deviceID, device: device, key: "INTERNET_FAILED")
            }
        }
    }

    /// A replacement never starts until the cancelled predecessor has retired its
    /// helper operation. This serializes real route mutations, not just reply handling.
    private func scheduleRebuild() {
        rebuildRevision += 1
        rebuilding?.cancel()
        if rebuilding == nil { launchRebuild() }
    }
    private func launchRebuild() {
        let revision = rebuildRevision, token = UUID()
        rebuildToken = token
        rebuilding = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.rebuildToken == token {
                    self.rebuilding = nil; self.rebuildToken = nil
                    if self.rebuildRevision != revision { self.launchRebuild() }
                    else { let waiting = self.idleWaiters; self.idleWaiters = []; waiting.forEach { $0.resume() } }
                }
            }
            let snapshot = self.sessions.keys.sorted().compactMap { id -> VerifiedGateway? in
                guard let device = self.sessions[id], device.healthy, let relay = device.relay else { return nil }
                return VerifiedGateway(id: id, device: device, preparation: device.preparationGeneration, relay: relay)
            }
            let fixedPeer = self.knownPeers[self.selection]
            let fixed = self.selection != "automatic" && self.selection != "balanced"
            let desired = fixed && (fixedPeer == nil || !snapshot.contains(where: { $0.device.control.peer.deviceID == fixedPeer })) ? [] : snapshot
            do {
                try Task.checkCancellation()
                if desired.isEmpty { await self.driver.stop() }
                else { try await self.driver.start(gatewayRelays: desired.map(\.relay), userApproved: true) }
                guard self.rebuildRevision == revision, !Task.isCancelled else { return }
                self.updatePolicy(); self.updateHealth()
                guard !desired.isEmpty else {
                    for gateway in snapshot where self.sessions[gateway.id] === gateway.device {
                        self.devices[gateway.id]?.key = "INTERNET_WAITING"
                    }
                    return
                }
                let before = self.driver.totalFlowStarted
                let permittedSlots = self.driver.gatewayDeviceIDs.indices.filter { slot in
                    guard let peer = self.driver.gatewayDeviceIDs[slot] else { return false }
                    return fixedPeer.map { $0 == peer } ?? desired.contains { $0.device.control.peer.deviceID == peer }
                }
                try await InternetGatewayProbe.verifyDefaultRoute()
                guard self.rebuildRevision == revision, !Task.isCancelled else { return }
                let after = self.driver.totalFlowStarted
                guard permittedSlots.contains(where: { $0 < before.count && $0 < after.count && after[$0] > before[$0] }) else {
                    throw URLError(.networkConnectionLost)
                }
                for gateway in desired where self.sessions[gateway.id] === gateway.device &&
                    gateway.device.preparationGeneration == gateway.preparation && gateway.device.healthy {
                    self.devices[gateway.id]?.key = "INTERNET_READY"
                }
            } catch {
                guard self.rebuildRevision == revision, !Task.isCancelled else { return }
                for gateway in desired where self.sessions[gateway.id] === gateway.device && gateway.device.preparationGeneration == gateway.preparation {
                    self.fail(deviceID: gateway.id, device: gateway.device,
                        key: FileManager.default.fileExists(atPath: "/var/run/GalaxyBridgeNetworkHelper.sock") ? "INTERNET_FAILED" : "INTERNET_HELPER_REQUIRED")
                }
            }
        }
    }
    private func updateHealth() {
        let fixed = selection != "automatic" && selection != "balanced"
        let healthy = sessions.values.filter { $0.healthy && (!fixed || $0.control.peer.deviceID == knownPeers[selection]) }
        driver.setHealthyPeers(Set(healthy.map { $0.control.peer.deviceID }))
    }
    private func updatePolicy() {
        if selection == "balanced" { driver.updatePolicy(.balanced) }
        else if selection == "automatic" { driver.updatePolicy(.automatic) }
        else if let peer = knownPeers[selection], let slot = driver.gatewayDeviceIDs.firstIndex(where: { $0 == peer }) { driver.updatePolicy(.fixed(slot)) }
        else {
            // Keep new flows and DNS closed while the selected peer has no slot.
            // A fixed choice must never temporarily fall back to another phone.
            driver.setHealthyPeers([]); driver.updatePolicy(.fixed(0))
        }
        updateHealth()
    }
    func isSelectableGateway(deviceID: String) -> Bool {
        wanted.contains(deviceID) || devices[deviceID]?.enabled == true || (selection == deviceID && knownPeers[deviceID] != nil)
    }
    func forget(deviceID: String) {
        disable(deviceID: deviceID)
        knownPeers.removeValue(forKey: deviceID)
        devices.removeValue(forKey: deviceID)
        if selection == deviceID { selection = "automatic" }
    }
    private func fail(deviceID: String, device: Device, key: String) {
        guard sessions[deviceID] === device else { return }
        disable(deviceID: deviceID); devices[deviceID] = .init(key: key)
    }
    func disable(deviceID: String) {
        wanted.remove(deviceID); removeSession(deviceID: deviceID); devices[deviceID] = .init()
        knownPeers = knownPeers.filter { sessions[$0.key] != nil || wanted.contains($0.key) || selection == $0.key }
    }
    private func removeSession(deviceID: String) {
        if let device = sessions.removeValue(forKey: deviceID) {
            device.preparationGeneration = UUID(); device.preparation?.cancel(); device.timeout?.cancel()
            device.preparingRelay?.stop(); device.preparingRelay = nil; device.relay?.stop(); device.relay = nil
            var request = GBInternetSharingRequest(); request.requestID = UUID().uuidString.lowercased()
            request.leaseID = device.leaseID; request.enabled = false; try? device.control.sendInternetSharing(request)
        }
        updateHealth(); scheduleRebuild()
    }
    func retire(deviceID: String, control: CompanionTLSClient) {
        guard sessions[deviceID]?.control === control else { return }
        removeSession(deviceID: deviceID)
        devices[deviceID] = .init(enabled: wanted.contains(deviceID), key: "INTERNET_WAITING")
    }
    func reconnectIfNeeded(deviceID: String, control: CompanionTLSClient) {
        guard wanted.contains(deviceID), sessions[deviceID] == nil else { return }
        setEnabled(true, deviceID: deviceID, control: control)
    }
    func stop() async {
        for id in Array(wanted.union(sessions.keys)) { disable(deviceID: id) }
        scheduleRebuild()
        if rebuilding != nil { await withCheckedContinuation { idleWaiters.append($0) } }
    }
    func uninstallHelper() async {
        guard !uninstalling else { return }
        uninstalling = true; helperError = nil
        defer { uninstalling = false }
        await stop()
        do { try await driver.uninstallHelper() }
        catch { helperError = "INTERNET_FAILED" }
    }
    func installHelper() {
        let url = Bundle.main.resourceURL?.appendingPathComponent("GalaxyBridge-Network-0.1.2.pkg")
        if let url, FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }
}

/// OS curl provides fresh certificate-validated HTTPS probes. Private loopback
/// credentials travel over stdin; the default-route probe explicitly uses no proxy.
private final class InternetProbeProcessOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        let owned = process
        if owned?.isRunning == true { owned?.terminate() }
        lock.unlock()
    }
    func run(configuration: String) throws {
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        child.arguments = ["--disable", "--config", "-"]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); throw error }
        defer { lock.lock(); if process === child { process = nil }; lock.unlock() }
        try input.fileHandleForWriting.write(contentsOf: Data(configuration.utf8)); try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard child.terminationStatus == 0, bytes.count < 4096,
              String(data: bytes, encoding: .utf8)?.contains("Success") == true else { throw URLError(.networkConnectionLost) }
    }
}
@MainActor private enum InternetGatewayProbe {
    static func verify(relay: PairedInternetRelay) async throws {
        guard let port = relay.localPort else { throw URLError(.networkConnectionLost) }
        try await run(extra: "proxy = \"socks5h://127.0.0.1:\(port)\"\nproxy-user = \"\(relay.username):\(relay.password)\"\n")
    }
    static func verifyDefaultRoute() async throws { try await run(extra: "proxy = \"\"\nnoproxy = \"*\"\n") }
    private static func run(extra: String) async throws {
        let owner = InternetProbeProcessOwner()
        let configuration = "silent\nshow-error\nfail\nhttp1.1\nmax-time = 12\nconnect-timeout = 5\nmax-filesize = 4096\n" + extra +
            "url = \"https://www.apple.com/library/test/success.html\"\n"
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try owner.run(configuration: configuration) }.value
            try Task.checkCancellation()
        } onCancel: { owner.cancel() }
    }
}
#endif
