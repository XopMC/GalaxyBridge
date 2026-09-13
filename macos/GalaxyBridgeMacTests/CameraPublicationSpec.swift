import CoreMedia
import CoreVideo
import Foundation

@main
enum CameraPublicationSpec {
    static func main() async throws {
        if ProcessInfo.processInfo.environment["CAMERA_FIX_CASE"] == "stop" {
            try await stopCompletionRegression()
            return
        }
        if ProcessInfo.processInfo.environment["CAMERA_FIX_CASE"] == "handoff" {
            try await loneHandoffFrame()
            return
        }
        let events = Events()
        let queue = DispatchQueue(label: "camera-spec.publication")
        let writer = FakeWriter(events: events)
        let publication = CameraPublication(worker: queue, makeWriter: { writer }, failure: { _, _ in events.append("failure") })
        let a = publication.start(deviceID: "A", companionID: "connection-A", connectionGeneration: 1, requestID: "start-A")!
        await drain(queue)
        let pixel = try syntheticNV12()
        let frameA = CameraPublicationFrame(pixelBuffer: pixel, presentationTime: .zero, epoch: 1, permit: a)

        // An actual executing write controls the barrier, not wall-clock sleeps.
        writer.blockNextWrite()
        publication.submit(frameA)
        await writer.waitUntilWriteEntered()
        let retirement = publication.retire(a)
        expect(!a.isAdmitted, "Stop must close admission synchronously")
        let termination = await MainActor.run { ApplicationTerminationCleanupCoordinator() }
        let replied = Signal()
        await MainActor.run {
            expect(termination.begin(cleanup: {
                _ = await retirement.wait()
                events.append("cleanup-completed")
            }, reply: { events.append("reply"); replied.signal() }), "first quit must start")
            expect(!termination.begin(cleanup: {}, reply: {}), "repeated quit must coalesce")
        }
        expect(!events.values.contains("reply"), "quit must wait for the executing write and retirement")
        publication.submit(frameA)
        writer.releaseWrite()
        _ = await retirement.wait()
        await replied.wait()
        expect(events.values == ["write-start", "write-end", "retire", "cleanup-completed", "reply"],
               "write, erase, cleanup and reply must occur in order: \(events.values)")

        let b = publication.start(deviceID: "B", companionID: "connection-B", connectionGeneration: 2, requestID: "start-B")!
        await drain(queue)
        let frameB = CameraPublicationFrame(pixelBuffer: pixel, presentationTime: .zero, epoch: 1, permit: b)
        publication.submit(frameB)
        await drain(queue)
        let beforeStale = events.values
        _ = await publication.retire(a).wait()
        publication.submit(frameA)
        await drain(queue)
        expect(publication.currentPermit === b && b.isAdmitted, "stale A retirement must preserve owner B")
        expect(events.values == beforeStale, "stale A callbacks must neither write nor retire B")
        expect(publication.owner(deviceID: "A") == nil, "non-owner Stop must not select B for retirement")
        expect(publication.owner(deviceID: "B", companionID: "connection-B", connectionGeneration: 1) == nil,
               "an old connection generation must not select the new owner")
        expect(publication.owner(deviceID: "B", requestID: "start-A") == nil,
               "a stale remote status request must not select the new owner")
        expect(publication.owner(deviceID: "B", companionID: "connection-B", connectionGeneration: 2, requestID: "start-B") === b,
               "a matching authenticated connection and initiating request must select its owner")

        // A frame queued before a worker hop is revoked before release. It must
        // not create a writer, even when Start itself is still queued.
        let queuedWorker = DispatchQueue(label: "camera-spec.queued")
        queuedWorker.suspend()
        let queuedEvents = Events()
        let queued = CameraPublication(worker: queuedWorker, makeWriter: {
            queuedEvents.append("create")
            return FakeWriter(events: queuedEvents)
        }, failure: { _, _ in queuedEvents.append("failure") })
        let old = queued.start(deviceID: "A", companionID: "same", connectionGeneration: 3, requestID: "old")!
        let oldFrame = CameraPublicationFrame(pixelBuffer: pixel, presentationTime: .zero, epoch: 1, permit: old)
        queued.submit(oldFrame)
        let closed = queued.retire(old)
        queuedWorker.resume()
        _ = await closed.wait()
        await drain(queuedWorker)
        expect(queuedEvents.values.isEmpty, "retired queued Start/frame must not lazily recreate the ring")

        // Preview's separate MainActor hop carries the old immutable permit.
        let previewEvents = Events()
        await MainActor.run {
            let preview = CameraPreviewDelivery { _ in previewEvents.append("preview") }
            let p = CameraPublicationPermit(deviceID: "A", companionID: "same", connectionGeneration: 3, requestID: "preview")
            preview.submit(CameraPublicationFrame(pixelBuffer: frameA.pixelBuffer, presentationTime: .zero, epoch: 1, permit: p))
            p.revoke()
            preview.clear()
        }
        await MainActor.run {}
        expect(previewEvents.values.isEmpty, "retired preview must not republish at its MainActor hop")

        // A bounded latest-frame mailbox preserves the most recent useful frame.
        queue.suspend()
        for epoch in 2 ... 100 {
            publication.submit(CameraPublicationFrame(pixelBuffer: pixel, presentationTime: .zero, epoch: UInt32(epoch), permit: b))
        }
        let writesBefore = writer.epochs.count
        queue.resume()
        await drain(queue)
        expect(writer.epochs.count == writesBefore + 1 && writer.epochs.last == 100,
               "a blocked worker must retain only the newest pending frame")

        // Cleanup failure propagates through quit's awaited result and blocks a
        // replacement. It is observable even if MainActor UI delivery is delayed.
        writer.failRetirement = true
        let c = publication.start(deviceID: "C", companionID: "connection-C", connectionGeneration: 4, requestID: "start-C")!
        await drain(queue)
        expect(!c.isAdmitted && events.values.last == "failure", "failed A-to-B erasure must fail closed")
        let failedQuit = publication.shutdown()
        if case .success = await failedQuit.wait() { fatalError("quit hid retirement failure") }
        expect(publication.start(deviceID: "D", companionID: "connection-D", connectionGeneration: 5, requestID: "start-D") == nil,
               "quit must permanently close Start admission")
        writer.failRetirement = false
        _ = await publication.shutdown().wait()
        try await commandFailureOrdering()
        try await stopCompletionRegression()
        try await loneHandoffFrame()
        try await scopedFailureDelivery()
        try checkLifecycleSource()
        print("PASS Camera publication: queued/in-flight retirement, A-to-B ownership, bounded latest frame, preview, quit awaiting/coalescing/failure")
    }

