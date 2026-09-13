import Darwin
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import Testing
@testable import GalaxyBridgeMac

private final class DisplayObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [ScrcpyOwnedProcessOutputEvent] = []

    var events: [ScrcpyOwnedProcessOutputEvent] {
        lock.withLock { storedEvents }
    }

    func record(_ event: ScrcpyOwnedProcessOutputEvent) {
        lock.withLock { storedEvents.append(event) }
    }
}

private final class DeferredApplicationDisplayDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var storedActions: [@MainActor @Sendable () -> Void] = []

    var count: Int {
        lock.withLock { storedActions.count }
    }

    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { storedActions.append(action) }
    }

    @MainActor
    func deliverNext() {
        let action = lock.withLock { storedActions.removeFirst() }
        action()
    }
}

private struct OpenFileIdentity: Sendable {
    let device: dev_t
    let inode: ino_t

    init?(descriptor: Int32) {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { return nil }
        device = information.st_dev
        inode = information.st_ino
    }

    func isDetached(from descriptor: Int32) -> Bool {
        var information = stat()
        if fstat(descriptor, &information) == -1 {
            return errno == EBADF
        }
        return information.st_dev != device || information.st_ino != inode
    }
}

private final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

@Suite
struct ScrcpyApplicationDisplayOutputTests {
    @Test
    func parsesExactFragmentedMultipleLineAndCRLFRecords() {
        var parser = ScrcpyNewDisplayOutputParser()

        #expect(parser.append(Data("unrelated\n[server] INFO: New dis".utf8)).isEmpty)
        #expect(
            parser.append(Data("play: 1920x1080/420 (id=366)\r\nignored\n".utf8)) == [
                .announcement(.init(width: 1_920, height: 1_080, density: 420, displayID: 366)),
            ]
        )
    }

    @Test
    func rejectsMalformedNonPositiveAndOverflowRecordsThenRecovers() {
        var parser = ScrcpyNewDisplayOutputParser()
        let lines = [
            "[server] INFO: New display: 0x1080/420 (id=1)",
            "[server] INFO: New display: 1920x-1/420 (id=1)",
            "[server] INFO: New display: 1920x1080/0 (id=1)",
            "[server] INFO: New display: 2147483648x1080/420 (id=1)",
            "[server] INFO: New display: 1920x2147483648/420 (id=1)",
            "[server] INFO: New display: 1920x1080/2147483648 (id=1)",
            "[server] INFO: New display: 1920x1080/420 (id=0)",
            "[server] INFO: New display: 1920x1080/420 (id=-1)",
            "[server] INFO: New display: 1920x1080/420 (id=2147483648)",
            "[server] INFO: New display: 1920 x1080/420 (id=9)",
            "[server] INFO: New display: 1920x1080/420 (id=9) trailing",
            "[server] INFO: New display: 800x600/240 (id=17)",
        ]

        #expect(parser.append(Data((lines.joined(separator: "\n") + "\n").utf8)) == [
            .announcement(.init(width: 800, height: 600, density: 240, displayID: 17)),
        ])
    }

    @Test
    func discardsOversizedLineIncludingForgedSuffixAndRecoversAtNewline() {
        var parser = ScrcpyNewDisplayOutputParser()
        let forgedSuffix = "[server] INFO: New display: 1920x1080/420 (id=366)"
        let bytes = Data(repeating: 0x78, count: 1_025)
            + Data(forgedSuffix.utf8)
            + Data("\n[server] INFO: New display: 640x480/160 (id=23)\n".utf8)

        #expect(parser.append(bytes) == [
            .announcement(.init(width: 640, height: 480, density: 160, displayID: 23)),
        ])
        #expect(parser.retainedPartialLineByteCount == 0)
    }

    @Test
    func repeatedIdentityIsIdempotentAndDifferentDisplayConflicts() {
        var parser = ScrcpyNewDisplayOutputParser()
        let first = "[server] INFO: New display: 1920x1080/420 (id=366)\n"
        let repeated = "[server] INFO: New display: 1280x720/320 (id=366)\n"
        let conflicting = "[server] INFO: New display: 1920x1080/420 (id=367)\n"

        #expect(parser.append(Data(first.utf8)).count == 1)
        #expect(parser.append(Data(repeated.utf8)).isEmpty)
        #expect(parser.append(Data(conflicting.utf8)) == [.conflict])
        #expect(parser.append(Data(first.utf8)).isEmpty)
    }

    @Test
    func simultaneousReadersKeepIndependentIdentityStreams() async throws {
        let first = DisplayObservationRecorder()
        let second = DisplayObservationRecorder()
        let firstProcess = Process()
        let secondProcess = Process()
        firstProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        firstProcess.arguments = ["-c", "printf '[server] INFO: New display: 800x600/240 (id=31)\\n'"]
        secondProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        secondProcess.arguments = ["-c", "printf '[server] INFO: New display: 1024x768/320 (id=47)\\n'"]
        let firstObserver = try ScrcpyOwnedProcessOutputObserver(eventHandler: first.record)
        let secondObserver = try ScrcpyOwnedProcessOutputObserver(eventHandler: second.record)

        try run(firstProcess, observedBy: firstObserver)
        try run(secondProcess, observedBy: secondObserver)
        try await waitUntil {
            first.events.last == .ended && second.events.last == .ended
        }

        #expect(first.events.first == .announcement(.init(width: 800, height: 600, density: 240, displayID: 31)))
        #expect(second.events.first == .announcement(.init(width: 1_024, height: 768, density: 320, displayID: 47)))
    }

    @Test
    func childCanFillMoreThanPipeCapacityAndExitWithoutHanging() async throws {
        let recorder = DisplayObservationRecorder()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "head -c 262144 /dev/zero; printf '\\n[server] INFO: New display: 1920x1080/420 (id=73)\\n'",
        ]
        let observer = try ScrcpyOwnedProcessOutputObserver(eventHandler: recorder.record)

        try run(process, observedBy: observer)
        try await waitUntil { recorder.events.last == .ended }

        #expect(process.isRunning == false)
        #expect(recorder.events.contains(
            .announcement(.init(width: 1_920, height: 1_080, density: 420, displayID: 73))
        ))
    }

    @Test
    func launchFailureEOFAndCancellationFinishObservation() async throws {
        let failedRecorder = DisplayObservationRecorder()
        let failedObserver = try ScrcpyOwnedProcessOutputObserver(eventHandler: failedRecorder.record)
        let invalidADB = try ADBClient(testingExecutableURL: URL(fileURLWithPath: "/no/such/synthetic-executable"))
        var launchFailed = false
        do {
            _ = try invalidADB.launch(serial: "synthetic", arguments: [], outputObserver: failedObserver)
        } catch {
            launchFailed = true
        }
        #expect(launchFailed)
        try await waitUntil { failedRecorder.events.last == .ended }

        let eofRecorder = DisplayObservationRecorder()
        let eofProcess = Process()
        eofProcess.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let eofObserver = try ScrcpyOwnedProcessOutputObserver(eventHandler: eofRecorder.record)
        try run(eofProcess, observedBy: eofObserver)
        try await waitUntil { eofRecorder.events.last == .ended }

        let cancelledRecorder = DisplayObservationRecorder()
        let cancelledProcess = Process()
        cancelledProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        cancelledProcess.arguments = ["5"]
        let cancelledObserver = try ScrcpyOwnedProcessOutputObserver(eventHandler: cancelledRecorder.record)
        try run(cancelledProcess, observedBy: cancelledObserver)
        cancelledObserver.cancel()
        cancelledProcess.terminate()
        try await waitUntil { cancelledRecorder.events.last == .ended }
    }

    @Test
    func cancellationRetainsObserverAcrossGatedTeardownThenDetachesResources() async throws {
        let recorder = DisplayObservationRecorder()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        let teardownQueue = DispatchQueue(label: "synthetic.scrcpy-observer-gated-teardown")
        teardownQueue.suspend()
        var teardownQueueIsSuspended = true
        defer {
            if teardownQueueIsSuspended { teardownQueue.resume() }
            if process.isRunning { process.terminate() }
        }
        var observer: ScrcpyOwnedProcessOutputObserver? = try .init(
            eventHandler: recorder.record,
            queue: teardownQueue
        )
        try #require(observer).attach(to: process)
        let pipe = try #require(process.standardOutput as? Pipe)
        let readDescriptor = pipe.fileHandleForReading.fileDescriptor
        let writeDescriptor = pipe.fileHandleForWriting.fileDescriptor
        let readIdentity = try #require(OpenFileIdentity(descriptor: readDescriptor))
        let writeIdentity = try #require(OpenFileIdentity(descriptor: writeDescriptor))
        try process.run()
        try #require(observer).launchDidSucceed()

        let observerLifetime = WeakReference(observer)
        try #require(observer).cancel()
        observer = nil
        #expect(observerLifetime.value != nil)
        teardownQueue.resume()
        teardownQueueIsSuspended = false
        try await waitUntil {
            recorder.events.last == .ended
                && process.terminationHandler == nil
                && readIdentity.isDetached(from: readDescriptor)
                && writeIdentity.isDetached(from: writeDescriptor)
        }

        #expect(recorder.events.last == .ended)
        #expect(process.terminationHandler == nil)
        #expect(observerLifetime.value == nil)
    }

    @Test
    func defaultADBLaunchKeepsNullOutputBehavior() throws {
        let adb = try ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true"))

        let process = try adb.launch(serial: "synthetic", arguments: [])
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(process.standardOutput as? FileHandle === FileHandle.nullDevice)
    }

    private func run(_ process: Process, observedBy observer: ScrcpyOwnedProcessOutputObserver) throws {
        try observer.attach(to: process)
        do {
            try process.run()
            observer.launchDidSucceed()
        } catch {
            observer.launchDidFail()
            throw error
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw DisplayIdentitySpecFailure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
@Suite
struct ScrcpyApplicationDisplaySessionTests {
    @Test
    func queuedOldCallbacksDeliveredAfterRetryAndStopAreRejectedBySessionGeneration() async throws {
        let delivery = DeferredApplicationDisplayDelivery()
        let session = try ScrcpySession(
            serial: "synthetic",
            adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
            physicalDisplayPolicy: .leaveUnchanged,
            automaticDisplayManagement: false,
            applicationDisplayEventDelivery: delivery.enqueue
        )
        let application = try ScrcpyApplicationTarget(packageName: "com.example.synthetic")
        let oldObserver = try #require(try session.beginApplicationDisplayObservation(for: application))

        oldObserver.receive(Data("[server] INFO: New display: 1920x1080/420 (id=51)\n".utf8))
        try await waitUntil { oldObserver.isIdle }
        #expect(delivery.count == 1)

        let newObserver = try #require(try session.beginApplicationDisplayObservation(for: application))
        try await waitUntil { oldObserver.isIdle }
        newObserver.receive(Data("[server] INFO: New display: 1920x1080/420 (id=52)\n".utf8))
        try await waitUntil { newObserver.isIdle }
        #expect(delivery.count == 3)

        delivery.deliverNext()
        #expect(session.applicationDisplayIdentity == nil)
        delivery.deliverNext()
        #expect(session.applicationDisplayIdentity == nil)
        delivery.deliverNext()
        #expect(session.applicationDisplayIdentity?.displayID == 52)

        newObserver.receive(Data("[server] INFO: New display: 1920x1080/420 (id=53)\n".utf8))
        try await waitUntil { newObserver.isIdle }
        #expect(delivery.count == 1)
        session.stop()
        try await waitUntil { newObserver.isIdle }
        #expect(delivery.count == 2)
        delivery.deliverNext()
        #expect(session.applicationDisplayIdentity == nil)
        delivery.deliverNext()
        #expect(session.applicationDisplayIdentity == nil)
    }

    @Test
    func reusedDisplayIDGetsFreshGenerationAndIdentitySurvivesResize() async throws {
        let session = try makeSession()
        let application = try ScrcpyApplicationTarget(packageName: "com.example.synthetic")
        let newObserver = try #require(try session.beginApplicationDisplayObservation(for: application))

        newObserver.receive(Data("[server] INFO: New display: 1920x1080/420 (id=52)\n".utf8))
        try await waitUntil { session.applicationDisplayIdentity?.displayID == 52 }
        let identity = try #require(session.applicationDisplayIdentity)

        session.handleVideo(.videoSession(.init(width: 1_280, height: 720, clientResized: true)))
        #expect(session.applicationDisplayIdentity == identity)

        let reusedIDObserver = try #require(
            try session.beginApplicationDisplayObservation(for: application)
        )
        reusedIDObserver.receive(Data("[server] INFO: New display: 800x600/240 (id=52)\n".utf8))
        try await waitUntil { session.applicationDisplayIdentity?.displayID == 52 }
        let reusedIDIdentity = try #require(session.applicationDisplayIdentity)
        #expect(reusedIDIdentity.launchGeneration != identity.launchGeneration)
    }

    @Test
    func conflictInvalidatesCandidateAndNonApplicationLaunchDoesNotObserve() async throws {
        let session = try makeSession()
        let application = try ScrcpyApplicationTarget(packageName: "com.example.synthetic")
        let observer = try #require(try session.beginApplicationDisplayObservation(for: application))
        observer.receive(Data("[server] INFO: New display: 1920x1080/420 (id=61)\n".utf8))
        try await waitUntil { session.applicationDisplayIdentity?.displayID == 61 }

        observer.receive(Data("[server] INFO: New display: 1920x1080/420 (id=62)\n".utf8))
        try await waitUntil { session.applicationDisplayIdentity == nil }
        observer.receive(Data("[server] INFO: New display: 1920x1080/420 (id=61)\n".utf8))
        try await waitUntil { observer.isIdle }
        #expect(session.applicationDisplayIdentity == nil)

        #expect(try session.beginApplicationDisplayObservation(for: nil) == nil)
        #expect(session.applicationDisplayIdentity == nil)
    }

    private func makeSession() throws -> ScrcpySession {
        try ScrcpySession(
            serial: "synthetic",
            adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
            physicalDisplayPolicy: .leaveUnchanged,
            automaticDisplayManagement: false
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw DisplayIdentitySpecFailure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum DisplayIdentitySpecFailure: Error {
    case timedOut
}
