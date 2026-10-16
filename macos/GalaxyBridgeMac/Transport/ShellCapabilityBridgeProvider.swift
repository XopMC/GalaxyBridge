#if !GALAXYBRIDGE_APP_STORE
import Combine
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import GalaxyBridgeProtocol
import Network

enum ShellCapabilityBridgeFailure: Error { case unavailable, invalidResult, sessionChanged, timeout, operationFailed, capacity }

struct ShellCapabilityBridgeContext: @unchecked Sendable {
    let endpoint: NWEndpoint
    let peer: PairedPeer
    let hostID: String
    let sessionID: String
    let control: CompanionTLSClient
}

@MainActor
final class ShellCapabilityBridgeLease {
    let id: String
    let generation: String
    let context: ShellCapabilityBridgeContext
    let port: UInt16?
    let clipboardPort: UInt16?
    private let relays: [ShellCapabilityBridgeRelay]
    private let log: CompanionTLSClient?
    private let outputObserver: ScrcpyOwnedProcessOutputObserver?
    init(id: String, generation: String, context: ShellCapabilityBridgeContext, relays: [ShellCapabilityBridgeRelay],
         port: UInt16?, clipboardPort: UInt16?, log: CompanionTLSClient?, observer: ScrcpyOwnedProcessOutputObserver?) {
        self.id = id; self.generation = generation; self.context = context; self.relays = relays
        self.port = port; self.clipboardPort = clipboardPort; self.log = log; outputObserver = observer
    }
    func cancelLocal() { relays.forEach { $0.cancel() }; log?.cancel(); outputObserver?.cancel() }
}

/// Root forwards current-generation ShellBridgeResult envelopes to receive().
/// An unknown START is never replayed: its unique lease is stopped explicitly.
@MainActor
final class ShellCapabilityBridgeProvider: ObservableObject {
    @Published private(set) var available = false
    private(set) var bootGeneration: String?
    private let control: () -> CompanionTLSClient?
    private let hostID: String
    private struct Pending {
        let context: ShellCapabilityBridgeContext
        let lease: String
        let generation: String
        let operation: GBShellBridgeRequest.Operation
        let continuation: CheckedContinuation<GBShellBridgeResult, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]
    private var leases: [String: ShellCapabilityBridgeLease] = [:]
    init(hostID: String, control: @escaping () -> CompanionTLSClient?) { self.hostID = hostID; self.control = control }

    private func context() throws -> ShellCapabilityBridgeContext {
        guard let control = control() else { throw ShellCapabilityBridgeFailure.unavailable }
        return ShellCapabilityBridgeContext(endpoint: control.resolvedEndpoint, peer: control.peer,
            hostID: hostID, sessionID: control.authenticatedSessionID, control: control)
    }

    func receive(_ result: GBShellBridgeResult, authenticatedSessionID: String) {
        guard let item = pending[result.requestID], item.context.sessionID == authenticatedSessionID,
              control()?.authenticatedSessionID == authenticatedSessionID,
              result.leaseID == item.lease,
              item.generation.isEmpty || result.bootGeneration == item.generation else { return }
        pending.removeValue(forKey: result.requestID); item.timeout.cancel()
        if result.available && item.operation != .listApplications {
            guard UUID(uuidString: result.bootGeneration)?.uuidString.lowercased() == result.bootGeneration else {
                item.continuation.resume(throwing: ShellCapabilityBridgeFailure.invalidResult); return
            }
            available = true; bootGeneration = result.bootGeneration
        } else if item.operation != .listApplications { available = false; bootGeneration = nil }
        item.continuation.resume(returning: result)
    }

    func disconnected(authenticatedSessionID: String) {
        for (id, item) in pending where item.context.sessionID == authenticatedSessionID {
            pending.removeValue(forKey: id); item.timeout.cancel(); item.continuation.resume(throwing: ShellCapabilityBridgeFailure.sessionChanged)
        }
        for lease in leases.values where lease.context.sessionID == authenticatedSessionID { lease.cancelLocal() }
        available = false
        bootGeneration = nil
    }

    @discardableResult func refresh() async -> Bool {
        do {
            let response = try await perform(operation: .status, lease: "", generation: "", context: context())
            available = response.available && response.errorCode.isEmpty
            return available
        } catch { available = false; bootGeneration = nil; return false }
    }

