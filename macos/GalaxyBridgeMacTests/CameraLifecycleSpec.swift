import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore

@main
enum CameraLifecycleSpec {
    static func main() async throws {
        if ProcessInfo.processInfo.environment["CAMERA_LIFECYCLE_FIX_CASE"] == "duplicate-revoke" {
            try await duplicateIngressRevocationAfterFailure()
            return
        }
        if ProcessInfo.processInfo.environment["CAMERA_LIFECYCLE_FIX_CASE"] == "start-retry" {
            try await retainedWriterStartRetry()
            return
        }
        // A remote producer's readiness is independent of local publication.
        var state = CameraLifecycleState()
        let remote = CameraRemoteStatus(phase: .streaming, reasonCode: "")
        expect(CameraStatusViewState.resolve(remote: remote, local: state).titleKey == "CAMERA_STATUS_PRODUCER_READY", "STREAMING before a write is only producer ready")
        expect(state.publish(), "first actual write must transition")
        expect(!state.publish(), "repeated write must coalesce")
        expect(CameraStatusViewState.resolve(remote: remote, local: state).titleKey == "CAMERA_STATUS_STREAMING", "actual publication must be visible")
        expect(state.retire(reason: .generationLoss), "generation loss must end local publication")
        expect(!state.publish(), "late success must not revive a retired attempt")
        expect(!state.retire(reason: .stop), "duplicate retirement must not replace the first reason")
        expect(state.retirementReason == .generationLoss, "actual retirement cause must survive later Stop")
        expect(CameraStatusViewState.resolve(remote: remote, local: state).titleKey == "CAMERA_STATUS_RESTART_REQUIRED", "cached STREAMING cannot revive local state")
        expect(CameraStatusViewState.resolve(remote: remote, local: state).remoteServiceMayBeRunning, "remote Stop remains relevant with no local publication")
        expect(state.completeRetirement(succeeded: false), "cleanup failure must remain visible")
        expect(CameraStatusViewState.resolve(remote: remote, local: state).isFailure, "cleanup failure cannot be hidden by STREAMING")
        expect(state.retire(reason: .stop), "failed erasure may retry its exact barrier")
        expect(state.completeRetirement(succeeded: true), "retry completion must be visible")
        expect(!state.completeRetirement(succeeded: true), "duplicate completion must coalesce")
        var reordered = CameraRemoteStatus(phase: .streaming, reasonCode: "")
        expect(!reordered.receive(phase: .starting, reasonCode: ""), "same-attempt starting cannot regress streaming")
        expect(reordered.receive(phase: .failed, reasonCode: "camera_permission_required"), "terminal remote status must be accepted")
        expect(!reordered.receive(phase: .streaming, reasonCode: ""), "terminal remote status dominates replay")
        expect(!CameraStatusCorrelation.accepts(currentRequestID: nil, incomingRequestID: "arbitrary-private-request"), "missing request is never freshness")
        expect(!CameraStatusCorrelation.accepts(currentRequestID: "", incomingRequestID: ""), "empty request is never freshness")
        try await publicationTransitions()
        try await generationLossAndReplay()
        try await typedRetirementCommands()
        try await duplicateIngressRevocationAfterFailure()
        try await retainedWriterStartRetry()
        print("PASS camera lifecycle: producer/local separation, terminal dominance, remote reorder, strict correlation, diagnostic counts/privacy, held real writer, coalesced delivery, owner replacement")
    }

