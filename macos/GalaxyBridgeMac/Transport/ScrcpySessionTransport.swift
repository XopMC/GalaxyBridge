#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeCore

struct ScrcpyTransportSettlement: Sendable {
    let physicallySettled: Bool
    let failed: Bool
    let status: UInt32
}

protocol ScrcpySessionTransport: AnyObject, Sendable {
    func send(_ bytes: Data, received: UInt64, trace: PrimaryMediaTrace?)
    func retire()
    func waitForCleanup() async -> ScrcpyTransportSettlement
}

/// Checked affine conversion between two clocks on this Mac only. Sampling
/// brackets the C call and uses the upper host bound: receipt is never made
/// younger by uncertainty. Android BOOTTIME is deliberately absent here.
struct QuicReceiptClock: Sendable {
    let hostLower: UInt64
    let hostUpper: UInt64
    let backend: UInt64
    init(hostBefore: UInt64, backend: UInt64, hostAfter: UInt64) throws {
        guard hostAfter >= hostBefore else { throw QuicBackendError(status: 104) }
        hostLower = hostBefore; hostUpper = hostAfter; self.backend = backend
    }
    func map(_ receipt: UInt64) throws -> UInt64 {
        if receipt >= hostUpper {
            let (value, overflow) = backend.addingReportingOverflow(receipt - hostUpper)
            guard !overflow else { throw QuicBackendError(status: 104) }
            return value
        }
        guard hostUpper - receipt <= backend else { throw QuicBackendError(status: 103) }
        return backend - (hostUpper - receipt)
    }
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    func cutoff(_ original: UInt64) throws -> UInt64 {
        if original >= backend {
            let (value, overflow) = hostLower.addingReportingOverflow(original - backend)
            guard !overflow else { throw QuicBackendError(status: 104) }
            return value
        }
        guard backend - original <= hostLower else { throw QuicBackendError(status: 104) }
        return hostLower - (backend - original)
    }
}

/// One committed reverse callback in flight. The owner continues checking this
/// original cutoff even while MainActor is held. The final lease outlives the
/// actor closure, not just C commit or an owner queue pop.
final class QuicDeviceDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let reverse, clipboard: UInt64
    private let attempt: NativeMediaAttempt
    private let retention: NativeMediaLease
    private var started = false
    private var completed = false
    private var failure: UInt32 = 0
    init(reverse: UInt64, clipboard: UInt64, attempt: NativeMediaAttempt, retention: NativeMediaLease) {
        self.reverse = reverse; self.clipboard = clipboard; self.attempt = attempt; self.retention = retention
    }
    private func expiry(_ now: UInt64) -> UInt32 {
        if clipboard != 0, now >= clipboard { return 112 }
        if now >= reverse { return 103 }
        return 0
    }
    var originalCutoff: UInt64 { clipboard == 0 ? reverse : min(reverse, clipboard) }
    func status(now: UInt64 = QuicReceiptClock.now) -> (completed: Bool, failure: UInt32) {
        lock.withLock {
            if !completed, failure == 0 { failure = expiry(now) }
            return (completed, failure)
        }
    }
    func cancel() { lock.withLock { if failure == 0 { failure = 107 } } }
    @MainActor func deliver(_ callback: () -> Bool) {
        let accepted = lock.withLock {
            if failure == 0 { failure = expiry(QuicReceiptClock.now) }
            guard !started, !completed, failure == 0, attempt.isAdmitted else { return false }
            started = true; return true
        }
        guard accepted else { return }
        // No await or queued continuation between this fresh guard and the
        // existing synchronous keyboard callback. No lock crosses the effect.
        let fresh = expiry(QuicReceiptClock.now)
        let delivered = fresh == 0 && attempt.isAdmitted && callback()
        lock.withLock {
            completed = true
            if failure == 0 { failure = fresh != 0 ? fresh : delivered ? expiry(QuicReceiptClock.now) : 107 }
        }
        withExtendedLifetime(retention) {}
    }
}

/// Encodes only the existing GQM1 typed control wrapper. Original stock bytes
/// stay unchanged. Bulk is selected by operation semantics, never length alone.
struct QuicControlEncoder {
    let generation: UInt64
    var epoch: UInt32 = 1
    private var critical: UInt64 = 0
    private var gesture: UInt64 = 0
    private var move: UInt64 = 0
    private var pointers: [UInt64: UInt64] = [:]
    init(generation: UInt64) { self.generation = generation }

