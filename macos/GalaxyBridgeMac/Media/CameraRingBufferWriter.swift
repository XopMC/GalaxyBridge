import CoreVideo
import Darwin
import Foundation
import VideoToolbox

final class CameraRingBufferWriter: @unchecked Sendable {
    static let fileName = "camera-ring-v2.bin"
    static let headerSize = 4_096
    static let slotCount = 3
    static let outputWidth = 1_920
    static let outputHeight = 1_080
    static let slotSize = outputWidth * outputHeight * 3 / 2

    private let descriptor: Int32
    private let pointer: UnsafeMutableRawPointer
    private let mappedSize = headerSize + slotCount * slotSize
    // POSIX record locks are process-owned; serialize every writer object,
    // including open/close, before taking the cross-process lock.
    private static let processLock = NSLock()
    private let normalizer = CameraFrameNormalizer(width: outputWidth, height: outputHeight)
    private let nowNanoseconds: @Sendable () -> UInt64
    private let publisherID: UInt64
    private var sequence: UInt64 = 0
    private var retired = false

    convenience init() throws {
        try self.init(url: nil)
    }

    init(
        url configuredURL: URL?,
        nowNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let url = try configuredURL ?? Self.ringURL()
        self.nowNanoseconds = nowNanoseconds
        publisherID = UInt64.random(in: 1 ... UInt64.max)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = Darwin.open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CameraRingError.posix(errno) }
        guard Self.lockFile(descriptor, type: F_WRLCK) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw CameraRingError.posix(code)
        }
        let lockedDescriptor = descriptor
        defer { Self.unlockFile(lockedDescriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw CameraRingError.posix(code)
        }
        // Never truncate an existing mapping beneath an open extension reader.
        guard status.st_size == 0 || status.st_size == off_t(mappedSize) else {
            Darwin.close(descriptor)
            throw CameraRingError.invalidLayout
        }
        if status.st_size == 0 && ftruncate(descriptor, off_t(mappedSize)) != 0 {
            let code = errno
            Darwin.close(descriptor)
            throw CameraRingError.posix(code)
        }
        let mapping = mmap(nil, mappedSize, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard mapping != MAP_FAILED, let mapping else {
            let code = errno
            Darwin.close(descriptor)
            throw CameraRingError.posix(code)
        }
        pointer = mapping
        memset(pointer, 0, mappedSize)
        store(UInt32(0x4742_4341), at: 0)
        store(UInt32(2), at: 4)
        store(UInt32(Self.outputWidth), at: 8)
        store(UInt32(Self.outputHeight), at: 12)
        store(UInt32(Self.outputWidth), at: 16)
        store(UInt32(Self.outputWidth), at: 20)
        store(UInt32(Self.slotCount), at: 24)
        store(UInt32(Self.slotSize), at: 28)
        store(publisherID, at: 64)
    }

    deinit {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        munmap(pointer, mappedSize)
        Darwin.close(descriptor)
    }

    func write(_ pixelBuffer: CVPixelBuffer, epoch: UInt32) throws {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2
        else { throw CameraRingError.unsupportedPixelFormat(format) }

        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard !retired else { throw CameraRingError.retiredPublisher }
        let normalized = try normalizer.normalize(pixelBuffer)
        CVPixelBufferLockBaseAddress(normalized, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(normalized, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(normalized, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(normalized, 1)
        else { throw CameraRingError.missingPlanes }
        guard Self.lockFile(descriptor, type: F_WRLCK) == 0 else { throw CameraRingError.posix(errno) }
        defer { Self.unlockFile(descriptor) }
        try verifyOwnership()

        let slot = Int(sequence % UInt64(Self.slotCount))
        let destination = pointer.advanced(by: Self.headerSize + slot * Self.slotSize)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(normalized, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(normalized, 1)
        for row in 0 ..< Self.outputHeight {
            memcpy(
                destination.advanced(by: row * Self.outputWidth),
                yBase.advanced(by: row * yStride),
                Self.outputWidth
            )
        }
        let uvDestination = destination.advanced(by: Self.outputWidth * Self.outputHeight)
        for row in 0 ..< Self.outputHeight / 2 {
            memcpy(
                uvDestination.advanced(by: row * Self.outputWidth),
                uvBase.advanced(by: row * uvStride),
                Self.outputWidth
            )
        }

        sequence &+= 1
        store(UInt32(slot), at: 32)
        store(nowNanoseconds(), at: 48)
        store(epoch, at: 56)
        // The sequence is the final publication marker. The cross-process file
        // lock prevents a reader from observing the slot while it is copied.
        store(sequence, at: 40)
    }

    /// Completion is the retirement barrier. Durable flush failure is reported;
    /// callers must not claim successful cleanup or activate a replacement then.
    func retire() throws {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard Self.lockFile(descriptor, type: F_WRLCK) == 0 else { throw CameraRingError.posix(errno) }
        defer { Self.unlockFile(descriptor) }
        try verifyOwnership()
        retired = true
        memset(pointer.advanced(by: Self.headerSize), 0, Self.slotCount * Self.slotSize)
        store(UInt32(0), at: 32)
        store(UInt64(0), at: 48)
        store(UInt32(0), at: 56)
        // v2 valid layout + nonzero publisher + zero sequence means inactive.
        store(UInt64(0), at: 40)
        guard msync(pointer, mappedSize, MS_SYNC) == 0 else { throw CameraRingError.posix(errno) }
        guard fsync(descriptor) == 0 else { throw CameraRingError.posix(errno) }
    }

    private func verifyOwnership() throws {
        guard UInt64(littleEndian: pointer.loadUnaligned(fromByteOffset: 64, as: UInt64.self)) == publisherID,
              UInt32(littleEndian: pointer.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) == 0x4742_4341,
              UInt32(littleEndian: pointer.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) == 2
        else { throw CameraRingError.replacedPublisher }
    }

    private func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        pointer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
    }

    private static func ringURL() throws -> URL {
        if let identifier = CameraAppGroupIdentifier.from(),
           let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return group.appendingPathComponent(fileName)
        }
        return try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("GalaxyBridge", isDirectory: true)
        .appendingPathComponent(fileName)
    }

    private static func lockFile(_ descriptor: Int32, type: Int32) -> Int32 {
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(type)
        fileLock.l_whence = Int16(SEEK_SET)
        // Fail promptly on external contention; never wedge the publication or
        // termination worker behind a dead/hung producer holding its lock.
        return fcntl(descriptor, F_SETLK, &fileLock)
    }

    private static func unlockFile(_ descriptor: Int32) {
        _ = lockFile(descriptor, type: F_UNLCK)
    }
}

private final class CameraFrameNormalizer {
    private let pool: CVPixelBufferPool
    private let transferSession: VTPixelTransferSession

    init(width: Int, height: Int) {
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ] as CFDictionary,
            &pool
        )
        precondition(poolStatus == kCVReturnSuccess && pool != nil)
        self.pool = pool!

        var transferSession: VTPixelTransferSession?
        let transferStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &transferSession
        )
        precondition(transferStatus == noErr && transferSession != nil)
        self.transferSession = transferSession!
        VTSessionSetProperty(
            transferSession!,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: kVTScalingMode_Trim
        )
    }

    deinit {
        VTPixelTransferSessionInvalidate(transferSession)
    }

    func normalize(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        var destination: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &destination
        )
        guard poolStatus == kCVReturnSuccess, let destination else {
            throw CameraRingError.pixelBuffer(poolStatus)
        }
        let transferStatus = VTPixelTransferSessionTransferImage(
            transferSession,
            from: source,
            to: destination
        )
        guard transferStatus == noErr else {
            throw CameraRingError.pixelTransfer(transferStatus)
        }
        return destination
    }
}

enum CameraRingError: Error, LocalizedError {
    case invalidLayout
    case retiredPublisher
    case replacedPublisher
    case posix(Int32)
    case unsupportedPixelFormat(OSType)
    case missingPlanes
    case pixelBuffer(CVReturn)
    case pixelTransfer(OSStatus)

    var errorDescription: String? { String(localized: "ERROR_CAMERA_OUTPUT") }
}