    private static func duplicateIngressRevocationAfterFailure() async throws {
        let queue = DispatchQueue(label: "camera-fix1-spec.duplicate-revoke")
        let diagnostics = Diagnostics()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-duplicate-revoke-\(UUID().uuidString).ring")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = HeldWriter(url: url)
        let publication = CameraPublication(worker: queue, makeWriter: { try writer.create(); return writer }, diagnostic: { diagnostics.append($0) }, failure: { _, _ in })
        let a = publication.start(deviceID: "A", companionID: "peer-A", connectionGeneration: 5, requestID: "A-start")!
        let ingress = CameraMediaIngress()
        let session = CameraVideoSession(permit: a, publication: publication, preview: CameraPreviewDelivery { _ in }, failure: { _ in })
        ingress.install(session)
        await drain(queue)
        writer.failRetire = true
        let failed = publication.retire(a, reason: .stop)
        guard case .failure = await failed.wait() else { fatalError("fixture must fail real retirement before ingress invalidation") }
        expect(a.lifecycle.phase == .cleanupFailed, "real failed cleanup must be visible")
        let beforeDuplicate = diagnostics.values
        ingress.invalidate()
        session.invalidate()
        expect(a.lifecycle.phase == .cleanupFailed, "duplicate ingress revocation must preserve completed cleanup failure")
        expect(diagnostics.values == beforeDuplicate, "duplicate revoke must not invent a retry event or completion")
        expect(a.lifecycle.retirementReason == .stop && !a.isAdmitted, "duplicate generation-loss revoke must preserve original Stop reason and admission")
        let remote = CameraRemoteStatus(phase: .streaming, reasonCode: "")
        expect(CameraStatusViewState.resolve(remote: remote, local: a.lifecycle).titleKey == "CAMERA_STATUS_CLEANUP_FAILED", "dedicated failure status must remain until a real retry")
        writer.failRetire = false
        queue.suspend()
        let retry = publication.retire(a, reason: .generationLoss)
        expect(retry !== failed && a.lifecycle.phase == .retiring, "explicit real retry must own a fresh exact-permit barrier")
        expect(diagnostics.values.map(\.kind) == [.started, .retiring, .cleanupFailed, .retiring], "only real retry adds the fourth transition")
        ingress.invalidate()
        queue.resume()
        guard case .success = await retry.wait() else { fatalError("real retry failed") }
        expect(a.lifecycle.phase == .retired && diagnostics.values.last?.reason == .stop, "retry completion must preserve the original Stop cause")
        expect(diagnostics.values.count == 5, "one attempt, two real cleanup operations must have exactly five events")
        _ = await publication.shutdown().wait()
        print("PASS I1 failed retirement before actual ingress invalidation preserves cleanupFailed and exact counts until real retry")
    }

    @MainActor private static func retainedWriterStartRetry() async throws {
        let queue = DispatchQueue(label: "camera-fix1-spec.start-retry")
        let diagnostics = Diagnostics()
        let notifications = Transitions()
        let delivery = HeldDelivery()
        let presentation = RetainedPresentation()
        let uiTransition = CameraPublicationTransitionDelivery(schedule: { delivery.append($0) }, deliver: { _ in presentation.refresh() })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-start-retry-\(UUID().uuidString).ring")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = HeldWriter(url: url)
        let publication = CameraPublication(worker: queue, makeWriter: { try writer.create(); return writer }, diagnostic: { diagnostics.append($0) }, transition: { notifications.append($0); uiTransition.submit($0) }, failure: { _, _ in })
        let a = publication.start(deviceID: "A", companionID: "peer-A", connectionGeneration: 8, requestID: "A-start")!
        presentation.retain(a)
        await drain(queue)
        let pixel = try syntheticNV12()
        publication.submit(.init(pixelBuffer: pixel, presentationTime: .zero, epoch: 1, permit: a))
        await drain(queue)
        writer.failRetire = true
        guard case .failure = await publication.retire(a, reason: .stop).wait() else { fatalError("fixture must retain failed writer A") }
        expect(a.lifecycle.phase == .cleanupFailed && publication.currentPermit == nil, "A must be failed and no longer owner before B starts")
        delivery.flush()
        expect(presentation.statuses["A"]?.titleKey == "CAMERA_STATUS_CLEANUP_FAILED", "A must visibly fail before the held retry notification")
        writer.failRetire = false
        queue.suspend()
        let b = publication.start(deviceID: "B", companionID: "peer-B", connectionGeneration: 9, requestID: "B-start")!
        presentation.retain(b)
        publication.submit(.init(pixelBuffer: pixel, presentationTime: .zero, epoch: 2, permit: b))
        queue.resume()
        await drain(queue)
        expect(a.lifecycle.phase == .retired, "Start B must complete the actual retained-A cleanup retry lifecycle")
        expect(a.lifecycle.retirementReason == .stop, "Start retry must retain A's original Stop cause")
        expect(publication.currentPermit === b && b.isAdmitted && b.lifecycle.phase == .publishing, "A retry must preserve B and B's lone first publication")
        let aEvents = diagnostics.values.filter { $0.attemptOrdinal == a.attemptOrdinal }
        expect(aEvents.map(\.kind) == [.started, .publishing, .retiring, .cleanupFailed, .retiring, .retired], "actual A retry and completion must each be diagnosed exactly once")
        expect(aEvents.suffix(4).allSatisfy { $0.reason == .stop }, "A retry/completion must never be relabelled as B's reason")
        expect(notifications.values.filter { $0.ordinal == a.attemptOrdinal }.map(\.phase) == [.publishing, .retiring, .cleanupFailed, .retiring, .retired], "actual A retry and completion must notify the retained A state")
        expect(diagnostics.values.filter { $0.attemptOrdinal == b.attemptOrdinal }.map(\.kind) == [.started, .publishing], "A cleanup cannot emit a B retirement")
        expect(delivery.count == 1, "held distinct-device A retry and B publication must coalesce to one UI task")
        delivery.flush()
        expect(presentation.statuses["A"]?.titleKey == "CAMERA_STATUS_RESTART_REQUIRED", "coalesced B delivery must expose completed A cleanup")
        expect(presentation.statuses["B"]?.titleKey == "CAMERA_STATUS_STREAMING", "coalesced delivery must derive B from its current authoritative permit")
        _ = await publication.retire(a, reason: .remoteFailed).wait()
        expect(publication.currentPermit === b && b.lifecycle.phase == .publishing, "stale A barrier retry/completion must not mutate B")
        presentation.remove(deviceID: "A")
        uiTransition.submit(a)
        delivery.flush()
        expect(presentation.statuses["A"] == nil && presentation.statuses["B"]?.titleKey == "CAMERA_STATUS_STREAMING", "late removed A notification must only refresh current B and never restore removed A")
        _ = await publication.shutdown().wait()
        print("PASS I2 failed A cleanup followed by Start B retries/completes/notifies A with original cause and publishes lone B frame")
    }

