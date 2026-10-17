#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeCore
import OSLog

typealias DisplayControllerRetirementProof = @MainActor @Sendable (DisplayPowerControllerIdentity, PhonePanelPowerSnapshot) async throws -> Void
typealias DisplayControllerResourceRelease = @MainActor @Sendable (DisplayPowerControllerIdentity, String) async throws -> Void

/// Capture-free, snapshot-owning UID2000 child. EOF and shutdown restore exact
/// panel states; no stock all-ON scrcpy cleanup, brightness or keyguard changes.
@MainActor
final class ScrcpyDisplayPowerSession: PhoneDisplayPowerOwner {
    private static let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "phone-display-privacy")
    var failureHandler: ((String) -> Void)?
    var panelPowerChangedHandler: ((PhonePanelPowerSnapshot) -> Void)?
    private var serial: String
    private let adb: ADBClient
    private var retirementProof: DisplayControllerRetirementProof?
    private var resourceRelease: DisplayControllerResourceRelease?
    private let retirementProofResolver: ((String) -> DisplayControllerRetirementProof?)?
    private let resourceReleaseResolver: ((String) -> DisplayControllerResourceRelease?)?
    private var independentRetirementConfirmed = false
    private var shellProvider: ShellCapabilityBridgeProvider?
    private let shellProviderResolver: ((String) -> ShellCapabilityBridgeProvider?)?
    private var shellLease: ShellCapabilityBridgeLease?
    private var controller: DisplayPowerControllerProcess?
    private var acknowledgement: DisplayPowerControllerAcknowledgement?
    private var startupFailureIdentity: DisplayPowerControllerIdentity?
    private var ownership: PhonePrivacyServerOwnership?
    private var confirmedRestoredFailure = false
    private var restored = false
    private var deliveredInitialSnapshot = false
    private var retriedInitialTransport = false
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var commandRevision: UInt64 = 0
    private var observed: PhonePanelPowerSnapshot?
    private var routeSettlementPending = false

    init(serial: String, adb: ADBClient, shellProvider: ShellCapabilityBridgeProvider? = nil,
         shellProviderResolver: ((String) -> ShellCapabilityBridgeProvider?)? = nil,
         retirementProof: DisplayControllerRetirementProof? = nil,
         resourceRelease: DisplayControllerResourceRelease? = nil,
         retirementProofResolver: ((String) -> DisplayControllerRetirementProof?)? = nil,
         resourceReleaseResolver: ((String) -> DisplayControllerResourceRelease?)? = nil) {
        self.serial = serial; self.adb = adb; self.shellProvider = shellProvider; self.shellProviderResolver = shellProviderResolver
        self.retirementProof = retirementProof; self.resourceRelease = resourceRelease
        self.retirementProofResolver = retirementProofResolver; self.resourceReleaseResolver = resourceReleaseResolver
    }
    func useRoute(serial: String) async throws -> PhoneDisplayPowerRouteChange {
        let next = shellProviderResolver?(serial)
        if routeSettlementPending || serial != self.serial || (next != nil) != (shellProvider != nil) {
            routeSettlementPending = true
            // An alternate ADB serial is already verified as this same phone;
            // use it for the old child's exact cleanup proof if USB disappeared.
            if next == nil, shellProvider == nil { self.serial = serial }
            try await stop()
            self.serial = serial; shellProvider = next
            routeSettlementPending = false
            return .rebased
        }
        return .preserved
    }
    func start() async throws {
        if let shellProvider {
            if shellLease == nil {
                shellLease = try await shellProvider.beginPanelOwnership()
                let state = try await shellProvider.panelPower()
                guard state != .unknown else { throw PowerError.panelNotConfirmed }
                shellLease = try await shellProvider.setPanelPower(on: state == .on, lease: shellLease)
                observed = .remotelyOwned(hasActivePanel: state == .on)
            }
            startMonitor(); return
        }
        if controller != nil, acknowledgement != nil, !restored { return }
        if controller != nil { try await stop() }
        // Freeze callbacks for this raw controller, after the previous backend
        // settled. A Shell-origin owner may now use a newly verified USB route.
        if let retirementProofResolver { retirementProof = retirementProofResolver(serial) }
        if let resourceReleaseResolver { resourceRelease = resourceReleaseResolver(serial) }
        let owned = PhonePrivacyServerOwnership()
        ownership = owned
        do {
            let server = try ScrcpyServerLocator.locate()
            try await Task.detached(priority: .utility) { [adb, serial] in
                try adb.push(serial: serial, localURL: server, remotePath: owned.remoteJarPath)
            }.value
            let input = Pipe(), output = Pipe()
            let process = try adb.launch(serial: serial, arguments: ["shell", "-T", "CLASSPATH=\(owned.remoteJarPath)",
                "app_process", "/", "com.genymobile.scrcpy.DisplayPowerController", "--owner-lease"], inputPipe: input, outputPipe: output)
            // Parent copies must not keep EOF from reaching the remote child.
            try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
            let controller = DisplayPowerControllerProcess(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
            self.controller = controller
            let header = try await controller.exchange(nil)
            acknowledgement = header; observed = header.current; restored = false
            guard try await identityIsCurrent(header.identity) else { throw PowerError.ownerIdentityUnavailable }
            startMonitor()
        } catch {
            if let startup = error as? DisplayPowerControllerAcknowledgement.StartupFailure { startupFailureIdentity = startup.identity }
            Self.logger.error("Display privacy child preparation failed")
            // EOF restores even when the header or an acknowledgement was lost.
            try await stop()
            if case DisplayPowerControllerProcess.ProcessError.controllerTimeout = error, !retriedInitialTransport {
                // One bounded transport retry after both producer readiness
                // signals. Physical-state/topology failures never auto retry.
                retriedInitialTransport = true
                try await start(); return
            }
            throw error
        }
    }
    func snapshot() async throws -> PhonePanelPowerSnapshot {
        if let shellProvider {
            let state = try await shellProvider.panelPower()
            guard state != .unknown else { throw PowerError.panelNotConfirmed }
            return .remotelyOwned(hasActivePanel: state == .on)
        }
        try await start()
        if !deliveredInitialSnapshot, let initial = acknowledgement?.initial {
            deliveredInitialSnapshot = true; return initial
        }
        return try await command(3).current
    }
    func panelPower() async throws -> PhonePanelPowerState { try await snapshot().hasActivePanel ? .on : .off }
    func setPanelPower(on: Bool) async throws {
        commandRevision &+= 1
        if let shellProvider {
            if shellLease == nil { try await start() }
            shellLease = try await shellProvider.setPanelPower(on: on, lease: shellLease)
            let result = try await snapshot()
            guard result.hasActivePanel == on else { throw PowerError.panelNotConfirmed }
            observed = result
        } else {
            try await start()
            let result = try await command(on ? 1 : 0)
            guard result.current.hasActivePanel == on else { throw PowerError.panelNotConfirmed }
            observed = result.current
        }
        startMonitor()
    }
    func restorePanelSnapshot(_ snapshot: PhonePanelPowerSnapshot) async throws {
        monitor?.cancel(); monitor = nil; commandRevision &+= 1
        if let shellProvider {
            if let lease = shellLease { try await shellProvider.retire(lease); shellLease = nil }
            // The trusted remote child restores its private per-panel snapshot.
            observed = snapshot; return
        }
        guard let initial = acknowledgement?.initial, initial == snapshot else { throw PowerError.initialSnapshotChanged }
        if restored { try await finishControllerExit(); observed = initial; return }
        do {
            let response = try await command(2)
            guard response.current == initial else { throw PowerError.panelNotConfirmed }
        } catch {
            // A timed-out stream can no longer correlate ACKs. The pinned
            // child's independent EOF path exits zero only after exact restore.
            try await finishControllerExit()
        }
        restored = true; observed = initial
    }
    func restorePanelPower(on: Bool) async throws {
        guard let initial = acknowledgement?.initial else {
            if shellProvider != nil { try await stop(); return }
            throw PowerError.initialSnapshotChanged
        }
        // Scalar callers cannot override the initial physical mixture.
        try await restorePanelSnapshot(initial)
    }
    func stop() async throws {
        generation = UUID(); monitor?.cancel(); monitor = nil
        if let shellProvider {
            if let lease = shellLease { try await shellProvider.retire(lease); shellLease = nil }
            observed = nil; return
        }
        if controller != nil {
            if let initial = acknowledgement?.initial, !restored { try await restorePanelSnapshot(initial) }
            try await finishControllerExit()
        }
        if let ownership {
            do { _ = try await shell("rm -f '\(ownership.remoteJarPath)'") }
            catch {
                guard let identity = acknowledgement?.identity ?? startupFailureIdentity, let resourceRelease else { throw error }
                try await resourceRelease(identity, ownership.resourceID)
            }
        }
        controller = nil; acknowledgement = nil; startupFailureIdentity = nil; ownership = nil; observed = nil; restored = false; deliveredInitialSnapshot = false; confirmedRestoredFailure = false; independentRetirementConfirmed = false
    }
    private func finishControllerExit() async throws {
        guard let controller else { return }
        if independentRetirementConfirmed { try await controller.retireAfterIndependentProof(); return }
        do {
            try await controller.closeAndWait(confirmedRestoredFailure: confirmedRestoredFailure)
            if let identity = acknowledgement?.identity ?? startupFailureIdentity {
                let deadline = ContinuousClock.now + .seconds(8)
                while try await identityIsCurrent(identity) {
                    guard ContinuousClock.now < deadline else { throw PowerError.cleanupUnsettled }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            let transportFailure = error
            guard let acknowledgement else { throw transportFailure }
            do {
                // A verified Wireless ADB alias can outlive the original USB
                // transport, including with a previous Helper version.
                guard try await !identityIsCurrent(acknowledgement.identity),
                      let current = PhonePanelPowerParser.snapshot(try await shell("dumpsys SurfaceFlinger")),
                      current == acknowledgement.initial else { throw PowerError.panelNotConfirmed }
            } catch {
                guard let retirementProof else { throw transportFailure }
                try await retirementProof(acknowledgement.identity, acknowledgement.initial)
            }
            independentRetirementConfirmed = true
            try await controller.retireAfterIndependentProof()
        }
    }
    private func command(_ byte: UInt8) async throws -> DisplayPowerControllerAcknowledgement {
        guard let controller, let previous = acknowledgement else { throw PowerError.ownerIdentityUnavailable }
        do {
            let response = try await controller.exchange(byte).validating(identity: previous.identity, initial: previous.initial)
            acknowledgement = response
            return response
        } catch let rejection as DisplayPowerControllerAcknowledgement.Rejection {
            let response = try rejection.acknowledgement.validating(identity: previous.identity, initial: previous.initial)
            if rejection.code == "panel_operation_failed_restored", response.current == previous.initial {
                restored = true; confirmedRestoredFailure = true; observed = previous.initial
            }
            throw rejection
        }
    }
    private func identityIsCurrent(_ identity: DisplayPowerControllerIdentity) async throws -> Bool {
        let output = try await shell("if [ -r /proc/\(identity.pid)/stat ]; then cat /proc/\(identity.pid)/stat; else printf 'GONE\\n'; fi")
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "GONE" { return false }
        guard let current = PhonePrivacyCleanupIdentity.parseStat(output), current.pid == identity.pid else { throw PowerError.ownerIdentityUnavailable }
        if String(current.startTime) != identity.startTime { return false }
        guard let closing = output.lastIndex(of: ")"), let state = output[output.index(after: closing)...].split(whereSeparator: \.isWhitespace).first else { throw PowerError.ownerIdentityUnavailable }
        return state != "Z"
    }
    private func shell(_ script: String) async throws -> String {
        let remote = ["sh", "-c", script].map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ")
        return try await Task.detached(priority: .utility) { [adb, serial] in
            try adb.run(arguments: ["-s", serial, "shell", remote], timeout: 6)
        }.value
    }
    private func startMonitor() {
        guard monitor == nil else { return }
        let expectedGeneration = generation
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                    guard let self, self.generation == expectedGeneration else { return }
                    let revision = self.commandRevision, previous = self.observed
                    let current = try await self.snapshot()
                    guard self.generation == expectedGeneration, self.commandRevision == revision, !Task.isCancelled else { continue }
                    self.observed = current
                    if let previous, current != previous { self.panelPowerChangedHandler?(current) }
                } catch is CancellationError { return }
                catch {
                    guard let self, self.generation == expectedGeneration else { return }
                    self.monitor = nil; self.failureHandler?("panel_owner_unavailable"); return
                }
            }
        }
    }
    private enum PowerError: Error { case ownerIdentityUnavailable, initialSnapshotChanged, panelNotConfirmed, cleanupUnsettled }
}
#endif
