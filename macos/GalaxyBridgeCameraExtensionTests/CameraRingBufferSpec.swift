import CoreVideo
import Darwin
import Foundation

@main
enum CameraRingBufferSpec {
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--hold-lock" {
            let descriptor = Darwin.open(CommandLine.arguments[2], O_RDWR)
            guard descriptor >= 0 else { throw SpecError("lock child open failed") }
            defer { Darwin.close(descriptor) }
            var fileLock = Darwin.flock()
            fileLock.l_type = Int16(F_WRLCK)
            fileLock.l_whence = Int16(SEEK_SET)
            guard fcntl(descriptor, F_SETLK, &fileLock) == 0 else { throw SpecError("lock child could not lock") }
            FileHandle.standardOutput.write(Data([1]))
            _ = FileHandle.standardInput.readData(ofLength: 1)
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyBridgeCameraRingSpec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ringURL = directory.appendingPathComponent(CameraRingBufferWriter.fileName)
        let clock = SpecClock(now: 9_000_000_000)
        var writer: CameraRingBufferWriter? = try CameraRingBufferWriter(
            url: ringURL,
            nowNanoseconds: { clock.now }
        )
        let reader = CameraRingReader(url: ringURL, nowNanoseconds: { clock.now })
        let source = try makeNV12(width: 1_280, height: 720, luma: 96)

        try writer?.write(source, epoch: 7)
        let first = try require(reader.latestSample(), "the first ring frame must be readable")
        expect(first.width == 1_920 && first.height == 1_080,
               "every Camera Extension frame must be normalized to 1080p")
        expect(first.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
               "the ring must publish NV12 video-range pixels")
        expect(first.hostTimeNanoseconds == clock.now,
               "the ring timestamp must use the Mac host clock, not the Android media PTS")
        expect(first.sourceEpoch == 7 && first.sourceEpochChanged,
               "the first frame of a source epoch must be marked as a discontinuity")
        expect(!first.isPlaceholder, "a fresh producer frame must not be a placeholder")

        // Initialization is also the v2 inactive state: an already mapped reader
        // must invalidate its cache at once, without moving the test clock.
        writer = try CameraRingBufferWriter(url: ringURL, nowNanoseconds: { clock.now })
        let inactive = try require(reader.latestSample(), "inactive sample")
        expect(inactive.isPlaceholder,
               "inactive replacement must immediately invalidate retained pixels")

        // A host relaunch can publish sequence 1 after the previous process only
        // reached sequence 1. The publisher identity, not sequence ordering, must
        // make that equal-sequence frame visible and discontinuous.
        writer = nil
        writer = try CameraRingBufferWriter(url: ringURL, nowNanoseconds: { clock.now })
        clock.now += 33_333_333
        try writer?.write(source, epoch: 7)
        let equalSequenceRestart = try require(
            reader.latestSample(),
            "a restarted publisher's equal sequence must remain readable"
        )
        expect(equalSequenceRestart.sourceEpochChanged,
               "an equal-sequence publisher restart must be a discontinuity")

        clock.now += 33_333_333
        try writer?.write(source, epoch: 7)
        let continued = try require(reader.latestSample(), "a continued epoch must be readable")
        expect(!continued.sourceEpochChanged,
               "ordinary frames in the same source epoch must stay continuous")
        expect(continued.hostTimeNanoseconds == clock.now,
               "each frame must carry its own Mac host timestamp")

        clock.now += 33_333_333
        try writer?.write(source, epoch: 8)
        let restarted = try require(reader.latestSample(), "a replacement source epoch must be readable")
        expect(restarted.sourceEpoch == 8 && restarted.sourceEpochChanged,
               "a camera restart must reach CoreMediaIO as a discontinuity")

        writer = nil
        writer = try CameraRingBufferWriter(url: ringURL, nowNanoseconds: { clock.now })
        clock.now += 33_333_333
        try writer?.write(source, epoch: 8)
        let hostRestart = try require(reader.latestSample(), "a restarted Mac host must be readable")
        expect(hostRestart.sourceEpochChanged,
               "a restarted ring publisher must be a discontinuity even when Android reuses its epoch")

        clock.now += 750_000_001
        let missing = try require(reader.latestSample(), "a missing phone source must yield a frame")
        expect(missing.isPlaceholder, "a source missing for more than 750 ms must yield a placeholder")
        expect(missing.width == 1_920 && missing.height == 1_080,
               "the placeholder must preserve the advertised 1080p format")