    private static func typedRetirementCommands() async throws {
        let queue = DispatchQueue(label: "camera-lifecycle-spec.commands")
        let events = Diagnostics()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-reasons-\(UUID().uuidString).ring")
        defer { try? FileManager.default.removeItem(at: url) }
        let publication = CameraPublication(worker: queue, makeWriter: { try CameraRingBufferWriter(url: url) }, diagnostic: { events.append($0) }, failure: { _, _ in })
        for reason: CameraRetirementReason in [.stop, .replacement, .generationLoss, .remoteStopped, .remoteFailed, .startFailed, .pairingRevoked] {
            let permit = publication.start(deviceID: "phone", companionID: "peer", connectionGeneration: 7, requestID: "command")!
            await drain(queue)
            queue.suspend()
            let operation = CameraControlCommand.run(enabled: reason == .startFailed,
                retireLocal: { publication.retire(permit, reason: reason) },
                retireFailedStart: { publication.retire(permit, reason: .startFailed) },
                control: { 1 }, send: { _ in if reason == .startFailed { throw Failure() } })
            expect(!permit.isAdmitted && permit.lifecycle.phase == .retiring, "command retirement must synchronously dominate held worker/status")
            expect(permit.lifecycle.retirementReason == reason, "command must carry actual typed retirement reason")
            queue.resume()
            let result = await operation.wait()
            guard case .success? = result.retirement else { fatalError("command omitted exact retirement barrier") }
            expect(permit.lifecycle.phase == .retired, "command must await retirement completion")
            expect(events.values.last?.reason == reason && events.values.last?.kind == .retired, "completion must carry original command reason")
        }
        expect(events.values.count == 21, "seven attempts must have exactly start, retirement and completion events")
        _ = await publication.shutdown().wait()
    }