    private static func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private static func stopCompletionRegression() async throws {
        for mode in ["normal", "unavailable", "send-failure", "cleanup-failure"] {
            let events = Events()
            let queue = DispatchQueue(label: "camera-spec.stop-completion.\(mode)")
            let writer = FakeWriter(events: events)
            let publication = CameraPublication(worker: queue, makeWriter: { writer }, failure: { _, _ in events.append("cleanup-error") })
            let permit = publication.start(deviceID: "A", companionID: "A", connectionGeneration: 1, requestID: "start")!
            await drain(queue)
            writer.failRetirement = mode == "cleanup-failure"
            queue.suspend()
            let operation = CameraControlCommand.run(enabled: false, retireLocal: { publication.retire(permit) },
                control: { () -> Int? in
                    expect(!permit.isAdmitted, "revocation must precede control lookup")
                    return mode == "unavailable" ? nil : 1
                }, send: { _ in if mode == "send-failure" { throw SpecFailure.send } })
            let observed = await MainActor.run {
                operation.observe(isCurrent: { true }, apply: { completion in
                    if mode == "cleanup-failure" {
                        guard case .failure(SpecFailure.flush)? = completion.retirement else { fatalError("cleanup failure was hidden") }
                    } else {
                        guard case .success? = completion.retirement else { fatalError("missing exact retirement completion") }
                    }
                    events.append("command-completed")
                })
            }
            await MainActor.run { events.append("main-responsive") }
            expect(!events.values.contains("command-completed"), "production Stop completed before its held retirement barrier")
            queue.resume()
            await observed.value
            expect(events.values == ["main-responsive", mode == "cleanup-failure" ? "cleanup-error" : "retire", "command-completed"],
                   "production observed Stop must finish only after cleanup succeeds/fails: \(events.values)")
            writer.failRetirement = false
            if mode == "cleanup-failure" {
                let retry = CameraControlCommand.run(enabled: false, retireLocal: { publication.retire(permit) }, control: { 1 }, send: { _ in })
                let result = await retry.wait()
                guard case .success? = result.retirement else { fatalError("a failed retirement must remain retryable") }
            }
            _ = await publication.shutdown().wait()
        }
        print("PASS production observed Stop remains incomplete until normal/unavailable/send-failed/cleanup-failed retirement completes")
    }

