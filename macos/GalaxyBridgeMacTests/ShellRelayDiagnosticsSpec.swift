import Foundation

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 1.0
    func set(_ next: Double) { lock.withLock { value = next } }
    func now() -> Double { lock.withLock { value } }
}
private final class Summaries: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ShellRelayDiagnostics.Summary] = []
    func add(_ summary: ShellRelayDiagnostics.Summary) { lock.withLock { storage.append(summary) } }
    var values: [ShellRelayDiagnostics.Summary] { lock.withLock { storage } }
}
@main enum ShellRelayDiagnosticsSpec {
    static func main() throws {
        let clock = Clock(), summaries = Summaries()
        let disabled = ShellRelayDiagnostics.make(enabled: false) {
            preconditionFailure("Disabled relay diagnostics must allocate no collector")
        }
        precondition(disabled == nil)
        let meter = ShellRelayDiagnostics(generation: 17, now: clock.now, sink: summaries.add)
        let first = meter.received(bytes: 3)!
        precondition(summaries.values.isEmpty, "Receive must never emit per-chunk logs")
        clock.set(1.25); meter.forwarded(first, succeeded: true)
        clock.set(1.5); let second = meter.received(bytes: 5)!
        clock.set(2); meter.forwarded(second, succeeded: false)
        meter.finish(); meter.finish()
        precondition(summaries.values.count == 1, "Cancellation paths must emit exactly one terminal summary")
        let value = summaries.values[0]
        precondition(value.generation == 17 && value.totalChunks == 2 && value.totalBytes == 8)
        precondition(value.overwritten == 0 && value.invalidObservations == 0 && value.alignmentValid)
        precondition(value.samples.count == 2)
        precondition(value.samples[0].sequence == 1 && value.samples[0].byteStart == 0 && value.samples[0].byteEnd == 3)
        precondition(value.samples[0].receivedAt == 1 && value.samples[0].forwardedAt == 1.25 && value.samples[0].succeeded == true)
        precondition(value.samples[1].byteStart == 3 && value.samples[1].byteEnd == 8 && value.samples[1].succeeded == false)
        precondition(value.logLines.allSatisfy { $0.utf8.count <= 900 })
        precondition(meter.received(bytes: 9) == nil)
        meter.forwarded(first, succeeded: false)
        precondition(summaries.values.count == 1)

        let ringValues = Summaries(), ring = ShellRelayDiagnostics(generation: 18, now: clock.now, sink: ringValues.add)
        var stale: ShellRelayDiagnostics.Ticket?
        for n in 0..<(ShellRelayDiagnostics.capacity + 3) {
            clock.set(Double(n + 10)); let ticket = ring.received(bytes: 2)!
            if n == 0 { stale = ticket }
            if n != ShellRelayDiagnostics.capacity + 2 { ring.forwarded(ticket, succeeded: true) }
        }
        ring.forwarded(stale!, succeeded: false)
        ring.finish()
        let retained = ringValues.values[0]
        precondition(retained.samples.count == ShellRelayDiagnostics.capacity && retained.overwritten == 3)
        precondition(retained.samples.first?.sequence == 4 && retained.samples.last?.sequence == UInt64(ShellRelayDiagnostics.capacity + 3))
        precondition(retained.samples.last?.forwardedAt == nil && retained.samples.last?.succeeded == nil,
                     "Unfinished forwarding must remain unresolved in terminal evidence")
        precondition(retained.totalBytes == UInt64((ShellRelayDiagnostics.capacity + 3) * 2))

        let invalidValues = Summaries(), invalid = ShellRelayDiagnostics(generation: 19, now: clock.now, sink: invalidValues.add)
        precondition(invalid.received(bytes: 0) == nil && invalid.received(bytes: -1) == nil)
        clock.set(.nan); precondition(invalid.received(bytes: 7) == nil)
        clock.set(10); let valid = invalid.received(bytes: 3)!
        clock.set(9); invalid.forwarded(valid, succeeded: true)
        clock.set(12); invalid.forwarded(first, succeeded: true)
        clock.set(13); invalid.forwarded(valid, succeeded: true)
        clock.set(14); invalid.forwarded(valid, succeeded: false)
        invalid.finish()
        let checked = invalidValues.values[0]
        precondition(checked.totalBytes == 10 && checked.samples.count == 1 && checked.samples[0].byteStart == 7)
        precondition(checked.samples[0].receivedAt == 10 && checked.samples[0].forwardedAt == 13 && checked.samples[0].succeeded == true)
        precondition(checked.invalidObservations >= 5 && checked.alignmentValid)
        precondition(!checked.logLines.joined().contains("nan") && !checked.logLines.joined().contains("inf"))

        let overflowValues = Summaries(), overflow = ShellRelayDiagnostics(generation: 20, now: clock.now, sink: overflowValues.add)
        _ = overflow.received(bytes: Int.max); _ = overflow.received(bytes: Int.max)
        precondition(overflow.received(bytes: 3) == nil && overflow.received(bytes: 1) == nil)
        overflow.finish()
        precondition(!overflowValues.values[0].alignmentValid && overflowValues.values[0].totalBytes == UInt64.max - 1,
                     "Overflow must invalidate byte alignment instead of wrapping offsets")
        print("PASS relay timing: byte ordinals, no data retention, silent observations, bounded ring, unresolved forwarding, idempotent cancellation, invalid clocks and overflow")
    }
}