    @MainActor private static func generationLossAndReplay() async throws {
        let queue = DispatchQueue(label: "camera-lifecycle-spec.reconnect")
        let supervisor = CompanionLogicalSessionRecoverySupervisor()
        let generationA = supervisor.beginSession(companionID: "peer")!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-replay-\(UUID().uuidString).ring")
        defer { try? FileManager.default.removeItem(at: url) }
        let publication = CameraPublication(worker: queue, makeWriter: { try CameraRingBufferWriter(url: url) }, diagnostic: { _ in }, failure: { _, _ in })
        let a = publication.start(deviceID: "phone", companionID: "peer", connectionGeneration: generationA, requestID: "A")!
        let ingressA = CameraMediaIngress()
        ingressA.install(CameraVideoSession(permit: a, publication: publication, preview: CameraPreviewDelivery { _ in }, failure: { _ in }))
        await drain(queue)
        let pixel = try syntheticNV12()
        publication.submit(.init(pixelBuffer: pixel, presentationTime: .zero, epoch: 1, permit: a))
        await drain(queue)
        let remoteA = CameraRemoteStatus(phase: .streaming, reasonCode: "")
        expect(CameraStatusViewState.resolve(remote: remoteA, local: a.lifecycle).titleKey == "CAMERA_STATUS_STREAMING", "A must really publish before bundle loss")
        // The AppModel's non-camera-channel recovery path retires first, then
        // closes the logical bundle. Exercise those production components.
        let barrierA = publication.retire(a, reason: .generationLoss)
        expect(supervisor.recover(companionID: "peer", generation: generationA, cancelChannels: [{ ingressA.invalidate() }], scheduleDelayedReconnect: { _ in }, publishModel: { _ in }), "current bundle loss must be accepted")
        _ = await barrierA.wait()
        let generationB = supervisor.beginSession(companionID: "peer")!
        let emptyIngress = CameraMediaIngress()
        emptyIngress.consume(MediaPacket(flags: [.keyFrame], epoch: 9, presentationTimeUs: 0, payload: Data([0, 0, 0, 1, 0x65])))
        await drain(queue)
        expect(publication.currentPermit == nil, "reconnected unsolicited media cannot acquire ownership")
        expect(CameraStatusViewState.resolve(remote: remoteA, local: a.lifecycle).titleKey == "CAMERA_STATUS_RESTART_REQUIRED", "cached old STREAMING must remain inactive")
        let inactive = try Data(contentsOf: url)
        expect(inactive[40..<48].allSatisfy { $0 == 0 } && inactive[4096...].allSatisfy { $0 == 0 }, "replayed remote status/empty ingress must leave all slots inactive")
        let b = publication.start(deviceID: "phone", companionID: "peer", connectionGeneration: generationB, requestID: "B")!
        await drain(queue)
        expect(!CameraStatusCorrelation.accepts(currentRequestID: b.requestID, incomingRequestID: a.requestID), "delayed A status cannot mutate B")
        expect(publication.owner(deviceID: "phone", companionID: "peer", connectionGeneration: generationA, requestID: "B") == nil, "old authenticated generation cannot select B")
        expect(publication.owner(deviceID: "other-phone") == nil, "foreign local Stop cannot select B")
        var remoteB = CameraRemoteStatus(phase: .starting, reasonCode: "")
        publication.submit(.init(pixelBuffer: pixel, presentationTime: .zero, epoch: 2, permit: b))
        await drain(queue)
        expect(CameraStatusViewState.resolve(remote: remoteB, local: b.lifecycle).titleKey == "CAMERA_STATUS_STREAMING", "publication before status is locally publishing")
        expect(remoteB.receive(phase: .streaming, reasonCode: ""), "current producer status must be admitted")
        expect(CameraStatusViewState.resolve(remote: remoteB, local: b.lifecycle).titleKey == "CAMERA_STATUS_STREAMING", "status after publication must preserve readiness")
        _ = await publication.retire(a, reason: .remoteStopped).wait()
        expect(b.isAdmitted && b.lifecycle.phase == .publishing, "A's delayed retirement observer cannot revoke B")
        _ = await publication.shutdown().wait()
        expect(b.lifecycle.retirementReason == .quit && b.lifecycle.phase == .retired, "quit must carry its reason through awaited cleanup")
    }

