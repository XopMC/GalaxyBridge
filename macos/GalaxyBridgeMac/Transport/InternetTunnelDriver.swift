#if !GALAXYBRIDGE_APP_STORE
import Foundation
import Combine
import Network
import Darwin
import CNetworkLease
import CInternetRuntime

enum InternetGatewaySelectionPolicy: Equatable, Sendable {
    case fixed(Int)
    case automatic
    case balanced
}
enum InternetTunnelDriverState: Equatable {
    case idle, starting, running, stopping
    case failed(String)
}

/// Owns one global utun. All payload processing remains in this unprivileged
/// process. Construction is inert; only an explicit approved start contacts the
/// optional root helper. Each relay must already have passed the caller's
/// authenticated gateway probes before it is admitted here.
@MainActor
final class InternetTunnelDriver: ObservableObject {
    @Published private(set) var state: InternetTunnelDriverState = .idle
    @Published private(set) var gatewayDeviceIDs: [String?] = [nil, nil]
    private var relays: [PairedInternetRelay?] = [nil, nil]
    private var ports: [UInt16] = [0, 0]
    private var token = Data()
    private var tunnelFD: Int32 = -1
    private var worker: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var generation = UUID()
    private var relayRevision = UUID()
    private var pendingRelays: [ObjectIdentifier: PairedInternetRelay] = [:]
    private var pendingCreate = false
    private var pendingCreateWaiters: [CheckedContinuation<Void, Never>] = []
    private var policy: InternetGatewaySelectionPolicy = .automatic
    private var healthMask: UInt32 = 3
    private var healthyPeers: Set<String>?
    private var dnsRelay: PairedDNSRelay?
    var totalFlowStarted: [UInt64] {
        var values = [UInt64](repeating: 0, count: 2)
        values.withUnsafeMutableBufferPointer { gb_gateway_pool_total_started($0.baseAddress) }
        return values
    }

