import Foundation

private enum ScrcpyLaunchConfiguration { static let serverSHA256Hex = String(repeating: "11", count: 32) }
private enum ShellCapabilityBridgeFailure: Error { case invalidResult, sessionChanged, runtimeInUse, capacity, unavailable }
private enum Operation { case status, listApplications, verifyRetirement, startCapture }
private struct GBShellBridgeResult {
    var requestID = "request"
    var leaseID = ""
    var bootGeneration = "11111111-1111-4111-8111-111111111111"
    var available = true
    var errorCode = ""
    var runtimeSha256 = Data()
}
@MainActor private final class Control {
    var authenticatedSessionID = "session"
    var supportsShellRuntimeIdentity = true
}
@MainActor private final class Cancellation { func cancel() {} }
@MainActor private final class Completion {
    var completed = false
    func resume(returning: GBShellBridgeResult) { completed = true }
    func resume(throwing: Error) { completed = true }
}
private struct Context { var sessionID = "session" }
private struct ShellCapabilityBridgeContext {
    let control: Control
    let sessionID: String
}
@MainActor private final class Lease {
    let context = Context()
    var clipboardPort: UInt16?
    func cancelLocal() {}
}
@MainActor private final class Harness {
    enum AbsenceProofSupport { case unknown, supported, legacy, unavailable }
    struct Pending {
        let context = Context()
        var lease = ""
        var generation = ""
        var operation: Operation = .status
        let continuation = Completion()
        let timeout = Cancellation()
    }
    var currentControl = Control()
    func control() -> Control? { currentControl }
    func context() throws -> ShellCapabilityBridgeContext {
        ShellCapabilityBridgeContext(control: currentControl, sessionID: currentControl.authenticatedSessionID)
    }
    var refreshHandler: (() async -> Bool)?
    func refresh() async -> Bool { await refreshHandler?() ?? false }
    var childWrites = 0
    var panelReservations = 0
    // ACTUAL_ADMITTED_REFRESH
    func coldCapturePath() async throws {
        // ACTUAL_COLD_CAPTURE
        childWrites += 1
    }
    func coldPanelPath() async throws {
        // ACTUAL_COLD_PANEL
        panelReservations += 1
    }
    var available = false
    var bootGeneration: String?
    var absenceProofGeneration: String?
    var absenceProofSupport: AbsenceProofSupport = .supported
    var runtimeIdentityGeneration: String?
    var runtimeSHA256Hex: String?
    var runtimeUpgradeInProgress = false
    var pendingLeaseAdmissions = 0
    var runtimeUpgradeRequested: (() -> Void)?
    var pending: [String: Pending] = [:]
    var leases: [String: Lease] = [:]
    // ACTUAL_VERIFIED_RUNTIME
    // ACTUAL_IDENTITY_PREDICATE
    // ACTUAL_RECOVERY_ADMISSION
    // ACTUAL_SAFE_UPGRADE
    // ACTUAL_BEGIN_UPGRADE
    // ACTUAL_END_UPGRADE
    // ACTUAL_NOTIFY_IDLE
    // ACTUAL_RESERVE_ADMISSION
    func admit() throws { try reserveLeaseAdmission() }
    // ACTUAL_RESULT_ADMISSION
    // ACTUAL_DISCONNECT
    func status(_ bytes: Data) {
        pending["request"] = Pending()
        var result = GBShellBridgeResult(); result.runtimeSha256 = bytes
        receive(result, authenticatedSessionID: "session")
    }
}
@main enum ShellRuntimeIdentitySpec {
    @MainActor static func main() async {
        let current = Data(repeating: 0x11, count: 32)
        let older = Data(repeating: 0x22, count: 32)
        do {
            let h = Harness(); h.status(Data())
            precondition(h.needsRuntimeUpgrade,
                "A ready broker with no runtime identity must upgrade when Helper negotiates identity")
            h.status(older); precondition(h.needsRuntimeUpgrade, "Older pinned broker must not hide behind ready status")
            h.status(current); precondition(!h.needsRuntimeUpgrade && h.currentRuntimeVerified)
            h.status(Data(repeating: 0x11, count: 31)); precondition(h.needsRuntimeUpgrade)
            print("PASS missing, older, matching and malformed broker identity")
        }
        do {
            let h = Harness(); h.currentControl.supportsShellRuntimeIdentity = false
            h.status(Data()); precondition(!h.currentRuntimeVerified)
            precondition(!h.needsRuntimeUpgrade, "Legacy Helper compatibility must remain usable")
            h.absenceProofGeneration = h.bootGeneration; h.absenceProofSupport = .legacy
            precondition(h.needsRuntimeUpgrade, "Existing legacy retirement upgrade must remain intact")
            print("PASS old Helper fallback and existing retirement compatibility")
        }
        do {
            let h = Harness(); h.status(current)
            let p = Harness.Pending(); h.pending["request"] = p
            var stale = GBShellBridgeResult(); stale.runtimeSha256 = older
            h.receive(stale, authenticatedSessionID: "retired-session")
            precondition(!p.continuation.completed && !h.needsRuntimeUpgrade)
            stale.leaseID = "another-lease"; h.receive(stale, authenticatedSessionID: "session")
            precondition(!p.continuation.completed && !h.needsRuntimeUpgrade)
            h.pending.removeAll()
            var auxiliary = Harness.Pending(); auxiliary.operation = .verifyRetirement
            h.pending["request"] = auxiliary; stale.leaseID = ""
            h.receive(stale, authenticatedSessionID: "session")
            precondition(!h.needsRuntimeUpgrade, "An auxiliary result cannot replace the status identity")
            h.disconnected(authenticatedSessionID: "session")
            precondition(!h.available && h.runtimeIdentityGeneration == nil && h.runtimeSHA256Hex == nil)
            print("PASS authenticated session, exact lease, status-only admission and disconnect fences")
        }
        for panel in [false, true] {
            for bytes in [Data(), older] {
                let h = Harness(); h.refreshHandler = { h.status(bytes); return true }
                do {
                    if panel { try await h.coldPanelPath() } else { try await h.coldCapturePath() }
                    preconditionFailure("Cold admission must revalidate the stale or missing runtime identity after refresh")
                } catch ShellCapabilityBridgeFailure.runtimeInUse {}
                catch { preconditionFailure("Wrong cold identity rejection") }
                precondition(h.childWrites == 0 && h.panelReservations == 0 && h.pendingLeaseAdmissions == 0)
            }
            for modern in [false, true] {
                let h = Harness(); h.currentControl.supportsShellRuntimeIdentity = modern
                h.refreshHandler = { h.status(modern ? current : Data()); return true }
                if panel { try! await h.coldPanelPath() } else { try! await h.coldCapturePath() }
                precondition(h.childWrites + h.panelReservations == 1 && h.pendingLeaseAdmissions == 0)
            }
            let h = Harness()
            h.refreshHandler = { h.status(current); h.currentControl = Control(); return true }
            do {
                if panel { try await h.coldPanelPath() } else { try await h.coldCapturePath() }
                preconditionFailure("A cold child cannot inherit a replacement control object")
            } catch ShellCapabilityBridgeFailure.sessionChanged {}
            catch { preconditionFailure("Wrong cold context rejection") }
        }
        print("PASS actual cold capture/panel paths: post-refresh positive identity and frozen control before any mutation")
        do {
            let h = Harness(); h.status(older)
            var requests = 0; h.runtimeUpgradeRequested = { requests += 1 }
            do { try h.admit(); preconditionFailure("Known stale runtime admitted a new child") }
            catch ShellCapabilityBridgeFailure.runtimeInUse {}
            catch { preconditionFailure("Wrong stale-runtime admission error") }
            precondition(requests == 1 && h.pendingLeaseAdmissions == 0)
            h.status(current); try! h.admit(); precondition(h.pendingLeaseAdmissions == 1)
            precondition(!h.beginRuntimeUpgrade())
            h.pendingLeaseAdmissions = 0; precondition(h.beginRuntimeUpgrade())
            do { try h.admit(); preconditionFailure("Exclusive upgrade admitted a racing child") }
            catch ShellCapabilityBridgeFailure.runtimeInUse {}
            catch { preconditionFailure("Wrong exclusive-upgrade admission error") }
            h.endRuntimeUpgrade(); h.currentControl.supportsShellRuntimeIdentity = false
            h.status(Data()); try! h.admit(); precondition(h.pendingLeaseAdmissions == 1)
            print("PASS actual child admission rejects stale/current-upgrade races and preserves old Helper compatibility")
        }
        do {
            let h = Harness(); h.status(older); let previous = Lease()
            h.leases["previous-generation"] = previous
            h.disconnected(authenticatedSessionID: "session")
            precondition(!h.available && h.leases["previous-generation"] === previous)
            precondition(h.beginRuntimeUpgrade() && h.canUpgradeRuntimeSafely,
                "A modern unavailable broker needs atomic bootstrap before old exact absence proofs can be obtained")
            precondition(h.leases["previous-generation"] === previous,
                "Bootstrap admission must retain old retirement ownership; it is not absence proof")
            h.endRuntimeUpgrade()
            print("PASS unavailable modern bootstrap keeps old proof handles until exact retirement")
        }
        do {
            let h = Harness(); h.status(older)
            let clipboard = Lease(); clipboard.clipboardPort = 4321
            h.leases["clipboard"] = clipboard
            precondition(!h.canUpgradeRuntimeSafely && h.beginRuntimeUpgrade())
            precondition(h.runtimeUpgradeInProgress && !h.beginRuntimeUpgrade())
            h.leases.removeAll(); precondition(h.canUpgradeRuntimeSafely)
            h.endRuntimeUpgrade(); precondition(!h.runtimeUpgradeInProgress)
            h.pendingLeaseAdmissions = 1; precondition(!h.beginRuntimeUpgrade() && !h.canUpgradeRuntimeSafely)
            h.pendingLeaseAdmissions = 0; h.leases["user-capture"] = Lease()
            precondition(!h.beginRuntimeUpgrade())
            print("PASS exclusive upgrade admission: only own clipboard, pending relays and user owners fenced")
        }
        do {
            let h = Harness(); h.status(older)
            precondition(h.canUpgradeRuntimeSafely)
            h.leases["capture"] = Lease(); precondition(!h.canUpgradeRuntimeSafely)
            h.leases.removeAll(); var p = Harness.Pending(); p.operation = .startCapture
            h.pending["request"] = p; precondition(!h.canUpgradeRuntimeSafely)
            h.pending.removeAll(); precondition(h.canUpgradeRuntimeSafely)
            print("PASS active and pending user owners preserve the existing upgrade barrier")
        }
    }
}
