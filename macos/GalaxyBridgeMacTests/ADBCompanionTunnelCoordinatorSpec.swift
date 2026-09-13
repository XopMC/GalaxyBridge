#if !GALAXYBRIDGE_APP_STORE
import Foundation

private final class Gate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var removed: [UInt16] = []
    func waitForStart() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { self.started.wait(); continuation.resume() }
        }
    }
    func remove(_ port: UInt16) { lock.lock(); removed.append(port); lock.unlock() }
    var removals: [UInt16] { lock.lock(); defer { lock.unlock() }; return removed }
}

@main struct ADBCompanionTunnelCoordinatorSpec {
    static func main() async throws {
        let gate = Gate()
        let coordinator = ADBCompanionTunnelCoordinator(allocate: { _ in
            gate.started.signal(); gate.resume.wait()
            return ADBCompanionTunnelResource(port: 42001, remove: { gate.remove(42001) })
        })
        let acquire = Task { try await coordinator.acquire(peerID: "verified-generation-1", serial: "fixture-A") }
        await gate.waitForStart()
        let revocation = Task { try await coordinator.revoke(peerID: "verified-generation-1") }
        // Revoke must install its admission fence while the allocation is held.
        try await Task.sleep(for: .milliseconds(30))
        do { _ = try await coordinator.acquire(peerID: "verified-generation-1", serial: "fixture-A"); fatalError("revoke admitted") }
        catch ADBCompanionTunnelError.revoked { }
        gate.resume.signal()
        do { _ = try await acquire.value; fatalError("late acquisition escaped") }
        catch ADBCompanionTunnelError.revoked { }
        try await revocation.value
        precondition(gate.removals == [42001])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-forward-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("adb-fixture")
        let code = #"""
#!/usr/bin/python3
import sys, pathlib
root = pathlib.Path(__file__).parent
args = sys.argv[1:]
with (root/'commands').open('a') as f: f.write(' '.join(args)+'\n')
p = root/'forward'
rows = p.read_text().splitlines() if p.exists() else []
if args == ['forward','--list']:
    if (root/'fail-reconcile').exists() and any(row.startswith('fixture-uncertain ') for row in rows): sys.exit(32)
    print('\n'.join(rows))
elif len(args)==5 and args[2:]==['forward','tcp:0','tcp:46737']:
    n = root/'counter'
    port = int(n.read_text())+1 if n.exists() else 42010
    n.write_text(str(port))
    rows.append(args[1]+' tcp:'+str(port)+' tcp:46737')
    p.write_text('\n'.join(rows))
    print('invalid' if (root/'bad-response').exists() else port)
elif len(args)==5 and args[2:4]==['forward','--remove']:
    if (root/'fail-remove').exists(): sys.exit(33)
    p.write_text('\n'.join(row for row in rows if not row.startswith(args[1]+' '+args[4]+' ')))
else: sys.exit(31)
"""#
        try code.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try "unrelated tcp:49000 tcp:46737".write(to: root.appendingPathComponent("forward"), atomically: true, encoding: .utf8)
        let production = ADBCompanionTunnelCoordinator(clientFactory: { try ADBClient(testingExecutableURL: executable) })
        async let first = production.acquire(peerID: "verified-A", serial: "fixture-A")
        async let second = production.acquire(peerID: "verified-A", serial: "fixture-A")
        let (a, b) = try await (first, second)
        precondition(a == b && a.host == "127.0.0.1" && a.port == 42010)
        try await production.release(a)
        let replacement = try await production.acquire(peerID: "verified-A", serial: "fixture-A")
        precondition(replacement.token != a.token && replacement.port == 42011)
        try await production.release(a) // stale token cannot retire replacement
        var rows = try String(contentsOf: root.appendingPathComponent("forward"), encoding: .utf8)
        precondition(rows.contains("fixture-A tcp:42011 tcp:46737"))
        try await production.shutdown()
        rows = try String(contentsOf: root.appendingPathComponent("forward"), encoding: .utf8)
        precondition(rows == "unrelated tcp:49000 tcp:46737")
        try Data().write(to: root.appendingPathComponent("bad-response"))
        let badResponse = ADBCompanionTunnelCoordinator(clientFactory: { try ADBClient(testingExecutableURL: executable) })
        do { _ = try await badResponse.acquire(peerID: "verified-bad", serial: "fixture-bad"); fatalError("invalid receipt accepted") }
        catch ADBCompanionTunnelError.invalidForward { }
        rows = try String(contentsOf: root.appendingPathComponent("forward"), encoding: .utf8)
        precondition(rows == "unrelated tcp:49000 tcp:46737") // Reconciled port cleaned despite bad response.
        try await badResponse.shutdown()
        try FileManager.default.removeItem(at: root.appendingPathComponent("bad-response"))

        // Native forward creation succeeds, but cleanup fails. The exact
        // resource remains quarantined until shutdown can retry its receipt.
        let cleanupFailure = ADBCompanionTunnelCoordinator(clientFactory: { try ADBClient(testingExecutableURL: executable) })
        let held = try await cleanupFailure.acquire(peerID: "cleanup-failure", serial: "fixture-held")
        try Data().write(to: root.appendingPathComponent("fail-remove"))
        do { try await cleanupFailure.release(held); fatalError("failed retirement reported settled") }
        catch is ADBClientError { }
        let commandCount = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").count
        do { _ = try await cleanupFailure.acquire(peerID: "new-pairing-generation", serial: "fixture-held"); fatalError("quarantined serial admitted a replacement") }
        catch ADBCompanionTunnelError.ownershipUncertain { }
        let blockedCommandCount = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n").count
        precondition(blockedCommandCount == commandCount)
        _ = try await cleanupFailure.acquire(peerID: "independent-device", serial: "fixture-independent")
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-remove"))
        try await cleanupFailure.shutdown()
        rows = try String(contentsOf: root.appendingPathComponent("forward"), encoding: .utf8)
        precondition(rows == "unrelated tcp:49000 tcp:46737", "shutdown must retry only the exact quarantined cleanup")

        // A failed post-allocation listing loses the safe removal receipt. Do
        // not guess a port or allocate another mapping in a new peer scope.
        let uncertain = ADBCompanionTunnelCoordinator(clientFactory: { try ADBClient(testingExecutableURL: executable) })
        try Data().write(to: root.appendingPathComponent("fail-reconcile"))
        do { _ = try await uncertain.acquire(peerID: "uncertain-generation", serial: "fixture-uncertain"); fatalError("unreconciled forward accepted") }
        catch ADBCompanionTunnelError.ownershipUncertain { }
        let uncertainCommands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
        do { _ = try await uncertain.acquire(peerID: "next-uncertain-generation", serial: "fixture-uncertain"); fatalError("uncertain ownership silently retried") }
        catch ADBCompanionTunnelError.ownershipUncertain { }
        let afterUncertainCommands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
        precondition(afterUncertainCommands == uncertainCommands)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-reconcile"))
        do { try await uncertain.shutdown(); fatalError("unknown port cleanup claimed success") }
        catch ADBCompanionTunnelError.cleanupFailed { }
        rows = try String(contentsOf: root.appendingPathComponent("forward"), encoding: .utf8)
        precondition(rows.contains("unrelated tcp:49000 tcp:46737") && rows.contains("fixture-uncertain "))
        let commands = try String(contentsOf: root.appendingPathComponent("commands"), encoding: .utf8)
        precondition(!commands.contains("--remove-all") && !commands.contains("kill-server") && !commands.contains("shell"))
        do { _ = try await production.acquire(peerID: "verified-B", serial: "fixture-B"); fatalError("shutdown admitted") }
        catch ADBCompanionTunnelError.stopped { }

        let pendingGate = Gate()
        let pending = ADBCompanionTunnelCoordinator(allocate: { _ in
            pendingGate.started.signal(); pendingGate.resume.wait()
            return ADBCompanionTunnelResource(port: 43000, remove: { pendingGate.remove(43000) })
        })
        let pendingAcquire = Task { try await pending.acquire(peerID: "pending", serial: "fixture") }
        await pendingGate.waitForStart()
        let closing = Task { try await pending.shutdown() }
        try await Task.sleep(for: .milliseconds(30))
        pendingGate.resume.signal()
        _ = try? await pendingAcquire.value
        try await closing.value
        precondition(pendingGate.removals == [43000])

        let failing = ADBCompanionTunnelCoordinator(allocate: { _ in
            ADBCompanionTunnelResource(port: 44000, remove: { throw ADBCompanionTunnelError.cleanupFailed })
        })
        _ = try await failing.acquire(peerID: "failure", serial: "fixture")
        do { try await failing.shutdown(); fatalError("cleanup failure lost") }
        catch ADBCompanionTunnelError.cleanupFailed { }
        print("PASS tunnel: real process exact commands, shared endpoint, stale release, revoke/pending shutdown fences, cleanup/uncertain-ownership quarantine, independent devices, exact shutdown retry and unrelated forward preservation")
    }
}
#endif