    mutating func encode(_ stock: Data) throws -> (kind: UInt32, bytes: Data) {
        guard let type = stock.first, !stock.isEmpty, stock.count <= 262144 else { throw QuicBackendError(status: 102) }
        if type == 1 {
            guard stock.count >= 5, Self.word(stock, 1, 4) == stock.count - 5,
                  stock.count <= 305, String(data: stock.dropFirst(5), encoding: .utf8) != nil else {
                throw QuicBackendError(status: 108)
            }
        }
        // GET_CLIPBOARD is a two-byte, latency-sensitive control request.  It
        // used to share the bulk/file QUIC connection, so a congested media
        // burst could let its 500 ms bulk acknowledgement expire and retire an
        // otherwise healthy screen session.  Keep the potentially large
        // SET_CLIPBOARD payload on bulk, but carry GET_CLIPBOARD on the same
        // ordered priority connection as the other small control commands.
        if type == 9 || (type == 12 || type == 13) && stock.count > 924 {
            return (3, stock)
        }
        guard stock.count <= 924 else { throw QuicBackendError(status: 108) }
        if type == 2 {
            guard stock.count == 32 else { throw QuicBackendError(status: 101) }
            let pointer = Self.word(stock, 2, 8)
            if stock[1] == 2 {
                guard let active = pointers[pointer] else { throw QuicBackendError(status: 101) }
                move = try increment(move)
                var body = Data(); Self.append(active, &body); Self.append(pointer, &body); Self.append(critical, &body)
                Self.append(UInt32(stock.count), &body); body.append(stock)
                return (2, record(kind: 9, sequence: move, lifetime: 40000, body: body))
            }
        }
        critical = try increment(critical)
        var classID: UInt8
        switch type {
        case 0: classID = 4
        case 2: classID = stock[1] == 0 ? 1 : stock[1] == 1 ? 2 : 3
        case 3: classID = 8
        case 12...14: classID = 5
        case 16: classID = 7
        case 21: classID = 6
        default: classID = 9
        }
        var body = Data(repeating: 0, count: 8); body[0] = classID
        if type == 2 {
            let pointer = Self.word(stock, 2, 8)
            let current: UInt64
            if stock[1] == 0 {
                guard pointers[pointer] == nil, pointers.count < 16 else { throw QuicBackendError(status: 102) }
                if pointers.isEmpty { gesture = try increment(gesture) }
                current = gesture; pointers[pointer] = current
            } else {
                guard let active = pointers.removeValue(forKey: pointer) else { throw QuicBackendError(status: 101) }
                current = active
            }
            Self.append(current, &body); Self.append(pointer, &body); Self.append(stock[1] == 0 ? UInt64(0) : move, &body)
        } else { body.append(Data(repeating: 0, count: 24)) }
        Self.append(UInt32(stock.count), &body); body.append(stock)
        if type == 21 { pointers.removeAll() }
        return (1, record(kind: 8, sequence: critical, lifetime: 500000, body: body))
    }

    private func increment(_ value: UInt64) throws -> UInt64 {
        guard value < UInt64.max else { throw QuicBackendError(status: 102) }; return value + 1
    }
    private func record(kind: UInt8, sequence: UInt64, lifetime: UInt32, body: Data) -> Data {
        var b = Data("GQM1".utf8); b.append(contentsOf: [kind, 0, 0, 0])
        Self.append(generation, &b); Self.append(epoch, &b); Self.append(UInt32(0), &b)
        Self.append(sequence, &b); Self.append(UInt64(0), &b); Self.append(UInt32(body.count), &b)
        Self.append(UInt16(0), &b); Self.append(UInt16(1), &b); Self.append(UInt16(body.count), &b)
        Self.append(UInt16(0), &b); Self.append(UInt32(0), &b); Self.append(lifetime, &b); Self.append(UInt32(0), &b)
        b.append(body); return b
    }
    private static func word(_ bytes: Data, _ at: Int, _ count: Int) -> UInt64 {
        bytes[at..<at+count].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private static func append<T: FixedWidthInteger>(_ value: T, _ bytes: inout Data) {
        var v = value.bigEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
    }
}
#endif
