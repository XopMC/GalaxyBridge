import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Testing
@testable import GalaxyBridgeMac

private final class WeakRecorderReference: @unchecked Sendable {
    weak var value: ScreenRecorder?

    init(_ value: ScreenRecorder?) {
        self.value = value
    }
}

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}

private final class AdmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    var acceptedCount: Int {
        lock.withLock { values.count(where: { $0 }) }
    }

    var rejectedCount: Int {
        lock.withLock { values.count(where: { !$0 }) }
    }

    func record(_ value: Bool) {
        lock.withLock { values.append(value) }
    }
}

@Suite(.serialized)
struct ScreenRecorderFinalizationTests {
    @Test(.timeLimit(.minutes(1)))
    func callerReleaseBeforeFinalizationStillProducesReadableFrames() async throws {
        let fixture = try RecordingFixture(name: "released-owner")
        defer { fixture.remove() }
        let workQueue = DispatchQueue(label: "synthetic.screen-recorder.released-owner")
        workQueue.suspend()
        var queueIsSuspended = true
        defer {
            if queueIsSuspended { workQueue.resume() }
        }

        var recorder: ScreenRecorder? = try ScreenRecorder(
            outputURL: fixture.outputURL,
            width: 64,
            height: 48,
            workQueue: workQueue
        )
        recorder?.append(try makeNV12Frame(width: 64, height: 48, luma: 40), presentationTime: CMTime(value: 300, timescale: 30))
        recorder?.append(try makeNV12Frame(width: 64, height: 48, luma: 80), presentationTime: CMTime(value: 301, timescale: 30))
        recorder?.append(try makeNV12Frame(width: 64, height: 48, luma: 120), presentationTime: CMTime(value: 302, timescale: 30))

        var accepted = false
        let results = AsyncStream<Result<URL, Error>> { continuation in
            accepted = recorder?.finish {
                continuation.yield($0)
                continuation.finish()
            } ?? false
        }
        #expect(accepted)
        let weakRecorder = WeakRecorderReference(recorder)
        recorder = nil

        try #require(weakRecorder.value != nil, "finish must own the recorder before queued finalization begins")
        workQueue.resume()
        queueIsSuspended = false

        let result = try #require(await firstResult(from: results))
        let outputURL = try result.get()
        #expect(outputURL == fixture.outputURL)

        let movie = try await readMovie(at: outputURL)
        #expect(movie.dimensions == CGSize(width: 64, height: 48))
        #expect(movie.frameDimensions == Array(repeating: CGSize(width: 64, height: 48), count: 3))
        #expect(movie.presentationTimes.count == 3)
        #expect(CMTimeCompare(movie.presentationTimes[0], CMTime(value: 0, timescale: 30)) == 0)
        #expect(CMTimeCompare(movie.presentationTimes[1], CMTime(value: 1, timescale: 30)) == 0)
        #expect(CMTimeCompare(movie.presentationTimes[2], CMTime(value: 2, timescale: 30)) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func repeatedFinishRequestsProduceOneTerminalCompletion() async throws {
        let fixture = try RecordingFixture(name: "repeated-finish")
        defer { fixture.remove() }
        let workQueue = DispatchQueue(label: "synthetic.screen-recorder.repeated-finish")
        workQueue.suspend()
        var queueIsSuspended = true
        defer {
            if queueIsSuspended { workQueue.resume() }
        }
        let recorder = try ScreenRecorder(
            outputURL: fixture.outputURL,
            width: 64,
            height: 48,
            workQueue: workQueue
        )
        recorder.append(try makeNV12Frame(width: 64, height: 48, luma: 64), presentationTime: .zero)

        let repeatedCallback = CallbackCounter()
        var firstAccepted = false
        var secondAccepted = true
        let results = AsyncStream<Result<URL, Error>> { continuation in
            firstAccepted = recorder.finish {
                continuation.yield($0)
                continuation.finish()
            }
            secondAccepted = recorder.finish { _ in repeatedCallback.increment() }
        }
        #expect(firstAccepted)
        #expect(secondAccepted == false)
        workQueue.resume()
        queueIsSuspended = false

        let result = try #require(await firstResult(from: results))
        #expect(try result.get() == fixture.outputURL)
        workQueue.sync {}
        let acceptedAfterCompletion = recorder.finish { _ in repeatedCallback.increment() }
        #expect(acceptedAfterCompletion == false)
        #expect(repeatedCallback.value == 0)
        let movie = try await readMovie(at: fixture.outputURL)
        #expect(movie.presentationTimes.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func simultaneousFinishRequestsAdmitExactlyOneCallback() async throws {
        let fixture = try RecordingFixture(name: "simultaneous-finish")
        defer { fixture.remove() }
        let workQueue = DispatchQueue(label: "synthetic.screen-recorder.simultaneous-finish")
        workQueue.suspend()
        var queueIsSuspended = true
        defer {
            if queueIsSuspended { workQueue.resume() }
        }
        let recorder = try ScreenRecorder(
            outputURL: fixture.outputURL,
            width: 64,
            height: 48,
            workQueue: workQueue
        )
        recorder.append(try makeNV12Frame(width: 64, height: 48, luma: 144), presentationTime: .zero)
        let admissions = AdmissionRecorder()
        let callbackCount = CallbackCounter()
        let (results, resultContinuation) = AsyncStream<Result<URL, Error>>.makeStream()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let accepted = recorder.finish { result in
                callbackCount.increment()
                resultContinuation.yield(result)
                resultContinuation.finish()
            }
            admissions.record(accepted)
        }