    func panelPower() async throws -> PhonePanelPowerState {
        let response = try await perform(operation: .status, lease: "", generation: "", context: context())
        guard response.available, response.errorCode.isEmpty else { throw ShellCapabilityBridgeFailure.unavailable }
        switch response.state { case "panel_on": return .on; case "panel_off": return .off; default: return .unknown }
    }

    func fetchApplicationCatalog() async throws -> [ApplicationCatalogItem] {
        let response = try await perform(operation: .listApplications, lease: "", generation: "", context: context())
        let data = response.applicationCatalogJson
        guard response.errorCode.isEmpty, !data.isEmpty, data.count <= 2 * 1024 * 1024 else { throw ShellCapabilityBridgeFailure.invalidResult }
        let manifest = try ApplicationCatalogExportManifest.decode(data, maximumApplications: 512)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        var icons: [String: Data] = [:]
        for row in (raw?["applications"] as? [[String: Any]]) ?? [] {
            guard let package = row["package"] as? String, let encoded = row["icon_png_base64"] as? String,
                  encoded.utf8.count <= 87_384, let bytes = Data(base64Encoded: encoded), bytes.count <= 65_536,
                  bytes.count >= 24, bytes.prefix(8) == Data([137,80,78,71,13,10,26,10]) else { continue }
            let width = bytes[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let height = bytes[20..<24].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if (1...256).contains(width), (1...256).contains(height) { icons[package] = bytes }
        }
        return manifest.applications.map { .init(packageName: $0.packageName, componentName: $0.componentName,
            label: $0.label, iconPNG: icons[$0.packageName], isSystem: $0.isSystem) }
    }

    func prepare(configuration: ScrcpyLaunchConfiguration, operation: GBShellBridgeRequest.Operation = .startScrcpy,
                 outputObserver: ScrcpyOwnedProcessOutputObserver? = nil) async throws -> ShellCapabilityBridgeLease {
        guard leases.count < 8 else { throw ShellCapabilityBridgeFailure.capacity }
        if bootGeneration == nil { guard await refresh() else { throw ShellCapabilityBridgeFailure.unavailable } }
        guard let generation = bootGeneration else { throw ShellCapabilityBridgeFailure.unavailable }
        let context = try context(), id = UUID().uuidString.lowercased()
        var committed = false
        defer {
            if !committed {
                Task { [weak self] in _ = try? await self?.perform(operation: .stop, lease: id, generation: generation, context: context) }
            }
        }
        var options = GBShellCaptureOptions()
        options.scid = configuration.scid; options.maxSize = UInt32(configuration.maxSize); options.maxFps = UInt32(configuration.maxFPS)
        options.videoBitRate = UInt64(configuration.videoBitRate); options.codec = configuration.videoCodec == .h264 ? "h264" : "h265"
        options.audio = configuration.audioEnabled; options.control = true
        switch configuration.captureTarget {
        case let .display(display): options.displayID = display
        case let .virtualDisplay(width, height, _): options.width = UInt32(width); options.height = UInt32(height)
        }
        options.packageName = configuration.applicationTarget?.packageName ?? ""
        let response = try await perform(operation: operation, lease: id, generation: generation, context: context, options: options)
        guard response.available, response.errorCode.isEmpty, response.state == "ready" else { throw ShellCapabilityBridgeFailure.operationFailed }
        let types = operation == .startClipboard ? ["control"] : configuration.audioEnabled ? ["video", "audio", "control"] : ["video", "control"]
        let allowed = Set(types + (operation == .startClipboard ? ["clipboard"] : ["log"]))
        guard Set(response.streamIds) == Set(allowed.map { id + "/" + $0 }), response.streamIds.count == allowed.count else { throw ShellCapabilityBridgeFailure.invalidResult }
        var relays: [ShellCapabilityBridgeRelay] = []
        do {
            let media = try await ShellCapabilityBridgeRelay.start(context: context, leaseID: id, types: types)
            relays.append(media)
            var clipboardPort: UInt16?
            if operation == .startClipboard {
                let clipboard = try await ShellCapabilityBridgeRelay.start(context: context, leaseID: id, types: ["clipboard"])
                relays.append(clipboard); clipboardPort = clipboard.port
            }
            let log: CompanionTLSClient?
            if let outputObserver, operation == .startScrcpy {
                log = CompanionTLSClient(endpoint: context.endpoint, peer: context.peer, hostID: context.hostID,
                    sessionID: context.sessionID, channelKind: .enhancedStream, stateHandler: { state in
                        if case .disconnected = state { outputObserver.cancel() }
                    }, envelopeHandler: { _, _ in }, rawStreamID: id + "/log",
                    rawDataHandler: { data, next in outputObserver.receive(data); next() })
                log?.start()
            } else { log = nil }
            try Task.checkCancellation()
            guard control()?.authenticatedSessionID == context.sessionID else { throw ShellCapabilityBridgeFailure.sessionChanged }
            let lease = ShellCapabilityBridgeLease(id: id, generation: generation, context: context, relays: relays,
                port: media.port, clipboardPort: clipboardPort, log: log, observer: outputObserver)
            leases[id] = lease; committed = true; return lease
        } catch { relays.forEach { $0.cancel() }; throw error }
    }

    func setPanelPower(on: Bool, lease: ShellCapabilityBridgeLease?) async throws -> ShellCapabilityBridgeLease {
        if bootGeneration == nil { guard await refresh() else { throw ShellCapabilityBridgeFailure.unavailable } }
        guard let generation = bootGeneration else { throw ShellCapabilityBridgeFailure.unavailable }
        let context = try context()
        var existing = lease
        if let lease, lease.generation != generation || lease.context.sessionID != context.sessionID {
            try await retire(lease); existing = nil
        }
        let id = existing?.id ?? UUID().uuidString.lowercased()
        var options = GBShellCaptureOptions(); options.scid = UInt32.random(in: 1...0x7fff_ffff); options.codec = "h264"; options.control = true
        let response = try await perform(operation: .startPanel, lease: id, generation: generation, context: context,
            options: options, powerOn: on)
        guard response.available, response.errorCode.isEmpty, response.state == (on ? "panel_on" : "panel_off"), response.streamIds.isEmpty else {
            _ = try? await perform(operation: .stop, lease: id, generation: generation, context: context)
            throw ShellCapabilityBridgeFailure.operationFailed
        }
        let owner = existing ?? ShellCapabilityBridgeLease(id: id, generation: generation, context: context, relays: [], port: nil, clipboardPort: nil, log: nil, observer: nil)
        leases[id] = owner; return owner
    }

    func retire(_ lease: ShellCapabilityBridgeLease) async throws {
        lease.cancelLocal()
        if control()?.authenticatedSessionID != lease.context.sessionID {
            // Old Helper control EOF owns retirement. A read-only exact-lease
            // proof may cross generations; never inherit mutation authority.
            let current = try context()
            let proof = try await perform(operation: .status, lease: lease.id, generation: "", context: current)
            guard proof.available, proof.errorCode.isEmpty, proof.state == "stopped" else { throw ShellCapabilityBridgeFailure.sessionChanged }
            leases.removeValue(forKey: lease.id); return
        }
        let response = try await perform(operation: .stop, lease: lease.id, generation: lease.generation, context: lease.context)
        guard response.available, response.errorCode.isEmpty, response.state == "stopped" else { throw ShellCapabilityBridgeFailure.operationFailed }
        leases.removeValue(forKey: lease.id)
    }

    private func perform(operation: GBShellBridgeRequest.Operation, lease: String, generation: String,
                         context: ShellCapabilityBridgeContext, options: GBShellCaptureOptions? = nil, powerOn: Bool = false) async throws -> GBShellBridgeResult {
        guard control()?.authenticatedSessionID == context.sessionID else { throw ShellCapabilityBridgeFailure.sessionChanged }
        guard pending.count < 32 else { throw ShellCapabilityBridgeFailure.capacity }
        try Task.checkCancellation()
        let id = UUID().uuidString.lowercased()
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let item = self?.pending.removeValue(forKey: id) else { return }
                item.continuation.resume(throwing: ShellCapabilityBridgeFailure.timeout)
            }
            pending[id] = Pending(context: context, lease: lease, generation: generation, operation: operation, continuation: continuation, timeout: timeout)
            var request = GBShellBridgeRequest(); request.requestID = id; request.leaseID = lease; request.bootGeneration = generation
            request.operation = operation; request.powerOn = powerOn
            if let options { request.options = options }
            do { try context.control.sendShellBridge(request) }
            catch { pending.removeValue(forKey: id)?.timeout.cancel(); continuation.resume(throwing: error) }
        }
    }
}
#endif