    func start(gatewayRelays: [PairedInternetRelay], userApproved: Bool) async throws {
        guard userApproved else { throw DriverError.approvalRequired }
        guard gatewayRelays.count <= 2, Set(gatewayRelays.map { $0.peer.deviceID }).count == gatewayRelays.count else { throw DriverError.invalidGateways }
        if gatewayRelays.isEmpty { await stop(); return }
        let revision = UUID(); relayRevision = revision
        if state == .running {
            var update = request(operation: UInt32(GB_NETWORK_UPDATE_GATEWAYS))
            update.mtu = 1400
            try Self.setAddresses(gatewayRelays, on: &update)
            let result = await Self.helper(HelperInput(request: update))
            guard relayRevision == revision, !Task.isCancelled else { throw CancellationError() }
            guard result.status == 0 else { throw DriverError.helper(result.status) }
            try await reconcileRelays(gatewayRelays, revision: revision)
            return
        }
        guard worker == nil, token.isEmpty, !pendingCreate, state != .stopping, state != .starting else { throw DriverError.retirementIncomplete }
        state = .starting
        let attempt = UUID(); generation = attempt
        do {
            try await reconcileRelays(gatewayRelays, revision: revision)
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            guard let first = relays.compactMap({ $0 }).first else { throw DriverError.invalidGateways }
            let dns = PairedDNSRelay { [weak self] excluded in self?.dnsGateway(excluding: excluded) }
            dnsRelay = dns
            let dnsPort = try await dns.start()
            guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
            var request = GBNetworkRequest()
            request.dns_port = UInt32(dnsPort)
            request.version = UInt32(GB_NETWORK_VERSION); request.operation = UInt32(GB_NETWORK_CREATE)
            request.mtu = 1400; request.flags = UInt32(GB_NETWORK_DEFAULT_ROUTES | GB_NETWORK_DNS | GB_NETWORK_IPV6 | GB_NETWORK_MUTATION_APPROVED)
            request.trial_seconds = 0 // Production sharing: heartbeat governs lifetime.
            try Self.setAddresses(gatewayRelays, on: &request)
            pendingCreate = true
            defer {
                pendingCreate = false
                let waiting = pendingCreateWaiters; pendingCreateWaiters.removeAll()
                for waiter in waiting { waiter.resume() }
            }
            let result = await Self.helper(HelperInput(request: request))
            guard generation == attempt, !Task.isCancelled else {
                let returnedToken = withUnsafeBytes(of: result.reply.token) { Data($0) }
                if returnedToken.contains(where: { $0 != 0 }) {
                    var release = GBNetworkRequest(); release.version = UInt32(GB_NETWORK_VERSION)
                    release.operation = UInt32(GB_NETWORK_RELEASE); release.token = result.reply.token
                    let released = await Self.helper(HelperInput(request: release))
                    if released.status != 0 {
                        token = withUnsafeBytes(of: result.reply.token) { Data($0) }
                        state = .failed("INTERNET_HELPER_RESTORE_FAILED")
                    } else if token.isEmpty, worker == nil { state = .idle }
                }
                if result.fd >= 0 { Darwin.close(result.fd) }
                throw CancellationError()
            }
            guard result.status == 0, result.fd >= 0 else {
                let returnedToken = withUnsafeBytes(of: result.reply.token) { Data($0) }
                if returnedToken.contains(where: { $0 != 0 }) {
                    token = returnedToken
                    let released = await Self.helper(HelperInput(request: self.request(operation: UInt32(GB_NETWORK_RELEASE))))
                    if released.status == 0 { token.removeAll() }
                }
                throw DriverError.helper(result.status)
            }
            // Reserve before publishing a detached worker: STOP must latch even
            // when that worker has not entered the C runtime yet.
            let prepared = gb_internet_tunnel_prepare()
            guard prepared == 0 else {
                Darwin.close(result.fd)
                token = withUnsafeBytes(of: result.reply.token) { Data($0) }
                let released = await Self.helper(HelperInput(request: self.request(operation: UInt32(GB_NETWORK_RELEASE))))
                if released.status == 0 { token.removeAll() }
                throw DriverError.runtime(prepared)
            }
            tunnelFD = result.fd
            token = withUnsafeBytes(of: result.reply.token) { Data($0) }
            let fd = tunnelFD, username = first.username, password = first.password
            state = .running
            worker = Task.detached(priority: .userInitiated) { [weak self] in
                let result = username.withCString { user in password.withCString { pass in
                    gb_internet_tunnel_run(fd, 1, user, pass) // Proxy ports are selected by the per-flow hook.
                } }
                await self?.workerExited(attempt: attempt, result: result, fd: fd)
            }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self, self.generation == attempt, self.state == .running else { return }
                    let reply = await Self.helper(HelperInput(request: self.request(operation: UInt32(GB_NETWORK_HEARTBEAT))))
                    if reply.status != 0 {
                        await self.stop()
                        self.state = .failed("INTERNET_HELPER_CONNECTION_LOST")
                        return
                    }
                }
            }
        } catch {
            guard generation == attempt else { throw error }
            for relay in relays.compactMap({ $0 }) { relay.stop() }
            relays = [nil, nil]; ports = [0, 0]; gatewayDeviceIDs = [nil, nil]
            if token.isEmpty { dnsRelay?.stop(); dnsRelay = nil }
            state = .failed("INTERNET_START_FAILED")
            throw error
        }
    }

    func updatePolicy(_ value: InternetGatewaySelectionPolicy, healthyMask: UInt32? = nil) {
        policy = value
        if let healthyMask { self.healthMask = healthyMask & 3 }
        applyPool()
    }
    func setHealthyPeers(_ ids: Set<String>) {
        healthyPeers = ids
        healthMask = 0
        for index in 0..<2 where gatewayDeviceIDs[index].map(ids.contains) == true { healthMask |= 1 << UInt32(index) }
        applyPool()
        dnsRelay?.setHealthyPeers(ids)
    }

    func stop() async {
        generation = UUID(); relayRevision = UUID()
        heartbeat?.cancel(); heartbeat = nil
        let preparing = Array(pendingRelays.values); pendingRelays.removeAll()
        for relay in preparing { relay.stop() }
        if pendingCreate, token.isEmpty, worker == nil {
            state = .stopping
            await withCheckedContinuation { pendingCreateWaiters.append($0) }
            if token.isEmpty { dnsRelay?.stop(); dnsRelay = nil; state = .idle; return }
        }
        if token.isEmpty, worker == nil {
            for relay in relays.compactMap({ $0 }) { relay.stop() }
            relays = [nil, nil]; ports = [0, 0]; gatewayDeviceIDs = [nil, nil]; dnsRelay?.stop(); dnsRelay = nil; state = .idle; return
        }
        state = .stopping
        _ = gb_internet_tunnel_set_gateways(max(ports[0], 1), ports[1], 0, 1, 0)
        for relay in relays.compactMap({ $0 }) { relay.stop() }
        relays = [nil, nil]
        let retiring = worker
        gb_internet_tunnel_stop()
        var releaseStatus: Int32 = 0
        if !token.isEmpty {
            let result = await Self.helper(HelperInput(request: request(operation: UInt32(GB_NETWORK_RELEASE))))
            releaseStatus = result.status
            if result.status == 0 { token.removeAll() }
        }
        await retiring?.value
        worker = nil; tunnelFD = -1
        if releaseStatus == 0 {
            dnsRelay?.stop(); dnsRelay = nil
            ports = [0, 0]; gatewayDeviceIDs = [nil, nil]; gb_gateway_pool_reset(); state = .idle
        } else { state = .failed("INTERNET_HELPER_RESTORE_FAILED") }
    }

    func uninstallHelper() async throws {
        await stop()
        guard token.isEmpty, worker == nil, !pendingCreate else { throw DriverError.retirementIncomplete }
        var request = GBNetworkRequest(); request.version = UInt32(GB_NETWORK_VERSION)
        request.operation = UInt32(GB_NETWORK_UNINSTALL)
        let result = await Self.helper(HelperInput(request: request))
        guard result.status == 0 else { throw DriverError.helper(result.status) }
    }

    private func reconcileRelays(_ desired: [PairedInternetRelay], revision: UUID) async throws {
        var newlyStarted: [PairedInternetRelay] = []
        var committed = false
        defer {
            for relay in newlyStarted {
                pendingRelays.removeValue(forKey: ObjectIdentifier(relay))
                if !committed { relay.stop() }
            }
        }
        if let first = desired.first {
            guard desired.allSatisfy({ $0.username == first.username && $0.password == first.password }) else { throw DriverError.invalidGateways }
            if let existing = relays.compactMap({ $0 }).first {
                guard existing.username == first.username, existing.password == first.password else { throw DriverError.invalidGateways }
            }
        }
        var next = relays, nextIDs = gatewayDeviceIDs, nextPorts = ports
        let desiredIDs = Set(desired.map { $0.peer.deviceID })
        var rebindMask: UInt32 = 0
        for index in 0..<2 {
            if let id = gatewayDeviceIDs[index], !desiredIDs.contains(id) { next[index] = nil }
        }
        for relay in desired {
            let index: Int
            if let known = nextIDs.firstIndex(where: { $0 == relay.peer.deviceID }) { index = known }
            else if let empty = nextIDs.firstIndex(where: { $0 == nil }) { index = empty; nextIDs[index] = relay.peer.deviceID }
            else {
                var counts = [UInt32](repeating: 0, count: 2)
                counts.withUnsafeMutableBufferPointer { gb_gateway_pool_stats($0.baseAddress) }
                guard let reusable = (0..<2).first(where: { counts[$0] == 0 && !desiredIDs.contains(nextIDs[$0] ?? "") && (relays[$0]?.activeFlowCount ?? 0) == 0 }) else {
                    throw DriverError.retirementIncomplete
                }
                index = reusable; nextIDs[index] = relay.peer.deviceID; rebindMask |= 1 << UInt32(index)
            }
            let wasExisting = relays.contains { $0 === relay }
            if !wasExisting { newlyStarted.append(relay) }
            pendingRelays[ObjectIdentifier(relay)] = relay
            let port: UInt16
            do {
                port = try await relay.start()
                guard relayRevision == revision, !Task.isCancelled else { throw CancellationError() }
            } catch {
                pendingRelays.removeValue(forKey: ObjectIdentifier(relay))
                if !wasExisting { relay.stop() }
                throw error
            }
            if wasExisting { pendingRelays.removeValue(forKey: ObjectIdentifier(relay)) }
            next[index] = relay; nextPorts[index] = port
        }
        var mask: UInt32 = 0
        for index in 0..<2 where next[index] != nil { mask |= 1 << UInt32(index) }
        let selectedHealth: UInt32
        if let healthyPeers {
            selectedHealth = (0..<2).reduce(UInt32(0)) { mask, index in
                nextIDs[index].map(healthyPeers.contains) == true ? mask | (1 << UInt32(index)) : mask
            }
        } else { selectedHealth = healthMask }
        let selection = nativeSelection()
        let result = gb_internet_tunnel_set_gateways_checked(max(nextPorts[0], 1), nextPorts[1], mask & selectedHealth,
            selection.mode, selection.fixed, rebindMask)
        guard result == 0 else { throw DriverError.retirementIncomplete }
        let previous = relays
        relays = next; ports = nextPorts; gatewayDeviceIDs = nextIDs; healthMask = selectedHealth
        committed = true
        for index in 0..<2 {
            if let old = previous[index], next[index] !== old { old.stop() }
        }
    }

    private func applyPool() {
        var mask: UInt32 = 0
        for index in 0..<2 where relays[index] != nil { mask |= 1 << UInt32(index) }
        let selection = nativeSelection()
        _ = gb_internet_tunnel_set_gateways(max(ports[0], 1), ports[1], mask & healthMask, selection.mode, selection.fixed)
    }
    private func nativeSelection() -> (mode: Int32, fixed: Int32) {
        switch policy {
        case let .fixed(index): return (0, Int32(clamping: index))
        case .automatic: return (1, 0)
        case .balanced: return (2, 0)
        }
    }

    private func dnsGateway(excluding: Set<String>) -> PairedInternetRelay? {
        let candidates = (0..<2).filter { index in
            relays[index] != nil && healthMask & (1 << UInt32(index)) != 0 &&
                !excluding.contains(relays[index]!.peer.deviceID)
        }
        switch policy {
        case let .fixed(index): return candidates.contains(index) ? relays[index] : nil
        case .automatic: return candidates.first.flatMap { relays[$0] }
        case .balanced:
            var counts = [UInt32](repeating: 0, count: 2)
            counts.withUnsafeMutableBufferPointer { gb_gateway_pool_stats($0.baseAddress) }
            return candidates.min(by: { counts[$0] < counts[$1] }).flatMap { relays[$0] }
        }
    }

    private func workerExited(attempt: UUID, result: Int32, fd: Int32) async {
        Darwin.close(fd)
        guard generation == attempt else { return }
        tunnelFD = -1; worker = nil
        if state == .running {
            await stop()
            if result != 0 { state = .failed("INTERNET_RUNTIME_FAILED") }
        }
    }
    private func request(operation: UInt32) -> GBNetworkRequest {
        var value = GBNetworkRequest(); value.version = UInt32(GB_NETWORK_VERSION); value.operation = operation
        withUnsafeMutableBytes(of: &value.token) { destination in token.copyBytes(to: destination) }
        return value
    }
    private struct HelperInput: @unchecked Sendable { let request: GBNetworkRequest }
    private struct HelperResult: @unchecked Sendable { var status: Int32; var reply: GBNetworkReply; var fd: Int32 }
    private nonisolated static func helper(_ input: HelperInput) async -> HelperResult {
        await Task.detached(priority: .utility) {
            var reply = GBNetworkReply(); var fd: Int32 = -1
            var request = input.request
            let status = gb_network_helper_request(&request, &reply, &fd)
            return HelperResult(status: status, reply: reply, fd: fd)
        }.value
    }
    private static func setAddresses(_ relays: [PairedInternetRelay], on request: inout GBNetworkRequest) throws {
        let addresses = try relays.compactMap { try gatewayAddress($0.endpoint) }
        request.gateway_count = UInt32(addresses.count)
        withUnsafeMutablePointer(to: &request.gateways) { tuple in
            tuple.withMemoryRebound(to: GBGatewayAddress.self, capacity: 2) { pointer in
                for (index, address) in addresses.enumerated() { pointer[index] = address }
            }
        }
    }
    private static func gatewayAddress(_ endpoint: NWEndpoint) throws -> GBGatewayAddress? {
        guard case let .hostPort(host, _) = endpoint else { throw DriverError.gatewayAddressUnavailable }
        var result = GBGatewayAddress()
        let bytes: Data
        switch host {
        case let .ipv4(address):
            if address.isLoopback { return nil }
            result.family = 4; bytes = address.rawValue
            result.interface_index = UInt32(address.interface?.index ?? 0)
        case let .ipv6(address):
            if address.isLoopback { return nil }
            result.family = 6; bytes = address.rawValue
            result.interface_index = UInt32(address.interface?.index ?? 0)
            // Link-local addresses are ambiguous without the resolved scope.
            guard !address.isLinkLocal || result.interface_index != 0 else { throw DriverError.gatewayAddressUnavailable }
        case .name:
            throw DriverError.gatewayAddressUnavailable
        @unknown default:
            throw DriverError.gatewayAddressUnavailable
        }
        _ = withUnsafeMutableBytes(of: &result.address) { bytes.copyBytes(to: $0) }
        return result
    }
    private enum DriverError: Error { case approvalRequired, invalidGateways, retirementIncomplete, gatewayAddressUnavailable, helper(Int32), runtime(Int32) }
}
#endif
