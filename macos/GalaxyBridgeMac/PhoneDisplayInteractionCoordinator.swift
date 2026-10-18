#if !GALAXYBRIDGE_APP_STORE
import Foundation

/// Cancellation may arrive off MainActor while a native snapshot is suspended.
/// Its admission fence must close synchronously, before that snapshot resumes.
final class PhoneDisplayInteractionAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    var isOpen: Bool { lock.withLock { accepting } }
    func close() { lock.withLock { accepting = false } }
}

@MainActor
protocol PhoneDisplayInteractionBackend: AnyObject {
    func beginSnapshot() async throws
    func apply(_ policy: DisplayStateControllerAcknowledgement.PanelPolicy) async throws
    func poll() async throws
    func retire() async throws
}

/// All windows on one phone share logical interactivity independently of the
/// physical-screen preference. Call release only after the producer has stopped.
@MainActor
final class PhoneDisplayInteractionCoordinator {
    typealias Policy = DisplayStateControllerAcknowledgement.PanelPolicy
    enum Failure: Error { case unavailable, cleanupIncomplete }
    private let makeOwner: () throws -> any PhoneDisplayInteractionBackend
    private let heartbeat: (@Sendable () async throws -> Void)?
    private struct Demand {
        let admission: PhoneDisplayInteractionAdmission
        var active: Bool { admission.isOpen }
        var admitted = false
        var ready = false
        var failureDelivered = false
        let onFailure: () -> Void
    }
    private var demands: [UUID: Demand] = [:]
    private var owner: (any PhoneDisplayInteractionBackend)?
    private var snapshotComplete = false
    private var interactive = false
    private var hasPresentedProducer = false
    private var appliedPolicy: Policy?
    private var privacyEnabled = true
    private var failure: Error?
    private var tail: Task<Void, Never>?
    private var tailID: UUID?
    private var heartbeatTask: Task<Void, Never>?
    private var pollRequested = false
    init(makeOwner: @escaping () throws -> any PhoneDisplayInteractionBackend,
         heartbeat: (@Sendable () async throws -> Void)? = { try await Task.sleep(for: .seconds(2)) }) {
        self.makeOwner = makeOwner; self.heartbeat = heartbeat
    }
    func reserve(_ id: UUID, admission: PhoneDisplayInteractionAdmission = .init(), onFailure: @escaping () -> Void = {}) throws {
        guard failure == nil, demands[id] == nil else { throw Failure.unavailable }
        demands[id] = Demand(admission: admission, onFailure: onFailure)
    }
    func prepare(_ id: UUID) async throws {
        guard demands[id]?.active == true else { throw Failure.unavailable }
        enqueue(); await waitForSettlement()
        guard failure == nil, demands[id]?.active == true, demands[id]?.admitted == true else {
            throw failure ?? Failure.unavailable
        }
    }
    func ready(_ id: UUID) {
        guard failure == nil, demands[id]?.active == true, demands[id]?.admitted == true else { return }
        demands[id]?.ready = true; enqueue()
    }
    func cancelAdmission(_ id: UUID) {
        guard demands[id] != nil else { return }
        demands[id]?.admission.close()
        // Keep readiness/ownership until this producer is physically settled.
        enqueue()
    }
    func setPrivacyEnabled(_ enabled: Bool) { privacyEnabled = enabled; enqueue() }
    func poll() async { pollRequested = true; enqueue(); await waitForSettlement() }
    func release(_ id: UUID) async throws {
        demands.removeValue(forKey: id)
        enqueue(); await waitForSettlement()
        guard !demands.isEmpty || owner == nil else { throw Failure.cleanupIncomplete }
    }
    func waitForSettlement() async {
        while let tail { await tail.value }
    }
    private func enqueue() {
        let preceding = tail, ticket = UUID()
        tailID = ticket
        tail = Task { [self] in
            await preceding?.value
            await reconcile()
            if tailID == ticket { tail = nil; tailID = nil }
        }
    }
    private func reconcile() async {
        if demands.isEmpty {
            heartbeatTask?.cancel(); heartbeatTask = nil; pollRequested = false
            guard let owner else { failure = nil; return }
            do {
                try await owner.retire()
                self.owner = nil; snapshotComplete = false; interactive = false
                hasPresentedProducer = false
                appliedPolicy = nil; failure = nil
            } catch { fail(error) }
            return
        }
        guard failure == nil else { return }
        do {
            if owner == nil {
                guard demands.values.contains(where: { $0.active }) else { return }
                owner = try makeOwner()
            }
            guard let owner else { return }
            if !snapshotComplete { try await owner.beginSnapshot(); snapshotComplete = true }
            // Closing during SNAPSHOT keeps cleanup authority, but must not
            // wake a phone for which no producer is still admitted/requested.
            guard interactive || demands.values.contains(where: { $0.active || $0.ready }) else { return }
            if !interactive {
                try await owner.apply(.preserve)
                interactive = true; appliedPolicy = .preserve
            }
            for id in Array(demands.keys) where demands[id]?.active == true { demands[id]?.admitted = true }
            hasPresentedProducer = hasPresentedProducer || demands.values.contains(where: { $0.ready })
            let desired: Policy = hasPresentedProducer ? (privacyEnabled ? .hide : .show) : .preserve
            if appliedPolicy != desired { try await owner.apply(desired); appliedPolicy = desired }
            if pollRequested { pollRequested = false; try await owner.poll() }
            armHeartbeat()
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        failure = error; heartbeatTask?.cancel(); heartbeatTask = nil; pollRequested = false
        var callbacks: [() -> Void] = []
        for id in Array(demands.keys) where demands[id]?.failureDelivered == false {
            if let callback = demands[id]?.onFailure { callbacks.append(callback) }
            demands[id]?.failureDelivered = true
        }
        callbacks.forEach { $0() }
    }
    private func armHeartbeat() {
        guard let heartbeat, heartbeatTask == nil, failure == nil, interactive, !demands.isEmpty else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await heartbeat() } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }
}
#endif
