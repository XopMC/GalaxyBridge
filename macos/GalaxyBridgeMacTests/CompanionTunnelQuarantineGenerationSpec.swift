import Foundation

struct ADBClient: Sendable {
    init() throws {}
    var acquiredGenerationIsRetired: Bool { false }
    func run(arguments: [String], timeout: TimeInterval) throws -> String { fatalError("unexpected real ADB boundary") }
}
final class Generations: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 1, dead = Set<Int>(), prepared: [Int] = [], removed: [Int] = []
    let allocationFailure: Bool
    init(allocationFailure: Bool) { self.allocationFailure = allocationFailure }
    func replace() { lock.lock(); dead.insert(generation); generation += 1; lock.unlock() }
    func isRetired(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return dead.contains(value) }
    var preparations: [Int] { lock.lock(); defer { lock.unlock() }; return prepared }
    var removals: [Int] { lock.lock(); defer { lock.unlock() }; return removed }
    func prepare(_ serial: String) -> ADBCompanionTunnelAllocation {
        lock.lock(); let frozen = generation; prepared.append(frozen); lock.unlock()
        return .init(create: { [self] in
            if allocationFailure && frozen == 1 { throw ADBCompanionTunnelError.ownershipUncertain }
            return .init(port: UInt16(42000 + frozen), remove: { [self] in
                if frozen == 1 && !isRetired(frozen) { throw ADBCompanionTunnelError.cleanupFailed }
                lock.lock(); removed.append(frozen); lock.unlock()
            })
        }, ownershipRetired: { [self] in isRetired(frozen) })
    }
}
@main struct CompanionTunnelQuarantineGenerationSpec {
    static func main() async throws {
        for allocationFailure in [true, false] {
            let evidence = Generations(allocationFailure: allocationFailure)
            let coordinator = ADBCompanionTunnelCoordinator(prepare: { evidence.prepare($0) })
            var old: ADBCompanionTunnelLease?
            do {
                old = try await coordinator.acquire(peerID: "synthetic-generation-1", serial: "synthetic-usb")
                try await coordinator.release(old!)
                fatalError("live uncertain ownership was accepted")
            } catch ADBCompanionTunnelError.ownershipUncertain {
                precondition(allocationFailure)
            } catch ADBCompanionTunnelError.cleanupFailed {
                precondition(!allocationFailure)
            }
            do {
                _ = try await coordinator.acquire(peerID: "synthetic-next-scope", serial: "synthetic-usb")
                fatalError("live quarantine admitted a successor")
            } catch ADBCompanionTunnelError.ownershipUncertain {}
            precondition(evidence.preparations == [1])
            evidence.replace()
            let fresh = try await coordinator.acquire(peerID: "synthetic-generation-2", serial: "synthetic-usb")
            precondition(fresh.port == 42002 && evidence.preparations == [1, 2])
            if let old { try await coordinator.release(old) }
            precondition(evidence.removals.isEmpty, "stale release touched a replacement")
            try await coordinator.shutdown()
            precondition(evidence.removals == [2], "cleanup migrated onto a retired generation")
        }
        let evidence = Generations(allocationFailure: true)
        let coordinator = ADBCompanionTunnelCoordinator(prepare: { evidence.prepare($0) })
        do { _ = try await coordinator.acquire(peerID: "synthetic", serial: "synthetic-usb"); fatalError("missing uncertain failure") }
        catch ADBCompanionTunnelError.ownershipUncertain {}
        evidence.replace()
        try await coordinator.shutdown()
        do { _ = try await coordinator.acquire(peerID: "new", serial: "synthetic-usb"); fatalError("shutdown reopened admission") }
        catch ADBCompanionTunnelError.stopped {}
        precondition(evidence.removals.isEmpty)
        let capacityEvidence = Generations(allocationFailure: true)
        let capacity = ADBCompanionTunnelCoordinator(capacity: 1, prepare: { capacityEvidence.prepare($0) })
        do { _ = try await capacity.acquire(peerID: "old-peer", serial: "old-usb"); fatalError("missing uncertain allocation") }
        catch ADBCompanionTunnelError.ownershipUncertain {}
        capacityEvidence.replace()
        _ = try await capacity.acquire(peerID: "new-peer", serial: "new-usb")
        try await capacity.shutdown()
        print("PASS actual tunnel coordinator: live quarantine, later exact daemon exit, allocation/removal uncertainty recovery, frozen generation proof, stale release and shutdown")
    }
}
