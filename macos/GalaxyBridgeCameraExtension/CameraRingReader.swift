import CoreVideo
import Darwin
import Foundation

struct CameraRingSample {
    let pixelBuffer: CVPixelBuffer
    let hostTimeNanoseconds: UInt64
    let sourceEpoch: UInt32
    let sourceEpochChanged: Bool
    let isPlaceholder: Bool

    var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
    var pixelFormat: OSType { CVPixelBufferGetPixelFormatType(pixelBuffer) }
}

final class CameraRingReader {
    private static let fileName = "camera-ring-v2.bin"
    private static let headerSize = 4_096
    private static let slotCount = 3
    private static let width = 1_920
    private static let height = 1_080
    private static let slotSize = width * height * 3 / 2
    private let mappedSize = headerSize + slotCount * slotSize
    private var descriptor: Int32 = -1
    private var pointer: UnsafeMutableRawPointer?
    private var lastSequence: UInt64 = 0
    private var lastPublisherID: UInt64 = 0
    private var lastSourceEpoch: UInt32?
    private var cachedFrame: CVPixelBuffer?
    private var cachedEpoch: UInt32 = 0
    private var lastWasPlaceholder = true
    private var continuity = CameraFrameContinuityPolicy()
    private let configuredURL: URL?
    private let nowNanoseconds: () -> UInt64

    init(
        url: URL? = nil,
        nowNanoseconds: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        configuredURL = url
        self.nowNanoseconds = nowNanoseconds
    }

    deinit {
        if let pointer { munmap(pointer, mappedSize) }
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func latestSample() -> CameraRingSample? {
        let now = nowNanoseconds()
        let result = readFreshFrame(now: now)
        if case let .fresh(fresh) = result {
            _ = continuity.decide(hasFreshFrame: true, hasCachedFrame: cachedFrame != nil, nowNanoseconds: now)
            let epochChanged = lastWasPlaceholder ||
                lastSourceEpoch != fresh.sourceEpoch ||
                fresh.publisherRestarted
            cachedFrame = fresh.pixelBuffer
            cachedEpoch = fresh.sourceEpoch
            lastSourceEpoch = fresh.sourceEpoch
            lastWasPlaceholder = false
            return CameraRingSample(
                pixelBuffer: fresh.pixelBuffer,
                hostTimeNanoseconds: fresh.hostTimeNanoseconds == 0 ? now : fresh.hostTimeNanoseconds,
                sourceEpoch: fresh.sourceEpoch,
                sourceEpochChanged: epochChanged,
                isPlaceholder: false
            )
        }

        switch result {
        case .inactive, .unavailable:
            cachedFrame = nil
            lastSourceEpoch = nil
            lastSequence = 0
            lastPublisherID = 0
            continuity = CameraFrameContinuityPolicy()
        case .fresh, .unchanged: break
        }

        switch continuity.decide(hasFreshFrame: false, hasCachedFrame: cachedFrame != nil, nowNanoseconds: now) {
        case .fresh:
            return nil
        case .cached:
            guard let cachedFrame else { return nil }
            return CameraRingSample(
                pixelBuffer: cachedFrame,
                hostTimeNanoseconds: now,
                sourceEpoch: cachedEpoch,
                sourceEpochChanged: false,
                isPlaceholder: false
            )
        case .placeholder:
            guard let pixelBuffer = placeholder() else { return nil }
            let transition = !lastWasPlaceholder
            lastWasPlaceholder = true
            return CameraRingSample(
                pixelBuffer: pixelBuffer,
                hostTimeNanoseconds: now,
                sourceEpoch: cachedEpoch,
                sourceEpochChanged: transition,
                isPlaceholder: true
            )
        }
    }

    private struct FreshFrame {
        let pixelBuffer: CVPixelBuffer
        let hostTimeNanoseconds: UInt64
        let sourceEpoch: UInt32
        let publisherRestarted: Bool
    }

    private enum ReadResult {
        case fresh(FreshFrame), unchanged, inactive, unavailable
    }

    private func readFreshFrame(now: UInt64) -> ReadResult {
        if pointer == nil { openRing() }
        guard let pointer,
              Self.lockFile(descriptor, type: F_RDLCK) == 0
        else { return .unavailable }
        defer { Self.unlockFile(descriptor) }
        guard load(UInt32.self, at: 0) == 0x4742_4341,
              load(UInt32.self, at: 4) == 2,
              load(UInt32.self, at: 8) == UInt32(Self.width),
              load(UInt32.self, at: 12) == UInt32(Self.height),
              load(UInt32.self, at: 16) == UInt32(Self.width),
              load(UInt32.self, at: 20) == UInt32(Self.width),
              load(UInt32.self, at: 24) == UInt32(Self.slotCount),
              load(UInt32.self, at: 28) == UInt32(Self.slotSize)
        else { return .unavailable }

        let slot = Int(load(UInt32.self, at: 32))
        let sequence = load(UInt64.self, at: 40)
        let timestamp = load(UInt64.self, at: 48)
        let sourceEpoch = load(UInt32.self, at: 56)
        let publisherID = load(UInt64.self, at: 64)
        guard publisherID != 0, (0 ..< Self.slotCount).contains(slot) else { return .unavailable }
        guard sequence != 0 else { return .inactive }
        // Timestamp belongs to the producer's host clock, not reader-open time.
        guard timestamp != 0, now >= timestamp,
              now - timestamp <= continuity.staleAfterNanoseconds else { return .inactive }
        guard publisherID != lastPublisherID || sequence != lastSequence else { return .unchanged }
        guard let pixelBuffer = makePixelBuffer() else { return .unavailable }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let source = pointer.advanced(by: Self.headerSize + slot * Self.slotSize)
        copyPlane(
            source: source,
            destination: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
            width: Self.width,
            height: Self.height,
            destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        )
        copyPlane(
            source: source.advanced(by: Self.width * Self.height),
            destination: CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1),
            width: Self.width,
            height: Self.height / 2,
            destinationStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        )
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let publisherRestarted = lastPublisherID != 0 && publisherID != lastPublisherID
        lastPublisherID = publisherID
        lastSequence = sequence
        return .fresh(FreshFrame(pixelBuffer: pixelBuffer, hostTimeNanoseconds: timestamp,
                                 sourceEpoch: sourceEpoch, publisherRestarted: publisherRestarted))
    }

