import Foundation

@main
@MainActor
enum CompanionLifecycleSpec {
    static func main() async throws {
        try legacyLifecycleChecks()
        await terminalAdmissionWhileCleanupHeld()
        await pendingRetryWhileCleanupHeld()
        activeFailureAndStaleRetrySlots()
        try appModelAdmissionWiring()
    }

    private static func legacyLifecycleChecks() throws {
        // Keep the legacy run-loop watchdog checks synchronous. New ordering
        // tests run asynchronously after these complete.
        let notifications = NotificationCenter()
        let expectedPeer = PairedPeer(
            deviceID: "device-under-test",
            displayName: "Galaxy under test",
            identityPublicKey: Data(repeating: 0x11, count: 65),
            tlsCertificateSHA256: Data(repeating: 0x22, count: 32),
            pairedAt: Date(timeIntervalSince1970: 1)
        )
        var bootstrappedPeer: PairedPeer?
        let bootstrap = CompanionConnectionBootstrap(notificationCenter: notifications) { peer in
            bootstrappedPeer = peer
        }

        CompanionLifecycleEvents.pairingStored(expectedPeer, notificationCenter: notifications)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        withExtendedLifetime(bootstrap) {}

        guard bootstrappedPeer == expectedPeer else {
            throw SpecFailure(
                message: "stored pairing must bootstrap the just-persisted peer without waiting for another Bonjour result"
            )
        }
        guard bootstrap.peers(merging: []).contains(expectedPeer) else {
            throw SpecFailure(
                message: "bootstrap must retain the just-persisted peer when the first Keychain enumeration is empty"
            )
        }

        var reconnectRequests: [String] = []
        let watchdog = CompanionConnectingWatchdog(timeout: .milliseconds(20)) { companionID in
            reconnectRequests.append(companionID)
        }
        watchdog.connectionStarted(companionID: "stuck-control")
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        guard reconnectRequests == ["stuck-control"] else {
            throw SpecFailure(
                message: "a control connection stuck in connecting must request a reconnect without app restart"
            )
        }

        watchdog.connectionStarted(companionID: "healthy-control")
        watchdog.connectionSettled(companionID: "healthy-control")
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        guard reconnectRequests == ["stuck-control"] else {
            throw SpecFailure(message: "a normally connected control channel must cancel its connecting watchdog")
        }

        watchdog.connectionStarted(companionID: "revoked-control")
        watchdog.forget(companionID: "revoked-control")
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        guard reconnectRequests == ["stuck-control"] else {
            throw SpecFailure(message: "revoking pairing must cancel the connecting watchdog")
        }

        let recovery = CompanionLogicalSessionRecoverySupervisor()
        let firstGeneration = recovery.beginSession(companionID: "companion-under-test")!
        var recoveryCount = 0
        if recovery.requestRecovery(
            companionID: "companion-under-test",
            generation: firstGeneration
        ) != nil {
            recoveryCount += 1
        }
        if recovery.requestRecovery(
            companionID: "companion-under-test",
            generation: firstGeneration
        ) != nil {
            recoveryCount += 1
        }
        guard recoveryCount == 1 else {
            throw SpecFailure(
                message: "simultaneous secondary-channel failures must schedule one logical-session recovery"
            )
        }

        var staleCallbacksAccepted = 0
        recovery.ifCurrentSession(
            companionID: "companion-under-test",
            generation: firstGeneration
        ) {
            staleCallbacksAccepted += 1
        }
        guard staleCallbacksAccepted == 0 else {
            throw SpecFailure(
                message: "accepting recovery must retire the failed generation before channel cancellation callbacks arrive"
            )
        }

        let replacementGeneration = recovery.beginSession(companionID: "companion-under-test")!
        guard replacementGeneration != firstGeneration else {
            throw SpecFailure(message: "recreating the six-channel bundle must start a fresh generation")
        }
        guard recovery.requestRecovery(
            companionID: "companion-under-test",
            generation: firstGeneration
        ) == nil else {
            throw SpecFailure(message: "a callback from the replaced bundle must not tear down the fresh bundle")
        }

        var capabilityReasons = ["CAPABILITY_SCREEN_CAPTURE": "old_reason"]
        recovery.ifCurrentSession(
            companionID: "companion-under-test",
            generation: firstGeneration
        ) {
            capabilityReasons = ["CAPABILITY_SCREEN_CAPTURE": "stale_callback"]
        }
        recovery.ifCurrentSession(
            companionID: "companion-under-test",
            generation: replacementGeneration
        ) {
            capabilityReasons = [:]
        }
        guard capabilityReasons.isEmpty else {
            throw SpecFailure(
                message: "a fresh events-channel capability update must replace stale unavailable reasons"
            )
        }

        let orchestration = CompanionLogicalSessionRecoverySupervisor()
        let failedGeneration = orchestration.beginSession(companionID: "six-channel-companion")!
        var cancellationCount = 0
        var delayedReconnectCount = 0
        var modelRefreshAllowsReconnect: [Bool] = []
        let accepted = orchestration.recover(
            companionID: "six-channel-companion",
            generation: failedGeneration,
            cancelChannels: [
                { cancellationCount += 1 },
                { cancellationCount += 1 },
                { cancellationCount += 1 },
                { cancellationCount += 1 },
                { cancellationCount += 1 },
                { cancellationCount += 1 },
            ],
            scheduleDelayedReconnect: { _ in delayedReconnectCount += 1 },
            publishModel: { allowsReconnect in
                modelRefreshAllowsReconnect.append(allowsReconnect)
            }
        )
        _ = orchestration.recover(
            companionID: "six-channel-companion",
            generation: failedGeneration,
            cancelChannels: [{ cancellationCount += 100 }],
            scheduleDelayedReconnect: { _ in delayedReconnectCount += 100 },
            publishModel: { modelRefreshAllowsReconnect.append($0) }
        )
        guard accepted,
              cancellationCount == 6,
              delayedReconnectCount == 1,
              modelRefreshAllowsReconnect == [false]
        else {
            throw SpecFailure(
                message: "accepted recovery must cancel six channels once, schedule once, and refresh without reconnecting"
            )
        }

        var postRecoveryCallbacks = 0
        orchestration.ifCurrentSession(
            companionID: "six-channel-companion",
            generation: failedGeneration
        ) {
            postRecoveryCallbacks += 1
        }
        guard postRecoveryCallbacks == 0 else {
            throw SpecFailure(message: "failed-generation callbacks must remain retired during delayed recovery")
        }

        let recreatedGeneration = orchestration.beginSession(companionID: "six-channel-companion")!
        var refreshedReasons = ["CAPABILITY_SCREEN_CAPTURE": "old_reason"]
        orchestration.ifCurrentSession(
            companionID: "six-channel-companion",
            generation: recreatedGeneration
        ) {
            refreshedReasons = [:]
        }
        guard refreshedReasons.isEmpty else {
            throw SpecFailure(message: "the recreated events channel must accept its fresh capability update")
        }
        print("PASS pairing bootstrap and stuck-connecting watchdog recover without restart")
        print("PASS logical Companion bundle recovery is deduplicated and generation-aware")
        print("PASS logical Companion recovery preserves delayed reconnect orchestration")
    }

