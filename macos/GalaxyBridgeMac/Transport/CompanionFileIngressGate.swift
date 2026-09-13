import Foundation

/// Reserves work before hopping from the socket callback to the main actor.
/// A misbehaving peer cannot accumulate unbounded decoded chunks/tasks there.
final class CompanionFileIngressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var bytes = 0
    private var rejected = false
    private var rejectionReported = false
    func admit(bytes count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !rejected else { return false }
        guard count >= 0, count <= 8 * 1024 * 1024, pending < 16,
              bytes <= 8 * 1024 * 1024 - count else { rejected = true; return false }
        pending += 1; bytes += count
        return true
    }
    func finish(bytes count: Int) {
        lock.lock(); defer { lock.unlock() }
        precondition(pending > 0 && count >= 0 && count <= bytes)
        pending -= 1; bytes -= count
    }
    func shouldReportRejection() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard rejected && !rejectionReported else { return false }
        rejectionReported = true; return true
    }
}
