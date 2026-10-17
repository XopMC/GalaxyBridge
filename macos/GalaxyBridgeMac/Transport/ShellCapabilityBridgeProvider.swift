#if !GALAXYBRIDGE_APP_STORE
import Combine
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import GalaxyBridgeProtocol
import Network
import OSLog

enum ShellCapabilityBridgeFailure: Error, LocalizedError {
    case unavailable, invalidResult, sessionChanged, timeout, operationFailed, capacity, runtimeInUse
    var errorDescription: String? {
        self == .capacity ? String(localized: "APPLICATION_WINDOW_LIMIT")
            : self == .runtimeInUse ? String(localized: "ERROR_RUNTIME_UPGRADE_PENDING") : String(localized: "ERROR_SCREEN_CONNECTION")
    }
}

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
    let diagnosticID = UInt64.random(in: 1...UInt64.max)
    let generation: String
    let context: ShellCapabilityBridgeContext
    let port: UInt16?
    let clipboardPort: UInt16?
    private let relays: [ShellCapabilityBridgeRelay]
    private let log: CompanionTLSClient?
    private let outputObserver: ScrcpyOwnedProcessOutputObserver?
    var displayState: DisplayStateLeaseState?
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
    private let cleanupLogger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "ShellBridgeCleanup")
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
    private enum AbsenceProofSupport { case unknown, supported, legacy, unavailable }
    private var absenceProofSupport: AbsenceProofSupport = .unknown
    private var absenceProofGeneration: String?
    private var runtimeIdentityGeneration: String?
    private var runtimeSHA256Hex: String?
    var supportsCompositeDisplayState: Bool {
        currentRuntimeVerified && control()?.supportsCompositeDisplayState == true
    }
    private(set) lazy var displayInteraction = PhoneDisplayInteractionCoordinator(makeOwner: { [weak self] in
        guard let self else { throw ShellCapabilityBridgeFailure.unavailable }
        return ShellDisplayInteractionBackend(provider: self)
    })
    var currentRuntimeVerified: Bool {
        available && bootGeneration != nil && control()?.supportsShellRuntimeIdentity == true
            && runtimeIdentityGeneration == bootGeneration && runtimeSHA256Hex == ScrcpyLaunchConfiguration.serverSHA256Hex
    }
    var needsRuntimeUpgrade: Bool {
        if absenceProofGeneration == bootGeneration && absenceProofSupport == .legacy { return true }
        guard available, bootGeneration != nil, control()?.supportsShellRuntimeIdentity == true else { return false }
        return !currentRuntimeVerified
    }
    private var runtimeUpgradeInProgress = false
    private var pendingLeaseAdmissions = 0
    var runtimeUpgradeRequested: (() -> Void)?
    /// A new modern broker may bootstrap exact absence proofs for an unavailable
    /// predecessor. Old handles remain retained; only atomic Helper admission
    /// authorizes replacement, never this local availability observation.
    private var canRecoverUnavailableRuntime: Bool { !available && control()?.supportsShellRuntimeIdentity == true }
    var canUpgradeRuntimeSafely: Bool {
        pendingLeaseAdmissions == 0 && (leases.isEmpty || canRecoverUnavailableRuntime) && pending.values.allSatisfy { $0.operation == .status || $0.operation == .listApplications || $0.operation == .verifyRetirement }
    }
    /// Freeze new children before retiring only this Mac's background clipboard.
    /// The Helper independently rejects replacement if any peer still owns work.
    func beginRuntimeUpgrade() -> Bool {
        guard !runtimeUpgradeInProgress, pendingLeaseAdmissions == 0,
              (canRecoverUnavailableRuntime || leases.values.allSatisfy({ $0.clipboardPort != nil })),
              pending.values.allSatisfy({ $0.operation == .status || $0.operation == .listApplications || $0.operation == .verifyRetirement }) else { return false }
        runtimeUpgradeInProgress = true
        return true
    }
    func endRuntimeUpgrade() { runtimeUpgradeInProgress = false }
    private func notifyRuntimeUpgradeIfIdle() {
        guard control()?.supportsShellRuntimeIdentity == true, needsRuntimeUpgrade,
              !runtimeUpgradeInProgress, pendingLeaseAdmissions == 0,
              leases.values.allSatisfy({ $0.clipboardPort != nil }),
              pending.values.allSatisfy({ $0.operation == .status || $0.operation == .listApplications || $0.operation == .verifyRetirement }) else { return }
        runtimeUpgradeRequested?()
    }
    private func reserveLeaseAdmission() throws {
        if control()?.supportsShellRuntimeIdentity == true && needsRuntimeUpgrade {
            notifyRuntimeUpgradeIfIdle()
            throw ShellCapabilityBridgeFailure.runtimeInUse
        }
        guard !runtimeUpgradeInProgress else { throw ShellCapabilityBridgeFailure.runtimeInUse }
        guard leases.count + pendingLeaseAdmissions < 8 else { throw ShellCapabilityBridgeFailure.capacity }
        pendingLeaseAdmissions += 1
    }
    private func refreshAdmittedRuntime(context expected: ShellCapabilityBridgeContext) async throws -> String {
        if !available || bootGeneration == nil {
            guard await refresh() else { throw ShellCapabilityBridgeFailure.unavailable }
        }
        guard control() === expected.control, control()?.authenticatedSessionID == expected.sessionID else {
            throw ShellCapabilityBridgeFailure.sessionChanged
        }
        if control()?.supportsShellRuntimeIdentity == true && !currentRuntimeVerified {
            throw ShellCapabilityBridgeFailure.runtimeInUse
        }
        guard !runtimeUpgradeInProgress, let generation = bootGeneration, available else {
            throw ShellCapabilityBridgeFailure.unavailable
        }
        return generation
    }
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
            if item.operation == .status, result.errorCode.isEmpty {
                runtimeIdentityGeneration = result.bootGeneration
                runtimeSHA256Hex = result.runtimeSha256.count == 32
                    ? result.runtimeSha256.map { String(format: "%02x", $0) }.joined() : nil
            }
        } else if item.operation != .listApplications { available = false; bootGeneration = nil }
        item.continuation.resume(returning: result)
        if item.operation == .status { notifyRuntimeUpgradeIfIdle() }
    }

    func disconnected(authenticatedSessionID: String) {
        for (id, item) in pending where item.context.sessionID == authenticatedSessionID {
            pending.removeValue(forKey: id); item.timeout.cancel(); item.continuation.resume(throwing: ShellCapabilityBridgeFailure.sessionChanged)
        }
        for lease in leases.values where lease.context.sessionID == authenticatedSessionID { lease.cancelLocal() }
        available = false
        bootGeneration = nil
        runtimeIdentityGeneration = nil
        runtimeSHA256Hex = nil
    }

    @discardableResult func refresh() async -> Bool {
        do {
            let response = try await perform(operation: .status, lease: "", generation: "", context: context())
            available = response.available && response.errorCode.isEmpty
            if available && control()?.supportsCaptureRetirementProof == true {
                if absenceProofGeneration != bootGeneration {
                    absenceProofGeneration = bootGeneration
                    absenceProofSupport = .unknown
                }
                if absenceProofSupport == .unknown || absenceProofSupport == .unavailable {
                    await refreshAbsenceProofSupport()
                }
            } else {
                absenceProofGeneration = nil
                absenceProofSupport = .unknown
            }
            return available
        } catch { available = false; bootGeneration = nil; return false }
    }

    private func refreshAbsenceProofSupport() async {
        guard available, let generation = bootGeneration, control()?.supportsCaptureRetirementProof == true else { return }
        do {
            let current = try context()
            let query = GBCaptureRetirementQuery()
            let result = try await perform(operation: .verifyRetirement, lease: "", generation: generation,
                                           context: current, retirement: query)
            guard control()?.authenticatedSessionID == current.sessionID, bootGeneration == generation,
                  result.bootGeneration == generation else { return }
            absenceProofGeneration = generation
            let proof = result.retirementProof
            if result.available, result.errorCode.isEmpty, result.streamIds.isEmpty,
               result.state == "retirement_supported", result.hasRetirementProof,
               proof.supported, !proof.absent, proof.kind == .probeSupport,
               proof.scid == 0, proof.pid == 0, proof.processStartTicks == 0,
               proof.panels.isEmpty, proof.ownedResourceID.isEmpty, !proof.resourceRemoved {
                absenceProofSupport = .supported
            } else if result.available, !result.hasRetirementProof,
                      result.state == "failed", result.errorCode == "shell_operation_failed" {
                absenceProofSupport = .legacy
            } else {
                absenceProofSupport = .unavailable
            }
        } catch {
            // A failed optional probe must not disable an otherwise usable broker.
            if bootGeneration == generation { absenceProofSupport = .unavailable }
        }
    }

    func panelPower() async throws -> PhonePanelPowerState {
        let response = try await perform(operation: .status, lease: "", generation: "", context: context())
        guard response.available, response.errorCode.isEmpty else { throw ShellCapabilityBridgeFailure.unavailable }
        switch response.state {
        case "panel_on", "panel_multi_on": return .on
        case "panel_off", "panel_multi_off": return .off
        default: return .unknown
        }
    }

    /// A typed, read-only proof for a raw ADB owner whose transport disappeared.
    /// Old brokers return panel/lease status and cannot satisfy this response.
    func confirmADBCaptureAbsent(scid: UInt32) async throws {
        guard scid > 0, scid <= 0x7fff_ffff else { throw ShellCapabilityBridgeFailure.invalidResult }
        var query = GBCaptureRetirementQuery()
        query.kind = .scrcpyCapture; query.scid = scid
        let proof = try await verifiedRetirementResult(query)
        guard proof.absent, proof.panels.isEmpty else { throw ShellCapabilityBridgeFailure.operationFailed }
    }

    func confirmDisplayControllerRetired(identity: DisplayPowerControllerIdentity, initial: PhonePanelPowerSnapshot) async throws {
        guard case .physical = initial, initial.isValid else { throw ShellCapabilityBridgeFailure.invalidResult }
        let query = try displayRetirementQuery(identity)
        let proof = try await verifiedRetirementResult(query)
        let observed = try PhonePanelPowerSnapshot(validating: proof.panels.map {
            PhonePhysicalPanelState(id: $0.physicalID, on: $0.on)
        })
        guard initial.isValid, proof.absent, observed == initial else { throw ShellCapabilityBridgeFailure.operationFailed }
    }

    func releaseRetiredControllerResource(identity: DisplayPowerControllerIdentity, resourceID: String) async throws {
        guard UUID(uuidString: resourceID)?.uuidString.lowercased() == resourceID else {
            throw ShellCapabilityBridgeFailure.invalidResult
        }
        var query = try displayRetirementQuery(identity)
        query.ownedResourceID = resourceID
        let digest = Array(ScrcpyLaunchConfiguration.serverSHA256Hex.utf8)
        guard digest.count == 64 else { throw ShellCapabilityBridgeFailure.invalidResult }
        var bytes = Data()
        for offset in stride(from: 0, to: digest.count, by: 2) {
            guard let byte = UInt8(String(decoding: digest[offset..<offset + 2], as: UTF8.self), radix: 16) else {
                throw ShellCapabilityBridgeFailure.invalidResult
            }
            bytes.append(byte)
        }
        query.resourceSha256 = bytes
        let proof = try await verifiedRetirementResult(query, operation: .releaseRetiredResource)
        guard proof.absent, proof.resourceRemoved, proof.panels.isEmpty else {
            throw ShellCapabilityBridgeFailure.operationFailed
        }
    }

    private func displayRetirementQuery(_ identity: DisplayPowerControllerIdentity) throws -> GBCaptureRetirementQuery {
        guard identity.pid > 1, let ticks = UInt64(identity.startTime), ticks > 0,
              ticks <= UInt64(Int64.max), String(ticks) == identity.startTime else {
            throw ShellCapabilityBridgeFailure.invalidResult
        }
        var query = GBCaptureRetirementQuery()
        query.kind = .displayPowerController; query.pid = UInt32(identity.pid); query.processStartTicks = ticks
        return query
    }

    private func verifiedRetirementResult(_ query: GBCaptureRetirementQuery,
        operation: GBShellBridgeRequest.Operation = .verifyRetirement) async throws -> GBCaptureRetirementProof {
        guard available, let generation = bootGeneration, control()?.supportsCaptureRetirementProof == true else {
            throw ShellCapabilityBridgeFailure.unavailable
        }
        let context = try context()
        let result = try await perform(operation: operation, lease: "", generation: generation,
                                       context: context, retirement: query)
        let proof = result.retirementProof
        let expectedState = operation == .releaseRetiredResource ? "resources_released" : "retired"
        guard control()?.authenticatedSessionID == context.sessionID,
              bootGeneration == generation, result.bootGeneration == generation,
              result.available, result.errorCode.isEmpty, result.streamIds.isEmpty,
              result.state == expectedState, result.hasRetirementProof, proof.supported,
              proof.kind == query.kind, proof.scid == query.scid, proof.pid == query.pid,
              proof.processStartTicks == query.processStartTicks,
              proof.ownedResourceID == query.ownedResourceID,
              proof.resourceRemoved == (operation == .releaseRetiredResource) else {
            throw ShellCapabilityBridgeFailure.operationFailed
        }
        return proof
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
        let context = try context()
        try reserveLeaseAdmission()
        defer { pendingLeaseAdmissions -= 1; notifyRuntimeUpgradeIfIdle() }
        let generation = try await refreshAdmittedRuntime(context: context)
        let id = UUID().uuidString.lowercased()
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

    func beginPanelOwnership() async throws -> ShellCapabilityBridgeLease {
        let context = try context()
        try reserveLeaseAdmission()
        defer { pendingLeaseAdmissions -= 1; notifyRuntimeUpgradeIfIdle() }
        let generation = try await refreshAdmittedRuntime(context: context)
        let owner = ShellCapabilityBridgeLease(id: UUID().uuidString.lowercased(), generation: generation, context: context,
            relays: [], port: nil, clipboardPort: nil, log: nil, observer: nil)
        // Reserve before sending a mutating request. Unknown outcomes retain an
        // exact retirement handle instead of losing an unacknowledged child.
        leases[owner.id] = owner
        return owner
    }

    func setPanelPower(on: Bool, lease: ShellCapabilityBridgeLease?) async throws -> ShellCapabilityBridgeLease {
        if bootGeneration == nil { guard await refresh() else { throw ShellCapabilityBridgeFailure.unavailable } }
        guard let generation = bootGeneration else { throw ShellCapabilityBridgeFailure.unavailable }
        let context = try context()
        guard let existing = lease, leases[existing.id] === existing,
              existing.generation == generation, existing.context.sessionID == context.sessionID else {
            // Replacing a panel context must settle its exact preceding owner
            // first; never create an unreturned mutating lease after reconnect.
            throw ShellCapabilityBridgeFailure.sessionChanged
        }
        let id = existing.id
        var options = GBShellCaptureOptions(); options.scid = UInt32.random(in: 1...0x7fff_ffff); options.codec = "h264"; options.control = true
        let response = try await perform(operation: .startPanel, lease: id, generation: generation, context: context,
            options: options, powerOn: on)
        guard response.available, response.errorCode.isEmpty, [on ? "panel_on" : "panel_off", on ? "panel_multi_on" : "panel_multi_off"].contains(response.state), response.streamIds.isEmpty else {
            _ = try? await perform(operation: .stop, lease: id, generation: generation, context: context)
            throw ShellCapabilityBridgeFailure.operationFailed
        }
        return existing
    }

    func retire(_ lease: ShellCapabilityBridgeLease) async throws {
        if lease.displayState != nil { try await retireDisplayState(lease); return }
        lease.cancelLocal()
        if control()?.authenticatedSessionID != lease.context.sessionID {
            // Old Helper control EOF owns retirement. A read-only exact-lease
            // proof may cross generations; never inherit mutation authority.
            let current = try context()
            let proof = try await perform(operation: .status, lease: lease.id, generation: "", context: current)
            guard proof.available, proof.errorCode.isEmpty, proof.state == "stopped" else {
                reportUnconfirmedRetirement(lease, stage: .previousSession, result: proof)
                throw ShellCapabilityBridgeFailure.sessionChanged
            }
            leases.removeValue(forKey: lease.id); notifyRuntimeUpgradeIfIdle(); return
        }
        do {
            let response = try await perform(operation: .stop, lease: lease.id, generation: lease.generation, context: lease.context)
            guard response.available, response.errorCode.isEmpty, response.state == "stopped" else {
                reportUnconfirmedRetirement(lease, stage: .stop, result: response)
                throw ShellCapabilityBridgeFailure.operationFailed
            }
        } catch {
            let reason = MediaFailureDiagnostics.reason(error)
            cleanupLogger.notice("shell_stop_retry owner=\(lease.diagnosticID, privacy: .public) reason=\(reason, privacy: .public)")
            let proof = try await perform(operation: .status, lease: lease.id, generation: "", context: lease.context)
            guard proof.available, proof.errorCode.isEmpty, proof.state == "stopped" else {
                reportUnconfirmedRetirement(lease, stage: .status, result: proof)
                throw ShellCapabilityBridgeFailure.operationFailed
            }
        }
        leases.removeValue(forKey: lease.id)
        notifyRuntimeUpgradeIfIdle()
    }

    /// Reserve a locally retained handle before the first remote SNAPSHOT.
    func beginDisplayStateOwnership() async throws -> ShellCapabilityBridgeLease {
        guard control()?.supportsCompositeDisplayState == true else { throw ShellCapabilityBridgeFailure.unavailable }
        let lease = try await beginPanelOwnership()
        lease.displayState = DisplayStateLeaseState()
        do { try validateDisplayStateAdmission(lease) }
        catch {
            // No remote command has been sent; this local reservation owns no
            // child. Once returned, the caller must retain it through cleanup.
            leases.removeValue(forKey: lease.id); notifyRuntimeUpgradeIfIdle(); throw error
        }
        return lease
    }
    func snapshotDisplayState(_ lease: ShellCapabilityBridgeLease) async throws {
        do {
            try validateDisplayStateAdmission(lease)
            guard lease.displayState?.header == nil, lease.displayState?.mayHaveMutated == false,
                  lease.displayState?.snapshotDispatched == false else {
                throw ShellCapabilityBridgeFailure.invalidResult
            }
            let response = try await perform(operation: .startDisplayState, lease: lease.id, generation: lease.generation,
                context: lease.context, displayState: GBDisplayStateCommand(), beforeDispatch: {
                    try self.validateDisplayStateAdmission(lease)
                    guard lease.displayState?.snapshotDispatched == false else { throw ShellCapabilityBridgeFailure.invalidResult }
                }, didDispatch: { lease.displayState?.markSnapshotDispatched() })
            guard response.available, response.errorCode.isEmpty, response.bootGeneration == lease.generation,
                  response.state == "display_state_snapshotted", response.streamIds.isEmpty else {
                throw ShellCapabilityBridgeFailure.operationFailed
            }
            // Retain the immutable baseline even if cancellation raced the
            // reply. Admission is rechecked only after retaining that evidence.
            try lease.displayState!.acceptSnapshot(DisplayStateControllerAcknowledgement.decode(response.displayStateAcknowledgement))
            try validateDisplayStateAdmission(lease)
        } catch { lease.displayState?.beginDraining(); throw error }
    }
    func applyDisplayState(_ lease: ShellCapabilityBridgeLease,
                           policy: DisplayStateControllerAcknowledgement.PanelPolicy) async throws {
        do {
            try validateDisplayStateAdmission(lease)
            let revision = try lease.displayState!.beginPolicy()
            var command = GBDisplayStateCommand()
            command.action = .apply; command.interactive = true; command.revision = revision
            switch policy { case .preserve: command.panelPolicy = .preserve
            case .hide: command.panelPolicy = .hide
            case .show: command.panelPolicy = .show }
            let response = try await perform(operation: .startDisplayState, lease: lease.id, generation: lease.generation,
                context: lease.context, displayState: command)
            guard response.available, response.errorCode.isEmpty, response.bootGeneration == lease.generation,
                  response.state == "display_state_reply", response.streamIds.isEmpty else {
                throw ShellCapabilityBridgeFailure.operationFailed
            }
            try lease.displayState!.acceptPolicy(DisplayStateControllerAcknowledgement.decode(response.displayStateAcknowledgement),
                                                 revision: revision, policy: policy)
            try validateDisplayStateAdmission(lease)
        } catch { lease.displayState?.beginDraining(); throw error }
    }
    private func validateDisplayStateAdmission(_ lease: ShellCapabilityBridgeLease) throws {
        try Task.checkCancellation()
        guard leases[lease.id] === lease, control() === lease.context.control,
              control()?.authenticatedSessionID == lease.context.sessionID, bootGeneration == lease.generation else {
            throw ShellCapabilityBridgeFailure.sessionChanged
        }
        guard available, currentRuntimeVerified, control()?.supportsCompositeDisplayState == true,
              let state = lease.displayState, !state.draining, !state.retired else {
            throw ShellCapabilityBridgeFailure.unavailable
        }
    }
    func pollDisplayState(_ lease: ShellCapabilityBridgeLease) async throws {
        do {
            try validateDisplayStateAdmission(lease)
            guard let state = lease.displayState, state.lastConfirmedRevision > 0, state.pendingRevision == nil else {
                throw ShellCapabilityBridgeFailure.invalidResult
            }
            var command = GBDisplayStateCommand(); command.action = .status
            let response = try await perform(operation: .startDisplayState, lease: lease.id, generation: lease.generation,
                context: lease.context, displayState: command)
            guard response.available, response.errorCode.isEmpty, response.bootGeneration == lease.generation,
                  response.state == "display_state_reply", response.streamIds.isEmpty else {
                throw ShellCapabilityBridgeFailure.operationFailed
            }
            try lease.displayState!.validateStatus(DisplayStateControllerAcknowledgement.decode(response.displayStateAcknowledgement))
            try validateDisplayStateAdmission(lease)
        } catch { lease.displayState?.beginDraining(); throw error }
    }
    /// Separate v2 retirement never uses the legacy stopped/status fallback.
    private func retireDisplayState(_ lease: ShellCapabilityBridgeLease) async throws {
        if lease.displayState?.retired == true { return }
        guard leases[lease.id] === lease, lease.displayState != nil else {
            throw ShellCapabilityBridgeFailure.invalidResult
        }
        lease.displayState!.beginDraining()
        if lease.displayState?.snapshotDispatched == false {
            try lease.displayState!.confirmNeverDispatched()
            leases.removeValue(forKey: lease.id); notifyRuntimeUpgradeIfIdle(); return
        }
        let proof: GBCaptureRetirementProof
        if control()?.authenticatedSessionID == lease.context.sessionID, bootGeneration == lease.generation {
            let response = try await perform(operation: .stop, lease: lease.id, generation: lease.generation, context: lease.context)
            guard response.available, response.errorCode.isEmpty, response.bootGeneration == lease.generation,
                  response.streamIds.isEmpty else { throw ShellCapabilityBridgeFailure.operationFailed }
            if response.state == "display_state_not_started" {
                guard !response.hasRetirementProof else { throw ShellCapabilityBridgeFailure.invalidResult }
                if !response.displayStateAcknowledgement.isEmpty {
                    let failed = try DisplayStateControllerAcknowledgement.decode(response.displayStateAcknowledgement)
                    guard failed.event == .startupFailed else { throw ShellCapabilityBridgeFailure.invalidResult }
                }
                try lease.displayState!.confirmNotStarted()
                leases.removeValue(forKey: lease.id); notifyRuntimeUpgradeIfIdle(); return
            }
            guard response.state == "display_state_retired", response.hasRetirementProof else {
                throw ShellCapabilityBridgeFailure.operationFailed
            }
            proof = response.retirementProof
        } else {
            // A new authenticated session may observe the exact frozen child,
            // but never inherits the preceding session's mutation authority.
            guard let identity = lease.displayState?.header?.identity else {
                throw ShellCapabilityBridgeFailure.sessionChanged
            }
            var query = GBCaptureRetirementQuery()
            query.kind = .displayStateController; query.pid = UInt32(identity.pid); query.processStartTicks = identity.startTicks
            proof = try await verifiedRetirementResult(query)
        }
        guard proof.pid <= UInt32(Int32.max) else { throw ShellCapabilityBridgeFailure.invalidResult }
        let evidence = DisplayStateRetirementEvidence(kind: proof.kind.rawValue, scid: proof.scid,
            identity: .init(pid: Int32(proof.pid), startTicks: proof.processStartTicks),
            supported: proof.supported, absent: proof.absent, legacyPanelCount: proof.panels.count,
            ownedResourceID: proof.ownedResourceID, resourceRemoved: proof.resourceRemoved,
            snapshotData: proof.displayStateSnapshot, terminalAcknowledgement: proof.displayStateTerminalAcknowledgement)
        _ = try lease.displayState!.confirmRetirement(evidence)
        leases.removeValue(forKey: lease.id); notifyRuntimeUpgradeIfIdle()
    }

    private enum RetirementDiagnosticStage: String { case previousSession = "previous_session", stop, status }
    private func reportUnconfirmedRetirement(_ lease: ShellCapabilityBridgeLease, stage: RetirementDiagnosticStage,
                                            result: GBShellBridgeResult) {
        let metadata = MediaFailureDiagnostics.stopResult(available: result.available, state: result.state,
            errorCode: result.errorCode, streams: result.streamIds.count)
        cleanupLogger.notice("shell_stop_unconfirmed owner=\(lease.diagnosticID, privacy: .public) stage=\(stage.rawValue, privacy: .public) \(metadata, privacy: .public)")
    }

    private func perform(operation: GBShellBridgeRequest.Operation, lease: String, generation: String,
                         context: ShellCapabilityBridgeContext, options: GBShellCaptureOptions? = nil, powerOn: Bool = false,
                         retirement: GBCaptureRetirementQuery? = nil,
                         displayState: GBDisplayStateCommand? = nil,
                         beforeDispatch: (() throws -> Void)? = nil, didDispatch: (() -> Void)? = nil) async throws -> GBShellBridgeResult {
        guard control()?.authenticatedSessionID == context.sessionID else { throw ShellCapabilityBridgeFailure.sessionChanged }
        guard pending.count < 32 else { throw ShellCapabilityBridgeFailure.capacity }
        try Task.checkCancellation()
        let timeoutSeconds = operation == .startDisplayState || leases[lease]?.displayState != nil
            || retirement?.kind == .displayStateController ? 25 : 10
        let id = UUID().uuidString.lowercased()
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                guard let item = self?.pending.removeValue(forKey: id) else { return }
                item.continuation.resume(throwing: ShellCapabilityBridgeFailure.timeout)
            }
            pending[id] = Pending(context: context, lease: lease, generation: generation, operation: operation, continuation: continuation, timeout: timeout)
            var request = GBShellBridgeRequest(); request.requestID = id; request.leaseID = lease; request.bootGeneration = generation
            request.operation = operation; request.powerOn = powerOn
            if let options { request.options = options }
            if let retirement { request.retirement = retirement }
            if let displayState { request.displayState = displayState }
            do {
                try beforeDispatch?()
                try context.control.sendShellBridge(request)
                // sendShellBridge only throws synchronously before queueing
                // NWConnection.send. Later transport errors remain uncertain.
                didDispatch?()
            }
            catch { pending.removeValue(forKey: id)?.timeout.cancel(); continuation.resume(throwing: error) }
        }
    }
}
#endif