    private static func terminalAdmissionWhileCleanupHeld() async {
        let supervisor = CompanionLogicalSessionRecoverySupervisor()
        let generation = supervisor.beginSession(companionID: "peer")!
        supervisor.beginApplicationTermination()
        let held = HeldCompanionCleanup()
        let cleanup = Task { await held.wait() }
        await held.waitUntilEntered()
        var cancellations = 0
        var schedules = 0
        var publications = 0
        var starts = 0
        let accepted = supervisor.recover(
            companionID: "peer", generation: generation,
            cancelChannels: [{ cancellations += 1 }],
            scheduleDelayedReconnect: { _ in schedules += 1 },
            publishModel: { _ in publications += 1 }
        )
        for id in ["peer", "queued-topology", "queued-pairing"] {
            if supervisor.beginSession(companionID: id) != nil { starts += 1 }
        }
        precondition(!accepted && cancellations == 0 && schedules == 0 && publications == 0 && starts == 0,
                     "terminal queued callbacks must invoke no recovery closures or bundle starts while cleanup is held")
        precondition(supervisor.currentGeneration(companionID: "peer") == nil)
        supervisor.beginApplicationTermination()
        precondition(supervisor.beginSession(companionID: "peer") == nil, "terminal phase must never reopen")
        held.release()
        await cleanup.value
        let fresh = CompanionLogicalSessionRecoverySupervisor()
        precondition(fresh.beginSession(companionID: "peer") != nil, "fresh app lifecycle must admit connections")
        print("PASS terminal queued recovery/start admission is closed during held cleanup; fresh instance admits")
    }

    private static func pendingRetryWhileCleanupHeld() async {
        let supervisor = CompanionLogicalSessionRecoverySupervisor()
        let generation = supervisor.beginSession(companionID: "peer")!
        var permit: CompanionLogicalSessionRecoverySupervisor.DelayedRetryPermit?
        var taskCancellations = 0
        precondition(supervisor.recover(companionID: "peer", generation: generation, cancelChannels: [],
            scheduleDelayedReconnect: {
                permit = $0
                precondition(supervisor.installDelayedRetry($0, cancel: { taskCancellations += 1 }))
            }, publishModel: { precondition(!$0) }))
        precondition(supervisor.delayedRetryCount == 1)
        supervisor.beginApplicationTermination()
        precondition(taskCancellations == 1 && supervisor.delayedRetryCount == 0,
                     "terminal entry must synchronously cancel and clear existing tasks")
        let held = HeldCompanionCleanup()
        let cleanup = Task { await held.wait() }
        await held.waitUntilEntered()
        var merges = 0
        precondition(!supervisor.performDelayedRetry(permit!) { merges += 1 },
                     "captured delayed work must not run after terminal entry even if cancellation is ignored")
        var rejectedTaskCancellations = 0
        precondition(!supervisor.installDelayedRetry(permit!, cancel: { rejectedTaskCancellations += 1 }))
        precondition(merges == 0 && rejectedTaskCancellations == 1 && supervisor.delayedRetryCount == 0)
        supervisor.beginApplicationTermination()
        precondition(taskCancellations == 1, "terminal entry must not recancel cleared slots")
        held.release()
        await cleanup.value
        print("PASS pending retry permit and task slot are invalidated before held termination cleanup")
    }

