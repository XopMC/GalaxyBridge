import Foundation

struct GBDirectLinkStatus { var requestID = ""; var groupLeaseID = ""; var state = ""; var errorCode = "" }
enum NearbyConnectionStatus: Equatable { case connected, failed(String) }
struct Descriptor { let deviceID: String }
struct Admission { func verified(_ generation: UUID) {} }

/// Execute the actual authenticated status branch with inert BLE/Wi-Fi boundaries.
/// The real retirement continuation block is extracted too; no radio is created.
@MainActor final class NearbyStatusFixture {
    final class Session {
        let generation = UUID()
        let deviceID: String?
        var requestID = UUID().uuidString.lowercased()
        var leaseID = UUID().uuidString.lowercased()
        var confirmation: (requestID: String, continuation: CheckedContinuation<Void, Error>, timeout: Task<Void, Never>)?
        var lifetime = NearbyLinkLifetime()
        var descriptor: Descriptor?
        var renewalState: NearbyLeaseRenewalState?
        var deadline: Task<Void, Never>?
        var polling: Task<Void, Never>?
        init(_ id: String) { deviceID = id }
    }
    var sessions: [String: Session] = [:]
    var statuses: [String: NearbyConnectionStatus] = [:]
    var requested = Set<String>()
    var tried: [String: Set<UUID>] = [:]
    var targetDeadlines: [String: Task<Void, Never>] = [:]
    var sharedDescriptor: Descriptor?
    var groupAdmission = Admission()
    var retired: [String] = []
    var confirmationCompletions = 0
    func current(_ session: Session) -> Bool { session.deviceID.map { sessions[$0] === session } == true }
    func update(_ session: Session, _ status: NearbyConnectionStatus) { if let id = session.deviceID { statuses[id] = status } }
    func recordRemoteLeaseDelivery(_ session: Session) {}
    func onDescriptor(_ descriptor: Descriptor) {}
    func startRenewing(_ session: Session) {}
    func drainGroupRequests() {}
    func requestLink(_ session: Session) {}
    func pump() {}
    func add(_ id: String) -> Session { let session = Session(id); sessions[id] = session; return session }
    func retire(_ session: Session, sendRelease: Bool) {
        guard current(session), let id = session.deviceID else { return }
        session.lifetime.retire(); sessions.removeValue(forKey: id); retired.append(id)
        // ACTUAL_CONFIRMATION_RETIREMENT
    }
    // ACTUAL_SESSION_FAILURE
    func deliver(_ status: GBDirectLinkStatus, to session: Session) {
        guard current(session) else { return }
        do { try receive(status, session) }
        catch { fail(session, code: "nearby_authentication_or_frame_failed") }
    }
    private func receive(_ status: GBDirectLinkStatus, _ session: Session) throws {
        // ACTUAL_AUTHENTICATED_STATUS_BRANCH
    }
    func confirm(_ session: Session, requestID: String) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let timeout = Task<Void, Never> { @MainActor in try? await Task.sleep(for: .seconds(60)) }
                    session.confirmation = (requestID, continuation, timeout)
                }
            } catch {}
            confirmationCompletions += 1
        }
    }
}

@main enum NearbyStatusDispatchSpec {
    @MainActor static func main() async {
        let coordinator = NearbyStatusFixture(), a = coordinator.add("A"), b = coordinator.add("B")
        coordinator.requested = ["A", "B"]
        let concurrency = "sta_p2p_concurrency_unverified"
        let rejected = GBDirectLinkStatus(requestID: a.requestID, groupLeaseID: a.leaseID, state: "failed", errorCode: concurrency)
        coordinator.deliver(rejected, to: a)
        precondition(coordinator.statuses["A"] == .failed(concurrency),
            "An authenticated current request failure must retain the phone's bounded reason")
        precondition(coordinator.retired == ["A"] && coordinator.sessions["B"] === b,
            "A rejected direct request must retire only its own phone")
        precondition(coordinator.requested == ["B"],
            "An authenticated rejection must not restart candidate probing and overwrite its reason")

        let stale = GBDirectLinkStatus(requestID: UUID().uuidString.lowercased(), groupLeaseID: b.leaseID, state: "failed", errorCode: concurrency)
        coordinator.deliver(stale, to: b)
        precondition(coordinator.sessions["B"] === b && coordinator.statuses["B"] == nil,
            "A stale request UUID cannot fail the current phone session")

        let confirmationID = UUID().uuidString.lowercased()
        let completion = coordinator.confirm(b, requestID: confirmationID)
        for _ in 0..<20 { await Task.yield() }
        coordinator.deliver(GBDirectLinkStatus(requestID: b.requestID, groupLeaseID: b.leaseID, state: "failed", errorCode: concurrency), to: b)
        precondition(b.confirmation != nil && coordinator.sessions["B"] === b,
            "Once confirmation is pending, the earlier create/poll response is stale")
        let denied = GBDirectLinkStatus(requestID: confirmationID, groupLeaseID: b.leaseID, state: "failed", errorCode: "local_hotspot_permission_failed")
        coordinator.deliver(denied, to: b)
        await completion.value
        coordinator.deliver(denied, to: b)
        precondition(coordinator.statuses["B"] == .failed("local_hotspot_permission_failed") && b.confirmation == nil)
        precondition(coordinator.confirmationCompletions == 1 && coordinator.retired == ["A", "B"],
            "Retirement must resolve a rejected confirmation exactly once, including duplicate receipt delivery")

        let malformed = coordinator.add("malformed")
        coordinator.deliver(GBDirectLinkStatus(requestID: malformed.requestID, groupLeaseID: malformed.leaseID,
            state: "failed", errorCode: "Untrusted message\n" + String(repeating: "x", count: 512)), to: malformed)
        precondition(coordinator.statuses["malformed"] == .failed("nearby_request_failed"),
            "Malformed or unbounded remote text must collapse to a local generic code")
        print("PASS actual nearby status dispatch: bounded peer reasons, current-request fences, per-phone retirement and exactly-once confirmation cleanup")
    }
}