    private static func loneHandoffFrame() async throws {
        let events = Events()
        let queue = DispatchQueue(label: "camera-spec.lone-handoff")
        let writer = FakeWriter(events: events)
        let publication = CameraPublication(worker: queue, makeWriter: { writer }, failure: { _, _ in events.append("failure") })
        let a = publication.start(deviceID: "A", companionID: "A", connectionGeneration: 1, requestID: "A-start")!
        await drain(queue)
        let pixel = try syntheticNV12()
        queue.suspend()
        publication.submit(CameraPublicationFrame(pixelBuffer: pixel, presentationTime: .zero, epoch: 11, permit: a))
        let b = publication.start(deviceID: "B", companionID: "B", connectionGeneration: 2, requestID: "B-start")!
        publication.submit(CameraPublicationFrame(pixelBuffer: pixel, presentationTime: .zero, epoch: 22, permit: b))
        queue.resume()
        await drain(queue)
        expect(writer.epochs == [22], "A's old drain consumed B's lone useful frame before B initialization")
        _ = await publication.shutdown().wait()
        print("PASS held-worker A submit, Start B, lone B submit publishes B without a second frame")
    }

    private static func scopedFailureDelivery() async throws {
        let events = Events()
        let queue = DispatchQueue(label: "camera-spec.failure-delivery")
        let writer = FakeWriter(events: events)
        let publication = CameraPublication(worker: queue, makeWriter: { writer }, failure: { _, _ in })
        let a = publication.start(deviceID: "A", companionID: "A", connectionGeneration: 1, requestID: "A-start")!
        await drain(queue)
        let delivered = Signal()
        let ui = Events()
        await MainActor.run {
            let errors = CameraFailureDelivery { _, permit in
                defer { delivered.signal() }
                guard publication.currentPermit === permit else { return }
                ui.append("error-applied")
            }
            errors.report(SpecFailure.flush, permit: a)
            _ = publication.start(deviceID: "B", companionID: "B", connectionGeneration: 2, requestID: "B-start")
        }
        await delivered.wait()
        expect(ui.values.isEmpty, "a queued A error must retain A's identity and not overwrite B")
        _ = await publication.shutdown().wait()
        print("PASS queued publication error retains original permit and cannot overwrite the replacement owner")
    }

    private static func commandFailureOrdering() async throws {
        let events = Events()
        let queue = DispatchQueue(label: "camera-spec.command")
        let writer = FakeWriter(events: events)
        let publication = CameraPublication(worker: queue, makeWriter: { writer }, failure: { _, _ in events.append("failure") })
        let a = publication.start(deviceID: "A", companionID: "A-connection", connectionGeneration: 1, requestID: "A-start")!
        await drain(queue)
        queue.suspend()
        let unavailable = CameraControlCommand.run(enabled: false, retireLocal: {
            publication.retire(a)
        }, control: { () -> Int? in
            expect(!a.isAdmitted, "Stop must revoke before unavailable control lookup")
            events.append("lookup-unavailable")
            return nil
        }, send: { _ in fatalError("unavailable control must not send") })
        guard case .unavailable = unavailable.outcome else { fatalError("missing control result") }
        expect(events.values == ["lookup-unavailable"], "unavailable Stop must not wait for the held worker")
        queue.resume()
        _ = await unavailable.wait()
        expect(events.values == ["lookup-unavailable", "retire"], "unavailable control must still finish local erasure")

        let b = publication.start(deviceID: "B", companionID: "B-connection", connectionGeneration: 2, requestID: "B-start")!
        await drain(queue)
        let beforeNonOwner = events.values
        let nonOwner = CameraControlCommand.run(enabled: false, retireLocal: {
            if let owner = publication.owner(deviceID: "A") { return publication.retire(owner) }
            return nil
        }, control: { 1 }, send: { _ in events.append("send-A-stop") })
        guard case .sent = nonOwner.outcome else { fatalError("non-owner Stop must still send") }
        let nonOwnerCompletion = await nonOwner.wait()
        expect(nonOwnerCompletion.retirement == nil, "non-owner Stop must not await or clear B")
        await drain(queue)
        expect(events.values == beforeNonOwner + ["send-A-stop"] && b.isAdmitted,
               "non-owner Stop must send without clearing B")

        queue.suspend()
        let throwingSend = CameraControlCommand.run(enabled: false, retireLocal: {
            publication.retire(b)
        }, control: {
            expect(!b.isAdmitted, "Stop must revoke before successful control lookup")
            return 1
        }, send: { _ in
            expect(!b.isAdmitted, "Stop must already be revoked when the sender throws")
            events.append("send-failed")
            throw SpecFailure.send
        })
        guard case .failed(SpecFailure.send) = throwingSend.outcome else { fatalError("sender error must remain observable") }
        let repeatedStop = CameraControlCommand.run(enabled: false, retireLocal: { publication.retire(b) }, control: { 1 }, send: { _ in })
        let revision = publication.revision
        let oldObserver = await MainActor.run {
            throwingSend.observe(isCurrent: { publication.revision == revision }, apply: { _ in events.append("stale-completion") })
        }
        let replacement = publication.start(deviceID: "C", companionID: "C-connection", connectionGeneration: 3, requestID: "C-start")!
        queue.resume()
        _ = await throwingSend.wait()
        _ = await repeatedStop.wait()
        await oldObserver.value
        await drain(queue)
        expect(events.values.suffix(2) == ["send-failed", "retire"], "sender failure must not bypass the local barrier")
        expect(replacement.isAdmitted, "old completion must not retire the replacement")
        expect(!events.values.contains("stale-completion"), "a delayed old operation must not overwrite newer state")

        // A failed Start send also owns its cleanup completion through the same
        // operation; there is no test-only barrier capture.
        queue.suspend()
        let failedStart = CameraControlCommand.run(enabled: true, retireLocal: { fatalError("Start used Stop path") },
            retireFailedStart: { publication.retire(replacement) }, control: { 1 }, send: { _ in throw SpecFailure.send })
        expect(!replacement.isAdmitted, "failed Start must revoke synchronously")
        queue.resume()
        let failedStartCompletion = await failedStart.wait()
        guard case .success? = failedStartCompletion.retirement else { fatalError("failed Start omitted cleanup completion") }
        _ = await publication.shutdown().wait()
        print("PASS production camera command: unavailable-control Stop, throwing sender Stop, non-owner remote Stop, asynchronous erasure")
    }

