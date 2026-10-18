import Foundation

@MainActor final class InteractionBackend: PhoneDisplayInteractionBackend {
    typealias Policy = DisplayStateControllerAcknowledgement.PanelPolicy
    var events: [String] = []
    var snapshotBarrier: CheckedContinuation<Void, Never>?
    var holdSnapshot = false
    var failApply = false
    var failPoll = false
    var failRetirement = false
    var onSnapshot: (() -> Void)?
    func beginSnapshot() async throws {
        events.append("snapshot")
        onSnapshot?()
        if holdSnapshot { await withCheckedContinuation { snapshotBarrier = $0 } }
    }
    func apply(_ policy: Policy) async throws {
        events.append(policy == .preserve ? "interactive" : policy == .hide ? "hide" : "show")
        if failApply { throw PhoneDisplayInteractionCoordinator.Failure.unavailable }
    }
    func poll() async throws {
        events.append("poll")
        if failPoll { throw PhoneDisplayInteractionCoordinator.Failure.unavailable }
    }
    func retire() async throws {
        events.append("retire")
        if failRetirement { throw PhoneDisplayInteractionCoordinator.Failure.cleanupIncomplete }
    }
}

@main enum PhoneDisplayInteractionSpec {
    enum Failure: Error { case expectation(String) }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.expectation(message) }
    }
    @MainActor static func run() async throws {
        do {
            let backend = InteractionBackend(); backend.failApply = true
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            var failures = 0
            let initial = try ScrcpyDisplayInteractionLease(coordinator: coordinator, onFailure: { failures += 1 })
            var rejected = false; do { try await initial.prepare() } catch { rejected = true }
            try require(rejected && failures == 0, "Initial prepare failure stays with its awaiting caller, before producer admission")
            try await initial.retire(producerPhysicallySettled: true)
            backend.failApply = false
            let active = try ScrcpyDisplayInteractionLease(coordinator: coordinator, onFailure: { failures += 1 })
            try await active.prepare(); backend.failPoll = true
            await coordinator.poll(); await coordinator.poll()
            try require(failures == 1, "A running producer receives one owner-failure callback")
            try await active.retire(producerPhysicallySettled: true)
        }
        do {
            let backend = InteractionBackend(); backend.holdSnapshot = true
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            let lease = try ScrcpyDisplayInteractionLease(coordinator: coordinator)
            let preparation = Task { @MainActor in
                do { try await lease.prepare(); return false }
                catch is CancellationError { return true }
                catch { return false }
            }
            for _ in 0..<1000 {
                if backend.snapshotBarrier != nil { break }
                await Task.yield()
            }
            try require(backend.snapshotBarrier != nil, "Handle cancellation test must reach a suspended native SNAPSHOT")
            preparation.cancel()
            backend.snapshotBarrier?.resume(); backend.snapshotBarrier = nil
            try require(await preparation.value, "Prepare must preserve Task cancellation classification")
            try require(backend.events == ["snapshot"] && !lease.admitted,
                        "Cancelling prepare during SNAPSHOT must close admission before the first APPLY")
            try await lease.retire(producerPhysicallySettled: true)
            try require(backend.events == ["snapshot", "retire"], "Read-only startup still settles its exact child")
        }
        do {
            let backend = InteractionBackend()
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            let lease = try ScrcpyDisplayInteractionLease(coordinator: coordinator)
            try await lease.prepare(); try require(lease.admitted, "The producer waits for interactive readiness")
            lease.ready(); await coordinator.waitForSettlement()
            var rejected = false
            do { try await lease.retire(producerPhysicallySettled: false) } catch { rejected = true }
            try require(rejected && lease.cancelled && !lease.retired && !backend.events.contains("retire"),
                        "An unsettled producer closes admission but cannot release its logical owner")
            await coordinator.poll()
            try require(backend.events.last == "poll", "Physical producer cleanup retains renewal even after admission closes")
            lease.ready(); await coordinator.waitForSettlement()
            try await lease.retire(producerPhysicallySettled: true)
            try require(lease.retired && backend.events.last == "retire", "The exact physical barrier permits final owner retirement")
            let count = backend.events.count
            try await lease.retire(producerPhysicallySettled: true)
            try require(backend.events.count == count, "Repeated cleanup cannot recreate or re-retire an owner")
        }
        do {
            let backend = InteractionBackend(); backend.holdSnapshot = true
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            let first = UUID(), second = UUID(); try coordinator.reserve(first)
            let initial = Task { @MainActor in
                do { try await coordinator.prepare(first); return true } catch { return false }
            }
            for _ in 0..<1000 {
                if backend.snapshotBarrier != nil { break }
                await Task.yield()
            }
            try require(backend.snapshotBarrier != nil, "Test must actually reach a suspended native startup")
            try coordinator.reserve(second)
            let additional = Task { @MainActor in try await coordinator.prepare(second) }
            coordinator.cancelAdmission(first)
            let closing = Task { @MainActor in try await coordinator.release(first) }
            backend.snapshotBarrier?.resume(); backend.snapshotBarrier = nil
            try require(await initial.value == false, "Cancelled admission cannot borrow a later window's success")
            try await additional.value; try await closing.value
            try require(backend.events == ["snapshot", "interactive"],
                        "Overlapping pending startup, cancellation and release keep one baseline and no premature retirement")
            coordinator.cancelAdmission(second); try await coordinator.release(second)
        }
        do {
            let backend = InteractionBackend()
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            let id = UUID(); try coordinator.reserve(id); try await coordinator.prepare(id)
            coordinator.cancelAdmission(id); await coordinator.poll()
            try require(backend.events.last == "poll" && !backend.events.contains("retire"),
                        "An admitted producer still settling before its first frame keeps STATUS renewal until physical release")
            try await coordinator.release(id)
        }
        do {
            let backend = InteractionBackend(); var factoryFails = true
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: {
                if factoryFails { throw PhoneDisplayInteractionCoordinator.Failure.unavailable }
                return backend
            }, heartbeat: nil)
            let id = UUID(); try coordinator.reserve(id)
            var failed = false; do { try await coordinator.prepare(id) } catch { failed = true }
            try require(failed, "Factory failure must reject initial admission")
            try await coordinator.release(id)
            factoryFails = false
            let retry = UUID(); try coordinator.reserve(retry); try await coordinator.prepare(retry)
            coordinator.cancelAdmission(retry); try await coordinator.release(retry)
            try require(backend.events == ["snapshot", "interactive", "retire"],
                        "A failed factory with no allocated child must not permanently fence the phone")
        }
        do {
            let backend = InteractionBackend()
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            let first = UUID(), second = UUID(); try coordinator.reserve(first); try await coordinator.prepare(first)
            coordinator.ready(first); await coordinator.waitForSettlement()
            try coordinator.reserve(second); try await coordinator.prepare(second)
            coordinator.cancelAdmission(first); try await coordinator.release(first)
            try require(backend.events == ["snapshot", "interactive", "hide"],
                        "Closing a ready window while a second window prepares must not flash the physical screen on")
            coordinator.cancelAdmission(second); try await coordinator.release(second)
        }
        do {
            let backend = InteractionBackend()
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            let first = UUID(), second = UUID()
            try coordinator.reserve(first)
            try await coordinator.prepare(first)
            try require(backend.events == ["snapshot", "interactive"], "Before a producer starts, wake with PRESERVE; never hide before readiness")
            coordinator.ready(first); await coordinator.waitForSettlement()
            try require(backend.events.last == "hide", "Default privacy hides only after frame/control readiness")
            try coordinator.reserve(second); try await coordinator.prepare(second)
            try require(backend.events.filter { $0 == "snapshot" }.count == 1 && backend.events.filter { $0 == "interactive" }.count == 1,
                        "An additional window must share the original baseline and logical owner")
            coordinator.setPrivacyEnabled(false); await coordinator.waitForSettlement()
            try require(backend.events.last == "show" && !backend.events.contains("retire"), "Privacy OFF reveals panels but retains interactivity")
            await coordinator.poll()
            try require(backend.events.last == "poll", "An active owner uses STATUS renewal, not repeated APPLY")
            coordinator.cancelAdmission(first)
            try await coordinator.release(first)
            try require(!backend.events.contains("retire"), "Closing one window must not retire the shared owner")
            coordinator.ready(second); coordinator.setPrivacyEnabled(true); await coordinator.waitForSettlement()
            try require(backend.events.last == "hide", "A remaining window can change privacy without rebasing")
            coordinator.cancelAdmission(second); try await coordinator.release(second)
            try require(backend.events.last == "retire", "The final settled producer releases the original owner")
        }
        do {
            let backend = InteractionBackend()
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            let id = UUID(); try coordinator.reserve(id)
            backend.onSnapshot = { coordinator.cancelAdmission(id) }
            var failed = false; do { try await coordinator.prepare(id) } catch { failed = true }
            try require(failed && backend.events == ["snapshot"], "Cancellation during startup cannot issue the first APPLY")
            try await coordinator.release(id)
            try require(backend.events == ["snapshot", "retire"], "A cancelled read-only child still requires exact cleanup")
        }
        do {
            let backend = InteractionBackend(); backend.failApply = true
            let coordinator = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            let id = UUID(); var failures = 0
            try coordinator.reserve(id, onFailure: { failures += 1 })
            var failed = false; do { try await coordinator.prepare(id) } catch { failed = true }
            try require(failed && failures == 1 && !backend.events.contains("retire"), "Unknown APPLY keeps cleanup authority and stops admission")
            coordinator.ready(id); await coordinator.waitForSettlement()
            try require(!backend.events.contains("hide") && failures == 1, "A failed owner cannot be revived by late readiness")
            backend.failRetirement = true
            failed = false; do { try await coordinator.release(id) } catch { failed = true }
            try require(failed, "An unconfirmed final retirement must remain fenced")
            var newAdmission = false; do { try coordinator.reserve(UUID()); newAdmission = true } catch {}
            try require(!newAdmission, "An unsettled old owner cannot admit a new producer")
            backend.failRetirement = false
            try await coordinator.release(id)
            backend.failApply = false
            let next = UUID(); try coordinator.reserve(next); try await coordinator.prepare(next)
            try require(backend.events.filter { $0 == "snapshot" }.count == 2, "A confirmed retirement permits a new independent baseline")
            coordinator.cancelAdmission(next); try await coordinator.release(next)
        }
        do {
            let a = InteractionBackend(), b = InteractionBackend()
            let first = PhoneDisplayInteractionCoordinator(makeOwner: { a }, heartbeat: nil)
            let second = PhoneDisplayInteractionCoordinator(makeOwner: { b }, heartbeat: nil)
            let id = UUID(); try first.reserve(id); try second.reserve(id)
            try await first.prepare(id); try await second.prepare(id)
            first.ready(id); await first.waitForSettlement()
            try require(!b.events.contains("hide"), "Phone owners and privacy policies must remain isolated")
            first.cancelAdmission(id); try await first.release(id)
            try require(!b.events.contains("retire"), "Stopping one phone cannot retire another")
            second.cancelAdmission(id); try await second.release(id)
        }
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS aggregate display interaction: readiness, privacy OFF, shared windows, cancellation, uncertainty, retry and phone isolation") }
        catch { print("FAIL display interaction: \(error)"); exit(1) }
    }
}