        #expect(admissions.acceptedCount == 1)
        #expect(admissions.rejectedCount == 31)
        workQueue.resume()
        queueIsSuspended = false
        let result = try #require(await firstResult(from: results))
        #expect(try result.get() == fixture.outputURL)
        workQueue.sync {}
        #expect(callbackCount.value == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func appendQueuedAfterFinishDoesNotReachTheMovie() async throws {
        let fixture = try RecordingFixture(name: "append-after-finish")
        defer { fixture.remove() }
        let workQueue = DispatchQueue(label: "synthetic.screen-recorder.append-after-finish")
        workQueue.suspend()
        var queueIsSuspended = true
        defer {
            if queueIsSuspended { workQueue.resume() }
        }
        let recorder = try ScreenRecorder(
            outputURL: fixture.outputURL,
            width: 64,
            height: 48,
            workQueue: workQueue
        )
        recorder.append(try makeNV12Frame(width: 64, height: 48, luma: 32), presentationTime: .zero)
        var accepted = false
        let results = AsyncStream<Result<URL, Error>> { continuation in
            accepted = recorder.finish {
                continuation.yield($0)
                continuation.finish()
            }
        }
        #expect(accepted)
        recorder.append(
            try makeNV12Frame(width: 64, height: 48, luma: 224),
            presentationTime: CMTime(value: 1, timescale: 30)
        )
        workQueue.resume()
        queueIsSuspended = false