    // AppModel is intentionally not instantiated (that starts discovery and
    // accesses user state). These are source wiring checks, not a GUI test.
    private static func checkLifecycleSource() throws {
        let root = CommandLine.arguments[1]
        let source = try String(contentsOfFile: root + "/macos/GalaxyBridgeMac/AppModel.swift", encoding: .utf8)
        let camera = String(source.components(separatedBy: "    func configureCamera(")[1]
            .components(separatedBy: "    private func retireCamera(deviceID:")[0])
        expect(camera.contains("CameraControlCommand.run(") &&
               camera.contains("retireLocal: { retireCamera(deviceID: deviceID) }") &&
               camera.contains("control: { companionControl(for: deviceID) }"),
               "AppModel must call the dynamically tested camera command boundary")
        expect(camera.contains("retireFailedStart:") && camera.contains("return retireCamera(permit: startedPermit, reason: .startFailed)"),
               "failed Start send must retire its permit through the operation")
        expect(camera.contains("return operation.observe(") && camera.contains("cameraPublication.revision == revision"),
               "AppModel must return and observe the production completion with a current-revision guard")
        let quit = String(source.components(separatedBy: "    func shutdownForApplicationTermination() async {")[1]
            .components(separatedBy: "    func row(id:")[0])
        expect(quit.range(of: "cameraPublication.shutdown()")!.lowerBound < quit.range(of: "await session.stopAndWaitForCleanup()")!.lowerBound,
               "camera admission must close before existing awaited quit work")
        expect(quit.range(of: "adbIdentityBinder.shutdown()")!.lowerBound < quit.range(of: "await session.stopAndWaitForCleanup()")!.lowerBound,
               "Task2d terminal ADB admission must remain before awaited cleanup")
        expect(quit.contains("await cameraRetirement.wait()") && quit.contains(".failure(error)"),
               "quit must await and surface camera retirement failure")
        print("PASS camera AppModel source wiring: tested command seam connected, failed Start retired, terminal ADB preserved")
    }

    private static func syntheticNV12() throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess,
              let pixel else { throw SpecFailure.syntheticBuffer }
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0 ..< 2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), plane == 0 ? 96 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return pixel
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}

private enum SpecFailure: Error { case syntheticBuffer, flush, send }

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func append(_ value: String) { lock.withLock { recorded.append(value) } }
}

private final class Signal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                precondition(self.semaphore.wait(timeout: .now() + 10) == .success, "test signal watchdog expired")
                continuation.resume()
            }
        }
    }
}

private final class FakeWriter: CameraRingPublishing, @unchecked Sendable {
    private let events: Events
    private let lock = NSLock()
    private var block = false
    private var shouldFail = false
    private var writtenEpochs: [UInt32] = []
    private let entered = Signal()
    private let release = DispatchSemaphore(value: 0)
    init(events: Events) { self.events = events }
    var failRetirement: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }
    var epochs: [UInt32] { lock.withLock { writtenEpochs } }
    func blockNextWrite() { lock.withLock { block = true } }
    func waitUntilWriteEntered() async { await entered.wait() }
    func releaseWrite() { release.signal() }
    func write(_ pixelBuffer: CVPixelBuffer, epoch: UInt32) throws {
        events.append("write-start")
        let blocking = lock.withLock { let value = block; block = false; return value }
        if blocking {
            entered.signal()
            precondition(release.wait(timeout: .now() + 10) == .success, "test release watchdog expired")
        }
        lock.withLock { writtenEpochs.append(epoch) }
        events.append("write-end")
    }
    func retire() throws {
        if failRetirement { throw SpecFailure.flush }
        events.append("retire")
    }
}
