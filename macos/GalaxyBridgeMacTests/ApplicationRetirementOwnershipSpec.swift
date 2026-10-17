import Foundation
import CoreGraphics

typealias NSWindow = WindowFixture
typealias ApplicationCatalogItem = String
typealias AnyCancellable = UUID

@MainActor final class SurfaceFixture {
    var freshFramePresentationReceipt: (() -> Void)?
    private(set) var cleared = false
    func clearFrame() { cleared = true }
}
@MainActor final class CleanupGate {
    var entered = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { entered += 1; await withCheckedContinuation { waiters.append($0) } }
    func release() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
@MainActor final class NativeFixture {
    let surface: SurfaceFixture
    var serial = "captured-usb"
    var capturedADBGeneration: UUID?
    var cleanupPhysicallySettled = false
    var hostResourcesPhysicallySettled = false
    var ownedDecodedFrameHandler: (() -> Void)?
    var gate: CleanupGate?
    init(surface: SurfaceFixture) { self.surface = surface }
    func stop() { precondition(surface.cleared, "closed session retained cached native pixels") }
    func stopAndWaitForCleanup() async { stop(); if let gate { await gate.wait() } }
    func retryOwnedCleanup() {}
    func waitForScheduledCleanup() async { if let gate { await gate.wait() } }
}
struct ResizeFixture { mutating func close() {} }
@MainActor final class ApplicationWindowSession {
    let application = "synthetic-app"
    let surface = SurfaceFixture()
    lazy var scrcpy = NativeFixture(surface: surface)
    var nativeSession: NativeFixture { scrcpy }
    var closed = false
    var resizeTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var resizeDeliveryState = ResizeFixture()
    // ACTUAL_SESSION_CLOSE
}
@MainActor final class WindowFixture {
    var frame = NSRect(x: 10, y: 20, width: 300, height: 400)
    weak var delegate: AnyObject?
    private(set) var closed = false
    func close() {
        guard !closed else { return }
        closed = true
        (delegate as? CoordinatorFixture)?.windowWillClose(Notification(name: .init("synthetic-close"), object: self))
    }
}
@MainActor final class WeakWindowFixture {
    weak var value: WindowFixture?
    init(_ value: WindowFixture?) { self.value = value }
}
@MainActor final class CoordinatorFixture {
    // ACTUAL_TYPES_AND_STORAGE
    // ACTUAL_METHODS
    func seed(_ session: ApplicationWindowSession, _ window: WindowFixture, device: String = "phone", release: @escaping () -> Void) {
        records["device:" + device + "\u{0}app"] = Record(identity: DeviceIdentity("device:" + device), leaseID: "synthetic-lease-" + device,
            window: window, session: session, release: release, privacySubscriptions: [])
        window.delegate = self
    }
}
@main struct ApplicationRetirementOwnershipSpec {
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    @MainActor static func main() async throws {
        let adoption = CoordinatorFixture(), pairedSession = ApplicationWindowSession(), pairedWindow = WindowFixture()
        let retiringBeforePair = ApplicationWindowSession(), retiringWindow = WindowFixture()
        var pairReleases = 0
        adoption.seed(pairedSession, pairedWindow, device: "unpaired", release: { pairReleases += 1 })
        let oldADB = UUID(), currentADB = UUID()
        try expect(!adoption.hasStaleADBGeneration(deviceID: "device:unpaired", currentGeneration: currentADB),
            "an unacquired client was treated as a dead generation")
        pairedSession.nativeSession.capturedADBGeneration = oldADB
        try expect(adoption.hasStaleADBGeneration(deviceID: "device:unpaired", currentGeneration: currentADB),
            "active app generation mismatch was omitted")
        try expect(!adoption.hasStaleADBGeneration(deviceID: "device:unpaired", currentGeneration: oldADB),
            "healthy app generation was treated as stale")
        adoption.adoptDeviceIdentity(from: "device:unpaired", to: "device:paired")
        try expect(adoption.captureSerials(deviceID: "device:paired") == ["captured-usb"]
            && adoption.captureSerials(deviceID: "device:unpaired").isEmpty, "verified adoption omitted an active app owner")
        try expect(!pairedWindow.closed && adoption.records["device:paired\u{0}app"]?.identity.id == "device:paired",
            "adoption lost live UI or left callbacks targeting the pre-pair identity")
        adoption.seed(retiringBeforePair, retiringWindow, device: "unpaired", release: { pairReleases += 1 })
        let pendingGate = CleanupGate(); retiringBeforePair.nativeSession.gate = pendingGate
        retiringBeforePair.nativeSession.capturedADBGeneration = oldADB
        retiringWindow.close()
        for _ in 0..<1000 where pendingGate.entered == 0 { await Task.yield() }
        try expect(adoption.hasStaleADBGeneration(deviceID: "device:unpaired", currentGeneration: currentADB),
            "retiring app generation mismatch was omitted")
        try expect(pendingGate.entered == 1, "pre-pair cleanup must remain in flight through adoption")
        adoption.adoptDeviceIdentity(from: "device:unpaired", to: "device:paired")
        try expect(adoption.hasRetiringOwners(deviceID: "device:paired") && !adoption.hasRetiringOwners(deviceID: "device:unpaired"),
            "adoption lost an in-flight retiring app fence")
        retiringBeforePair.nativeSession.hostResourcesPhysicallySettled = true
        retiringBeforePair.nativeSession.cleanupPhysicallySettled = true
        pendingGate.release()
        for work in Array(adoption.retirementTasks.values) { await work.value }
        try expect(pairReleases == 1 && !adoption.hasRetiringOwners(deviceID: "device:paired"),
            "old-key cleanup completion lost its migrated exact release handle")
        // Canonical active + pre-pair active collision: preserve both owners until exact retirement.
        let collision = ApplicationWindowSession(), collisionWindow = WindowFixture()
        adoption.seed(collision, collisionWindow, device: "unpaired", release: { pairReleases += 1 })
        adoption.adoptDeviceIdentity(from: "device:unpaired", to: "device:paired")
        try expect(collisionWindow.closed && !pairedWindow.closed && adoption.hasRetiringOwners(deviceID: "device:paired"),
            "identity collision replaced a live canonical owner or discarded its predecessor fence")
        pairedWindow.close()
        try expect(adoption.retiringRecords.count == 2 && adoption.records.isEmpty,
            "closing the canonical window overwrote its adopted predecessor's retirement fence")
        collision.nativeSession.hostResourcesPhysicallySettled = true; collision.nativeSession.cleanupPhysicallySettled = true
        _ = await adoption.retryRetiringOwners(deviceID: "device:paired")
        try expect(pairReleases == 2 && adoption.hasRetiringOwners(deviceID: "device:paired"), "identity collision lost/doubled a capacity release")
        pairedSession.nativeSession.hostResourcesPhysicallySettled = true; pairedSession.nativeSession.cleanupPhysicallySettled = true
        _ = await adoption.retryRetiringOwners(deviceID: "device:paired")
        try expect(pairReleases == 3 && !adoption.hasRetiringOwners(deviceID: "device:paired"), "canonical close lost its distinct exact owner")

        let delayed = CoordinatorFixture(), delayedSession = ApplicationWindowSession(), delayedWindow = WindowFixture()
        var delayedReleases = 0
        delayed.seed(delayedSession, delayedWindow, release: { delayedReleases += 1 })
        delayedWindow.close()
        for work in Array(delayed.retirementTasks.values) { await work.value }
        try expect(delayedReleases == 0, "unsettled local owner released capacity")
        delayedSession.nativeSession.hostResourcesPhysicallySettled = true
        // No route notification or explicit retry: the phone remains unreachable.
        for _ in 0..<30 where delayedReleases == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try expect(delayedReleases == 1, "late local settlement stranded global app capacity without a ready phone")
        try expect(delayed.hasRetiringOwners(deviceID: "device:phone"), "local settlement removed the remote target fence")

        let coordinator = CoordinatorFixture(), session = ApplicationWindowSession()
        var window: WindowFixture? = WindowFixture()
        let closedUI = WeakWindowFixture(window)
        var released = 0
        coordinator.seed(session, window!, release: { released += 1 })
        let suspension = await coordinator.suspendForRouteChange(deviceID: "device:phone")
        try expect(!suspension.settled && released == 0, "unconfirmed app retirement released capacity before remote ownership settled")
        try expect(suspension.windows.count == 1 && suspension.windows[0].application == "synthetic-app"
            && suspension.windows[0].frame == NSRect(x: 10, y: 20, width: 300, height: 400), "route suspension lost the exact app and window geometry")
        try expect(window!.closed && session.closed && session.surface.cleared, "suspension must close UI and cached pixels before awaiting native ownership")
        try expect(coordinator.hasOwnedADBCaptureWindows(deviceID: "device:phone"), "retiring raw owner disappeared from backend admission")
        window = nil
        try expect(closedUI.value == nil, "retirement retained the closed window/view graph")
        _ = await coordinator.retryRetiringOwners(deviceID: "device:other")
        try expect(released == 0 && coordinator.hasRetiringOwners(deviceID: "device:phone"), "another phone released pending ownership")
        session.nativeSession.hostResourcesPhysicallySettled = true
        let remoteStillPending = await coordinator.retryRetiringOwners(deviceID: "device:phone")
        try expect(!remoteStillPending && released == 1 && coordinator.hasRetiringOwners(deviceID: "device:phone"),
            "retained remote target must free confirmed local capacity without admitting a same-target successor")
        session.nativeSession.cleanupPhysicallySettled = true
        let gate = CleanupGate(); session.nativeSession.gate = gate
        let first = Task { await coordinator.retryRetiringOwners(deviceID: "device:phone") }
        let second = Task { await coordinator.retryRetiringOwners(deviceID: "device:phone") }
        for _ in 0..<1000 where gate.entered < 2 { await Task.yield() }
        try expect(gate.entered == 2, "both cleanup retries must reach the controlled ownership barrier")
        gate.release()
        _ = await first.value; _ = await second.value
        try expect(released == 1 && !coordinator.hasRetiringOwners(deviceID: "device:phone"), "concurrent exact proof must release capacity once")
        try expect(!coordinator.hasOwnedADBCaptureWindows(deviceID: "device:phone"), "confirmed retirement still blocks a successor")

        let closed = CoordinatorFixture(), closedSession = ApplicationWindowSession(), closedWindow = WindowFixture()
        var closedReleases = 0
        closed.seed(closedSession, closedWindow, release: { closedReleases += 1 })
        closedWindow.close()
        _ = await closed.retryRetiringOwners(deviceID: "device:phone")
        try expect(closedReleases == 0 && closed.hasRetiringOwners(deviceID: "device:phone"), "native close must use the same retirement barrier as route suspension")
        closedSession.nativeSession.cleanupPhysicallySettled = true
        closedSession.nativeSession.hostResourcesPhysicallySettled = true
        _ = await closed.retryRetiringOwners(deviceID: "device:phone")
        try expect(closedReleases == 1, "native close lost its eventual exact capacity release")

        let feature = CoordinatorFixture(), featureSession = ApplicationWindowSession(), featureWindow = WindowFixture()
        var featureReleases = 0
        feature.seed(featureSession, featureWindow, release: { featureReleases += 1 })
        feature.closeForFeaturePolicy(deviceID: "device:phone")
        _ = await feature.retryRetiringOwners(deviceID: "device:phone")
        try expect(featureWindow.closed && featureReleases == 0, "feature OFF must close UI without pretending unconfirmed cleanup succeeded")
        featureSession.nativeSession.cleanupPhysicallySettled = true
        featureSession.nativeSession.hostResourcesPhysicallySettled = true
        _ = await feature.retryRetiringOwners(deviceID: "device:phone")
        try expect(featureReleases == 1, "feature OFF stranded confirmed ownership")

        let shutdown = CoordinatorFixture(), shutdownSession = ApplicationWindowSession(), shutdownWindow = WindowFixture()
        var shutdownReleases = 0
        shutdown.seed(shutdownSession, shutdownWindow, release: { shutdownReleases += 1 })
        await shutdown.shutdownForApplicationTermination()
        try expect(shutdownWindow.closed && shutdownReleases == 0, "termination released an unconfirmed remote owner")
        shutdownSession.nativeSession.cleanupPhysicallySettled = true
        shutdownSession.nativeSession.hostResourcesPhysicallySettled = true
        _ = await shutdown.retryRetiringOwners(deviceID: "device:phone")
        try expect(shutdownReleases == 1, "termination lost the retained exact owner")
        print("PASS actual app retirement: route suspension, exact capacity, closed UI release, native close, feature OFF, termination and concurrent retries")
    }
}