        _ = try (try #require(await firstResult(from: results))).get()
        let movie = try await readMovie(at: fixture.outputURL)
        #expect(movie.presentationTimes.count == 1)
        #expect(CMTimeCompare(movie.presentationTimes[0], .zero) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyRecordingReportsFinalizationFailure() async throws {
        let fixture = try RecordingFixture(name: "empty")
        defer { fixture.remove() }
        let recorder = try ScreenRecorder(outputURL: fixture.outputURL, width: 64, height: 48)

        let result = await finish(recorder)

        guard case .failure(let error) = result else {
            Issue.record("an empty recording must not report a finalized movie")
            return
        }
        guard let recorderError = error as? ScreenRecorderError,
              case .noFrames = recorderError
        else {
            Issue.record("an empty recording must report ScreenRecorderError.noFrames")
            return
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func outputIOFailureIsReportedAsWriterFailure() async throws {
        let fixture = try RecordingFixture(name: "writer-failure")
        defer { fixture.remove() }
        let workQueue = DispatchQueue(label: "synthetic.screen-recorder.writer-failure")
        let recorder = try ScreenRecorder(
            outputURL: fixture.outputURL,
            width: 64,
            height: 48,
            workQueue: workQueue
        )
        var originalLimit = rlimit()
        guard getrlimit(RLIMIT_FSIZE, &originalLimit) == 0 else {
            throw RecordingTestFailure.fileSizeLimit(errno)
        }
        var failingLimit = originalLimit
        failingLimit.rlim_cur = 1
        let previousSignalHandler = signal(SIGXFSZ, SIG_IGN)
        guard setrlimit(RLIMIT_FSIZE, &failingLimit) == 0 else {
            _ = signal(SIGXFSZ, previousSignalHandler)
            throw RecordingTestFailure.fileSizeLimit(errno)
        }
        defer {
            _ = setrlimit(RLIMIT_FSIZE, &originalLimit)
            _ = signal(SIGXFSZ, previousSignalHandler)
        }
        recorder.append(try makeNV12Frame(width: 64, height: 48, luma: 96), presentationTime: .zero)

        let result = await finish(recorder)

        guard case .failure(let error) = result else {
            Issue.record("the writer must surface output I/O failure")
            return
        }
        guard let recorderError = error as? ScreenRecorderError,
              case .writer(let underlyingError) = recorderError
        else {
            Issue.record("output I/O failure must report ScreenRecorderError.writer")
            return
        }
        #expect(underlyingError != nil)
    }

    @Test
    func existingDestinationIsNotReplacedWhenWriterCreationFails() throws {
        let fixture = try RecordingFixture(name: "existing-destination")
        defer { fixture.remove() }
        let original = Data("existing user movie".utf8)
        try original.write(to: fixture.outputURL)

        var creationFailed = false
        do {
            _ = try ScreenRecorder(outputURL: fixture.outputURL, width: 64, height: 48)
        } catch {
            creationFailed = true
        }

        #expect(creationFailed)
        #expect(try Data(contentsOf: fixture.outputURL) == original)
    }
}

private struct RecordingFixture {
    let directory: URL
    let outputURL: URL

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("galaxybridge-screen-recorder-\(name)-\(UUID().uuidString)", isDirectory: true)
        outputURL = directory.appendingPathComponent("synthetic.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct ReadMovie {
    let dimensions: CGSize
    let frameDimensions: [CGSize]
    let presentationTimes: [CMTime]
}

private func finish(_ recorder: ScreenRecorder) async -> Result<URL, Error> {
    var accepted = false
    let results = AsyncStream<Result<URL, Error>> { continuation in
        accepted = recorder.finish {
            continuation.yield($0)
            continuation.finish()
        }
    }
    #expect(accepted)
    return await firstResult(from: results) ?? .failure(RecordingTestFailure.missingTerminalResult)
}

private func firstResult(
    from stream: AsyncStream<Result<URL, Error>>
) async -> Result<URL, Error>? {
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()
}

private func makeNV12Frame(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
    var optionalBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes as CFDictionary,
        &optionalBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer = optionalBuffer else {
        throw RecordingTestFailure.pixelBufferCreation(status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
          let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
    else {
        throw RecordingTestFailure.missingPixelBufferPlanes
    }
    memset(lumaBase, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * height)
    memset(chromaBase, 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * (height / 2))
    return pixelBuffer
}

private func readMovie(at url: URL) async throws -> ReadMovie {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first, "the finalized movie must contain a video track")
    let dimensions = try await track.load(.naturalSize)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
    )
    try #require(reader.canAdd(output))
    reader.add(output)
    try #require(reader.startReading())

    var frameDimensions: [CGSize] = []
    var presentationTimes: [CMTime] = []
    while let sample = output.copyNextSampleBuffer() {
        let imageBuffer = try #require(
            CMSampleBufferGetImageBuffer(sample),
            "AVAssetReader must return live decoded video frames"
        )
        frameDimensions.append(CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        ))
        presentationTimes.append(CMSampleBufferGetPresentationTimeStamp(sample))
    }
    #expect(reader.status == .completed)
    return ReadMovie(
        dimensions: dimensions,
        frameDimensions: frameDimensions,
        presentationTimes: presentationTimes
    )
}

private enum RecordingTestFailure: Error {
    case fileSizeLimit(Int32)
    case missingTerminalResult
    case missingPixelBufferPlanes
    case pixelBufferCreation(CVReturn)
}