    private static func publicationTransitions() async throws {
        let queue = DispatchQueue(label: "camera-lifecycle-spec.writer")
        let clock = Clock()
        let events = Diagnostics()
        let delivery = HeldDelivery()
        let presented = Presented()
        let transition = CameraPublicationTransitionDelivery(schedule: { delivery.append($0) }, deliver: { presented.record($0) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-lifecycle-\(UUID().uuidString).ring")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = HeldWriter(url: url)
        let publication = CameraPublication(worker: queue, makeWriter: { try writer.create(); return writer },
            now: { clock.now }, diagnostic: { events.append($0) }, transition: { transition.submit($0) }, failure: { _, _ in })
        let a = publication.start(deviceID: "private-device-A", companionID: "private-peer-A", connectionGeneration: 42, requestID: "private-request-A")!
        await drain(queue)
        expect(a.lifecycle.phase == .starting, "permit/writer creation cannot establish publication")
        let pixel = try syntheticNV12()
        writer.holdNextWrite()
        publication.submit(.init(pixelBuffer: pixel, presentationTime: .zero, epoch: 1, permit: a))
        await writer.entered.wait()
        expect(a.lifecycle.phase == .starting, "held real write must not signal readiness")
        clock.set(12_000_000)
        let retired = publication.retire(a, reason: .generationLoss)
        expect(!a.isAdmitted && a.lifecycle.phase == .retiring, "retirement closes state and permit synchronously")
        writer.release.signal()
        _ = await retired.wait()
        expect(a.lifecycle.phase == .retired, "barrier completes only after erasure")
        expect(!events.values.contains { $0.kind == .publishing }, "late held write completion must not publish")
        let raw = try Data(contentsOf: url)
        expect(raw[40..<48].allSatisfy { $0 == 0 } && raw[4096...].allSatisfy { $0 == 0 }, "retired ring sequence and all slots must be inactive")
        let b = publication.start(deviceID: "private-device-B", companionID: "private-peer-B", connectionGeneration: 43, requestID: "private-request-B")!
        await drain(queue)
        for _ in 0..<100 {
            publication.submit(.init(pixelBuffer: pixel, presentationTime: .zero, epoch: 2, permit: b))
            await drain(queue)
        }
        expect(b.lifecycle.phase == .publishing, "B's first successful write must publish without a remote status")
        expect(events.values.filter { $0.kind == .publishing }.count == 1, "100 writes must produce exactly one publication transition")
        expect(delivery.count == 1, "held UI must have at most one transition task across replacement")
        _ = await publication.retire(a, reason: .remoteFailed).wait()
        expect(publication.currentPermit === b && b.isAdmitted, "late A retirement cannot change B")
        await delivery.flush()
        let displayed = await presented.ordinals
        expect(displayed == [b.attemptOrdinal], "coalesced stale A UI delivery must not overwrite B")
        clock.set(27_000_000)
        _ = await publication.retire(b, reason: .stop).wait()
        await delivery.flush()
        expect(events.values.map(\.kind) == [.started, .retiring, .retired, .started, .publishing, .retiring, .retired], "diagnostics must record each actual lifecycle transition/completion exactly once")
        expect(events.values[2].elapsedMilliseconds == 12, "elapsed time must use the injected monotonic clock")
        expect(events.values[2].reason == .generationLoss, "completion must retain generation-loss cause")
        expect(events.values.last?.elapsedMilliseconds == 15, "replacement has its own elapsed origin")
        expect(events.values.allSatisfy { !$0.serialized.contains("private") && !$0.serialized.contains("UUID") }, "diagnostic serialization must exclude private identities")
        let failing = publication.start(deviceID: "private-device-C", companionID: "private-peer-C", connectionGeneration: 44, requestID: "private-request-C")!
        await drain(queue)
        writer.failWrite = true
        publication.submit(.init(pixelBuffer: pixel, presentationTime: .zero, epoch: 3, permit: failing))
        await drain(queue)
        expect(!failing.isAdmitted && failing.lifecycle.retirementReason == .publicationFailure, "actual writer failure must end publication with a typed cause")
        expect(failing.lifecycle.phase != .publishing, "failed first write must never signal readiness")
        writer.failRetire = true
        if case .success = await publication.retire(failing, reason: .publicationFailure).wait() { fatalError("cleanup failure hidden") }
        expect(failing.lifecycle.phase == .cleanupFailed, "all-slot cleanup failure stays visible")
        expect(events.values.last?.kind == .cleanupFailed, "cleanup failure must be diagnosed without raw error")
        expect(!events.values.map(\.serialized).joined().contains("arbitrary-secret-error"), "arbitrary errors cannot enter lifecycle diagnostics")
        writer.failRetire = false
        _ = await publication.shutdown().wait()
        expect(failing.lifecycle.phase == .retired, "quit retry must complete a failed retained writer even with no current owner")
        expect(events.values.suffix(2).map(\.kind) == [.retiring, .retired], "quit retry must diagnose retained cleanup completion")
    }

    private static func drain(_ queue: DispatchQueue) async { await withCheckedContinuation { c in queue.async { c.resume() } } }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) { if !value() { fatalError(message) } }
    private static func syntheticNV12() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &value) == kCVReturnSuccess, let value else { throw Failure() }
        CVPixelBufferLockBaseAddress(value, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(value, plane), plane == 0 ? 96 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(value, plane) * CVPixelBufferGetHeightOfPlane(value, plane))
        }
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }
}

