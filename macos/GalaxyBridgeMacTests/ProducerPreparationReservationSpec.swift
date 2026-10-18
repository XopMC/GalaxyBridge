import Foundation

@MainActor private final class Probe {
    var started = false
    var cleaned = 0
    var cancelled = 0
    var failCleanup = true
    var waiter: CheckedContinuation<Void, Never>?
}

@main struct ProducerPreparationReservationSpec {
    @MainActor static func until(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        fatalError("reservation fixture did not reach its boundary")
    }
    @MainActor static func main() async throws {
        let unused = Probe()
        let local = ProducerPreparationReservation<Int>(operation: { _ in
            unused.started = true; return 1
        }, cancelResource: { _ in unused.cancelled += 1 }, cleanup: {
            unused.cleaned += 1
        })
        try await local.retire()
        precondition(local.retired && !unused.started && unused.cleaned == 0)

        let probe = Probe()
        let reservation = ProducerPreparationReservation<Int>(operation: { owner in
            try owner.checkAdmission()
            owner.markDispatched()
            probe.started = true
            await withCheckedContinuation { probe.waiter = $0 }
            return 7 // A remote response may arrive despite cancellation.
        }, cancelResource: { value in
            precondition(value == 7); probe.cancelled += 1
        }, cleanup: {
            probe.cleaned += 1
            if probe.failCleanup { throw CancellationError() }
        })
        let start = Task { try await reservation.value() }
        await until { probe.waiter != nil }
        let stop = Task { try await reservation.retire() }
        await until { !reservation.accepting }
        precondition(!reservation.retired && probe.cleaned == 0,
                     "cleanup cannot precede a still-starting producer")
        probe.waiter!.resume(); probe.waiter = nil
        do { _ = try await start.value; fatalError("late resource escaped cancelled admission") }
        catch is CancellationError {}
        do { try await stop.value; fatalError("failed cleanup was accepted") }
        catch is CancellationError {}
        precondition(!reservation.retired && probe.cleaned == 1 && probe.cancelled > 0)
        probe.failCleanup = false
        try await reservation.retire()
        precondition(reservation.retired && probe.cleaned == 2)
        try await reservation.retire()
        precondition(probe.cleaned == 2, "confirmed retirement must be idempotent")

        let beforeDispatch = Probe()
        let cancelled = ProducerPreparationReservation<Int>(operation: { owner in
            await withCheckedContinuation { beforeDispatch.waiter = $0 }
            try owner.checkAdmission()
            owner.markDispatched()
            beforeDispatch.started = true
            return 9
        }, cancelResource: { _ in }, cleanup: { beforeDispatch.cleaned += 1 })
        let waiting = Task { try await cancelled.value() }
        await until { beforeDispatch.waiter != nil }
        waiting.cancel()
        beforeDispatch.waiter!.resume(); beforeDispatch.waiter = nil
        do { _ = try await waiting.value; fatalError("cancelled START was admitted") }
        catch is CancellationError {}
        try await cancelled.retire()
        precondition(cancelled.retired && !beforeDispatch.started && beforeDispatch.cleaned == 0)
        print("Producer preparation reservation: passed")
    }
}
