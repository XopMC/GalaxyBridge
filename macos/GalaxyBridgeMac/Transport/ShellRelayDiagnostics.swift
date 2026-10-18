#if !GALAXYBRIDGE_APP_STORE
import Foundation
import OSLog

/// Opt-in scalar evidence at the TLS-to-loopback boundary. Byte ranges refer
/// only to the upgraded raw stream. No payload, peer or lease is retained.
final class ShellRelayDiagnostics: @unchecked Sendable {
    static let argument = "--primary-relay-diagnostics"
    static let capacity = 256
    struct Ticket: Equatable, Sendable {
        fileprivate let owner: UUID
        fileprivate let sequence: UInt64
    }
    struct Sample: Sendable {
        let sequence: UInt64
        let byteStart: UInt64
        let byteEnd: UInt64
        let receivedAt: Double
        var forwardedAt: Double?
        var succeeded: Bool?
        var logField: String {
            let forwarded = forwardedAt.map { String($0) } ?? "none"
            let success = succeeded.map { $0 ? "1" : "0" } ?? "none"
            return "relaySample=\(sequence),from:\(byteStart),to:\(byteEnd),received_s:\(receivedAt),forwarded_s:\(forwarded),success:\(success)"
        }
    }
    struct Summary: Sendable {
        let generation: UInt64
        let totalChunks: UInt64
        let totalBytes: UInt64
        let overwritten: UInt64
        let invalidObservations: UInt64
        let alignmentValid: Bool
        let samples: [Sample]
        var logLines: [String] {
            let prefix = "relay_generation=\(generation) stream=video"
            return ["\(prefix) terminal=1 chunks=\(totalChunks) bytes=\(totalBytes) retained=\(samples.count) overwritten=\(overwritten) invalid=\(invalidObservations) aligned=\(alignmentValid ? 1 : 0) boundary=TLS_callback_to_loopback_contentProcessed"]
                + samples.map { "\(prefix) \($0.logField)" }
        }
    }
    private let generation: UInt64
    private let identity = UUID()
    private let now: @Sendable () -> Double
    private let sink: @Sendable (Summary) -> Void
    private let lock = NSLock()
    private var terminal = false
    private var totalChunks: UInt64 = 0
    private var totalBytes: UInt64 = 0
    private var overwritten: UInt64 = 0
    private var invalid: UInt64 = 0
    private var alignmentValid = true
    private var samples = [Sample?](repeating: nil, count: capacity)

    static func make(enabled: Bool, factory: () -> ShellRelayDiagnostics) -> ShellRelayDiagnostics? {
        enabled ? factory() : nil
    }
    static func logging(bundleID: String) -> ShellRelayDiagnostics {
        let logger = Logger(subsystem: bundleID, category: "ShellRelayDiagnostics")
        return ShellRelayDiagnostics(generation: UInt64.random(in: 1...UInt64.max)) { summary in
            for line in summary.logLines { logger.info("\(line, privacy: .public)") }
        }
    }
    init(generation: UInt64, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         sink: @escaping @Sendable (Summary) -> Void) {
        self.generation = generation; self.now = now; self.sink = sink
    }
    func received(bytes: Int) -> Ticket? {
        let time = now()
        return lock.withLock {
            guard !terminal else { return nil }
            guard bytes > 0, alignmentValid else { markInvalid(); return nil }
            let (end, byteOverflow) = totalBytes.addingReportingOverflow(UInt64(bytes))
            let (sequence, sequenceOverflow) = totalChunks.addingReportingOverflow(1)
            guard !byteOverflow, !sequenceOverflow else {
                alignmentValid = false; markInvalid(); return nil
            }
            let start = totalBytes; totalBytes = end; totalChunks = sequence
            let slot = Int((sequence - 1) % UInt64(Self.capacity))
            if sequence > UInt64(Self.capacity) { overwritten += 1 }
            samples[slot] = nil
            guard time.isFinite, time >= 0 else { markInvalid(); return nil }
            samples[slot] = Sample(sequence: sequence, byteStart: start, byteEnd: end, receivedAt: time)
            return Ticket(owner: identity, sequence: sequence)
        }
    }
    func forwarded(_ ticket: Ticket, succeeded: Bool) {
        let time = now()
        lock.withLock {
            guard !terminal else { return }
            guard ticket.owner == identity else { markInvalid(); return }
            let slot = Int((ticket.sequence - 1) % UInt64(Self.capacity))
            guard var sample = samples[slot], sample.sequence == ticket.sequence else { return }
            guard sample.forwardedAt == nil, time.isFinite, time >= sample.receivedAt else { markInvalid(); return }
            sample.forwardedAt = time; sample.succeeded = succeeded; samples[slot] = sample
        }
    }
    private func markInvalid() { if invalid < .max { invalid += 1 } }
    /// Emit once, after existing cancellation. Pending completions remain
    /// unresolved; later callbacks cannot rewrite already emitted evidence.
    func finish() {
        let summary: Summary? = lock.withLock {
            guard !terminal else { return nil }
            terminal = true
            let retained = samples.compactMap { $0 }.sorted { $0.sequence < $1.sequence }
            samples.removeAll()
            return Summary(generation: generation, totalChunks: totalChunks, totalBytes: totalBytes,
                           overwritten: overwritten, invalidObservations: invalid,
                           alignmentValid: alignmentValid, samples: retained)
        }
        if let summary { sink(summary) }
    }
}
#endif