private struct Failure: Error, LocalizedError { var errorDescription: String? { "arbitrary-secret-error /private/path 192.0.2.4" } }
private final class Clock: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 0
    var now: UInt64 { lock.withLock { value } }
    func set(_ n: UInt64) { lock.withLock { value = n } }
}
private final class Diagnostics: @unchecked Sendable {
    private let lock = NSLock(); private var items: [CameraLifecycleDiagnostic] = []
    var values: [CameraLifecycleDiagnostic] { lock.withLock { items } }
    func append(_ value: CameraLifecycleDiagnostic) { lock.withLock { items.append(value) } }
}
private final class Transitions: @unchecked Sendable {
    struct Value: Sendable { let ordinal: UInt64; let phase: CameraLifecycleState.Phase }
    private let lock = NSLock(); private var items: [Value] = []
    var values: [Value] { lock.withLock { items } }
    func append(_ permit: CameraPublicationPermit) { lock.withLock { items.append(.init(ordinal: permit.attemptOrdinal, phase: permit.lifecycle.phase)) } }
}
private final class HeldDelivery: @unchecked Sendable {
    private let lock = NSLock(); private var actions: [@MainActor @Sendable () -> Void] = []
    var count: Int { lock.withLock { actions.count } }
    func append(_ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { actions.append(action) } }
    @MainActor func flush() { let pending = lock.withLock { let x = actions; actions = []; return x }; pending.forEach { $0() } }
}
@MainActor private final class Presented {
    var ordinals: [UInt64] = []
    func record(_ permit: CameraPublicationPermit) { ordinals.append(permit.attemptOrdinal) }
}
@MainActor private final class RetainedPresentation {
    private var permits: [String: CameraPublicationPermit] = [:]
    private var remote: [String: CameraRemoteStatus] = [:]
    private(set) var statuses: [String: CameraStatusViewState] = [:]
    func retain(_ permit: CameraPublicationPermit) {
        permits[permit.deviceID] = permit
        remote[permit.deviceID] = .init(phase: .streaming, reasonCode: "")
    }
    func remove(deviceID: String) { permits.removeValue(forKey: deviceID); remote.removeValue(forKey: deviceID) }
    func refresh() {
        statuses = CameraStatusViewState.resolveRetained(remoteStatuses: remote, localStates: permits.mapValues(\.lifecycle))
    }
}
private final class Signal: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait() async { await withCheckedContinuation { c in DispatchQueue.global().async { precondition(self.semaphore.wait(timeout: .now() + 10) == .success); c.resume() } } }
}
private final class HeldWriter: CameraRingPublishing, @unchecked Sendable {
    private let url: URL
    private var writer: CameraRingBufferWriter?
    let entered = Signal(); let release = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var held = false; private var writeFailure = false; private var retireFailure = false
    var failWrite: Bool { get { lock.withLock { writeFailure } } set { lock.withLock { writeFailure = newValue } } }
    var failRetire: Bool { get { lock.withLock { retireFailure } } set { lock.withLock { retireFailure = newValue } } }
    init(url: URL) { self.url = url }
    func create() throws { writer = try CameraRingBufferWriter(url: url) }
    func holdNextWrite() { lock.withLock { held = true } }
    func write(_ pixel: CVPixelBuffer, epoch: UInt32) throws {
        let hold = lock.withLock { let x = held; held = false; return x }
        if hold { entered.signal(); precondition(release.wait(timeout: .now() + 10) == .success) }
        if failWrite { throw Failure() }
        try writer!.write(pixel, epoch: epoch)
    }
    func retire() throws { if failRetire { throw Failure() }; try writer!.retire() }
}