        let newReader = CameraRingReader(url: ringURL, nowNanoseconds: { clock.now })
        let stale = try require(newReader.latestSample(), "stale new reader")
        expect(stale.isPlaceholder, "opening a stale ring must not renew its freshness")
        for luma: UInt8 in [51, 99, 147] {
            try writer?.write(makeNV12(width: 1_920, height: 1_080, luma: luma), epoch: 1)
        }
        let populated = try Data(contentsOf: ringURL)
        for (slot, luma) in [UInt8(51), 99, 147].enumerated() {
            // The current writer had sequence 1, so the next three use 1,2,0.
            expect(populated[CameraRingBufferWriter.headerSize + ((slot + 1) % 3) * CameraRingBufferWriter.slotSize] == luma,
                   "all three slots must contain their distinct synthetic patterns")
        }
        _ = reader.latestSample()
        try writer?.retire()
        let sanitized = try Data(contentsOf: ringURL)
        expect(sanitized.dropFirst(CameraRingBufferWriter.headerSize).allSatisfy { $0 == 0 },
               "retirement must zero every byte of all three slots")
        expect(sanitized[40 ..< 60].allSatisfy { $0 == 0 }, "sequence, timestamp and epoch must be zero")
        let retiredSample = try require(reader.latestSample(), "retired sample")
        expect(retiredSample.isPlaceholder, "same-reader retirement must be immediate with an unchanged clock")
        do {
            try writer?.write(source, epoch: 1)
            throw SpecError("retired writer accepted a frame")
        } catch CameraRingError.retiredPublisher {}

        let staleWriter = writer
        writer = try CameraRingBufferWriter(url: ringURL, nowNanoseconds: { clock.now })
        try writer?.write(source, epoch: 1)
        let replacementBytes = try Data(contentsOf: ringURL)
        do {
            try staleWriter?.retire()
            throw SpecError("stale publisher retired replacement")
        } catch CameraRingError.replacedPublisher {}
        expect(tryBytes(ringURL) == replacementBytes, "stale retirement must preserve replacement bytes")
        let resumed = try require(reader.latestSample(), "source restart sample")
        expect(!resumed.isPlaceholder && resumed.sourceEpochChanged, "same reader must resume with a discontinuity")
        let unretiredStaleWriter = writer
        writer = try CameraRingBufferWriter(url: ringURL, nowNanoseconds: { clock.now })
        try writer?.write(source, epoch: 1)
        let currentBytes = try Data(contentsOf: ringURL)
        do {
            try unretiredStaleWriter?.write(source, epoch: 2)
            throw SpecError("stale writer mutated replacement")
        } catch CameraRingError.replacedPublisher {}
        expect(tryBytes(ringURL) == currentBytes, "stale writes must preserve replacement bytes")
        let lockHolder = Process()
        let ready = Pipe()
        let release = Pipe()
        lockHolder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        lockHolder.arguments = ["--hold-lock", ringURL.path]
        lockHolder.standardOutput = ready
        lockHolder.standardInput = release
        try lockHolder.run()
        guard ready.fileHandleForReading.readData(ofLength: 1) == Data([1]) else { throw SpecError("lock child not ready") }
        do {
            try writer?.retire()
            throw SpecError("retirement ignored an external lock")
        } catch let CameraRingError.posix(code) {
            expect(code == EAGAIN || code == EACCES, "lock contention must return a bounded failure")
        }
        let unavailable = try require(reader.latestSample(), "unavailable reader sample")
        expect(unavailable.isPlaceholder, "unavailable producer must invalidate cached pixels")
        expect(tryBytes(ringURL) == currentBytes, "failed lock acquisition must not mutate pixels")
        release.fileHandleForWriting.write(Data([1]))
        lockHolder.waitUntilExit()
        expect(lockHolder.terminationStatus == 0, "external lock child failed")
        try writer?.retire()

        print("PASS Camera ring NV12, all-slot sanitization, immediate inactivity, stale publishers/timestamps and restart continuity")
    }

    private static func tryBytes(_ url: URL) -> Data { try! Data(contentsOf: url) }

    private static func makeNV12(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw SpecError("could not create source pixel buffer: \(status)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            memset(y, Int32(luma), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * height)
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * (height / 2))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SpecError(message) }
        return value
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}

private struct SpecError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class SpecClock: @unchecked Sendable {
    var now: UInt64
    init(now: UInt64) { self.now = now }
}