    private static func activeFailureAndStaleRetrySlots() {
        let supervisor = CompanionLogicalSessionRecoverySupervisor()
        let a = supervisor.beginSession(companionID: "peer")!
        var cancellations = 0
        var schedules = 0
        var publications: [Bool] = []
        var permitA: CompanionLogicalSessionRecoverySupervisor.DelayedRetryPermit?
        var cancelledA = 0
        precondition(supervisor.recover(companionID: "peer", generation: a,
            cancelChannels: (0..<6).map { _ in { cancellations += 1 } },
            scheduleDelayedReconnect: {
                schedules += 1
                permitA = $0
                precondition(supervisor.installDelayedRetry($0, cancel: { cancelledA += 1 }))
            }, publishModel: { publications.append($0) }))
        for _ in 0..<6 {
            precondition(!supervisor.recover(companionID: "peer", generation: a,
                cancelChannels: [{ cancellations += 100 }],
                scheduleDelayedReconnect: { _ in schedules += 100 }, publishModel: { publications.append($0) }))
        }
        precondition(cancellations == 6 && schedules == 1 && publications == [false])

        let b = supervisor.beginSession(companionID: "peer")!
        precondition(cancelledA == 1 && !supervisor.hasDelayedRetry(companionID: "peer"))
        var merges = 0
        precondition(!supervisor.performDelayedRetry(permitA!) { merges += 1 })
        precondition(supervisor.currentGeneration(companionID: "peer") == b && merges == 0,
                     "delayed A cannot alter current B or start a third bundle")
        let permitB = supervisor.requestRecovery(companionID: "peer", generation: b)!
        var cancelledB = 0
        precondition(supervisor.installDelayedRetry(permitB, cancel: { cancelledB += 1 }))
        var rejectedA = 0
        precondition(!supervisor.installDelayedRetry(permitA!, cancel: { rejectedA += 1 }),
                     "late A installation cannot replace B's retry slot")
        precondition(!supervisor.performDelayedRetry(permitA!) { merges += 1 },
                     "late A consumption cannot delete B's retry slot")
        precondition(supervisor.hasDelayedRetry(companionID: "peer") && supervisor.delayedRetryCount == 1)
        precondition(cancelledB == 0 && rejectedA == 1 && publications == [false] && merges == 0)
        precondition(supervisor.performDelayedRetry(permitB) { merges += 1 })
        precondition(!supervisor.performDelayedRetry(permitB) { merges += 100 })
        precondition(merges == 1 && supervisor.delayedRetryCount == 0,
                     "active retry consumes its exact permit once and clears its own slot")
        supervisor.beginApplicationTermination()
        let fresh = CompanionLogicalSessionRecoverySupervisor()
        let freshGeneration = fresh.beginSession(companionID: "peer")!
        precondition(fresh.requestRecovery(companionID: "peer", generation: freshGeneration) != nil)
        precondition(!fresh.installDelayedRetry(permitB, cancel: {}), "permits cannot cross supervisor instances")
        print("PASS active failure cancels six siblings/schedules/publishes once; stale A cannot delete or replace B slot")
    }

    private static func appModelAdmissionWiring() throws {
        // Source-only integration check: constructing AppModel starts discovery.
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("GalaxyBridgeMac/AppModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let shutdown = source.components(separatedBy: "    func shutdownForApplicationTermination() async {")[1]
            .components(separatedBy: "    func row(id:")[0]
        precondition(shutdown.range(of: "companionRecoverySupervisor.beginApplicationTermination()")!.lowerBound
            < shutdown.range(of: "await ")!.lowerBound)
        precondition(shutdown.range(of: "companionRecoverySupervisor.beginApplicationTermination()")!.lowerBound
            < shutdown.range(of: "connections.cancelAll()")!.lowerBound)
        let connect = source.components(separatedBy: "    private func connectPairedCompanions(")[1]
            .components(separatedBy: "    private func handleCompanionState(")[0]
        let admission = connect.range(of: "guard let generation = companionRecoverySupervisor.beginSession")!.lowerBound
        for allocation in ["MediaPlayoutClock()", "CompanionVideoSession(", "CameraMediaIngress()", "CompanionTLSClient("] {
            precondition(admission < connect.range(of: allocation)!.lowerBound)
        }
        let delayed = source.components(separatedBy: "    private func scheduleCompanionReconnect(")[1]
            .components(separatedBy: "    private func companionDiagnosticSink()")[0]
        precondition(delayed.contains("companionRecoverySupervisor.performDelayedRetry(permit) {\n                mergeDevices()"))
        print("PASS AppModel terminal-before-await/cancel, admitted-before-allocation, and permit-bound merge wiring")
    }
}

@MainActor private final class HeldCompanionCleanup {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered?.resume()
            entered = nil
        }
    }

    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() { continuation?.resume(); continuation = nil }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