    private func openRing() {
        let url: URL
        if let configuredURL {
            url = configuredURL
        } else {
            guard let identifier = CameraAppGroupIdentifier.from(),
                  let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            else { return }
            url = root.appendingPathComponent(Self.fileName)
        }
        descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_size == off_t(mappedSize)
        else {
            Darwin.close(descriptor)
            descriptor = -1
            return
        }
        let mapping = mmap(nil, mappedSize, PROT_READ, MAP_SHARED, descriptor, 0)
        guard mapping != MAP_FAILED else {
            Darwin.close(descriptor)
            descriptor = -1
            return
        }
        pointer = mapping
    }

    private func copyPlane(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer?,
        width: Int,
        height: Int,
        destinationStride: Int
    ) {
        guard let destination else { return }
        for row in 0 ..< height {
            memcpy(destination.advanced(by: row * destinationStride), source.advanced(by: row * width), width)
        }
    }

    private func load<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        guard let pointer else { return 0 }
        return T(littleEndian: pointer.loadUnaligned(fromByteOffset: offset, as: T.self))
    }

    private func placeholder() -> CVPixelBuffer? {
        guard let pixelBuffer = makePixelBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let y = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            memset(y, 32, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * Self.height)
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * (Self.height / 2))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.width,
            Self.height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        return pixelBuffer
    }

    private static func lockFile(_ descriptor: Int32, type: Int32) -> Int32 {
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(type)
        fileLock.l_whence = Int16(SEEK_SET)
        return fcntl(descriptor, F_SETLK, &fileLock)
    }

    private static func unlockFile(_ descriptor: Int32) {
        _ = lockFile(descriptor, type: F_UNLCK)
    }
}
