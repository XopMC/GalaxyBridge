import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore
import VideoToolbox

/// Uses a real hardware encoder and decoder. No second frame or flush is sent
/// to the decoder: a stationary phone must not need another gesture to appear.
@main
private enum VideoToolboxDecoderSpec {
    static func main() throws {
        let encoded = EncodedSample()
        var encoder: VTCompressionSession?
        try check(VTCompressionSessionCreate(
            allocator: nil, width: 64, height: 64, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { reference, _, status, _, sample in
                guard let reference else { return }
                let result = Unmanaged<EncodedSample>.fromOpaque(reference).takeUnretainedValue()
                result.status = status
                result.sample = sample
                result.ready.signal()
            },
            refcon: Unmanaged.passUnretained(encoded).toOpaque(), compressionSessionOut: &encoder
        ))
        guard let encoder else { throw Failure("encoder missing") }
        defer { VTCompressionSessionInvalidate(encoder) }
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue))
        try check(VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse))
        var pixel: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel))
        guard let pixel else { throw Failure("pixel buffer missing") }
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0 ..< 2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), plane == 0 ? 96 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        try check(VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixel,
            presentationTimeStamp: CMTime(value: 1_000_000, timescale: 1_000_000), duration: .invalid,
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
            sourceFrameRefcon: nil, infoFlagsOut: nil))
        try check(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid))
        guard encoded.ready.wait(timeout: .now() + 3) == .success, let sample = encoded.sample,
              let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample)
        else { throw Failure("encoder did not produce fixture") }
        try check(encoded.status)
        var configuration = Data()
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
                parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil))
            guard let pointer else { throw Failure("parameter set missing") }
            configuration.append(contentsOf: [0, 0, 0, 1])
            configuration.append(pointer, count: size)
        }
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        try check(avcc.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        })
        var annexB = Data()
        var offset = 0
        while offset + 4 <= avcc.count {
            let size = avcc[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard offset + size <= avcc.count else { throw Failure("invalid encoded fixture") }
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(avcc[offset..<offset + size])
            offset += size
        }
        let presented = DispatchSemaphore(value: 0)
        let decoder = VideoToolboxDecoder(frameHandler: { buffer, _, epoch in
            if CVPixelBufferGetWidth(buffer) == 64 && epoch == 1 { presented.signal() }
        }, failureHandler: { error in
            fputs("decoder error: \(error)\n", stderr)
        })
        decoder.consume(.codec(.h264))
        decoder.consume(.videoSession(.init(width: 64, height: 64, clientResized: true)), epoch: 1)
        decoder.consume(.packet(.init(isConfiguration: true, isKeyFrame: false,
                                      presentationTimeUs: nil, payload: configuration)))
        decoder.consume(.packet(.init(isConfiguration: false, isKeyFrame: true,
                                      presentationTimeUs: 1_000_000, payload: annexB)))
        guard presented.wait(timeout: .now() + 1) == .success else {
            throw Failure("a lone keyframe must be presented without a second frame or decoder flush")
        }
        withExtendedLifetime(decoder) { decoder.invalidate() }
        print("PASS real VideoToolbox presents a stationary single-frame stream")
        try cameraRetirement(configuration: configuration, annexB: annexB)
    }

    private static func cameraRetirement(configuration: Data, annexB: Data) throws {
        let decodeQueue = DispatchQueue(label: "camera-spec.decode-boundary")
        let playoutQueue = DispatchQueue(label: "camera-spec.playout-boundary")
        let state = CameraSpecState()
        decodeQueue.suspend()
        let retiredBeforeDecode = VideoToolboxDecoder(cameraAdmission: { state.admitted }, queue: decodeQueue,
            playoutQueue: playoutQueue, frameHandler: { _, _, _ in state.recordFrame() },
            failureHandler: { _ in state.recordError() })
        feed(retiredBeforeDecode, configuration: configuration, annexB: annexB)
        state.admitted = false
        decodeQueue.resume()
        decodeQueue.sync {}
        playoutQueue.sync {}
        guard state.frames == 0 && state.errors == 0 else { throw Failure("retired packet crossed decode admission") }
        retiredBeforeDecode.invalidate()
        decodeQueue.sync {}

        let queued = DispatchSemaphore(value: 0)
        let active = CameraSpecState()
        let clock = MediaPlayoutClock()
        _ = clock.decision(track: .video, presentationTimeUs: 1_000_000, epoch: 1, now: 0)
        playoutQueue.suspend()
        let retiredAfterDecode = VideoToolboxDecoder(playoutClock: clock, nowSeconds: { 0.060 },
            cameraAdmission: { active.admitted }, queue: decodeQueue, playoutQueue: playoutQueue,
            cameraOutputQueued: { queued.signal() }, frameHandler: { _, _, _ in active.recordFrame() },
            failureHandler: { _ in active.recordError() })
        // .videoSession resets the clock, so establish decoder metadata first,
        // then anchor it before feeding the synthetic keyframe.
        retiredAfterDecode.consume(.codec(.h264))
        retiredAfterDecode.consume(.videoSession(.init(width: 64, height: 64, clientResized: true)), epoch: 1)
        decodeQueue.sync {}
        _ = clock.decision(track: .video, presentationTimeUs: 1_000_000, epoch: 1, now: 0)
        retiredAfterDecode.consume(.packet(.init(isConfiguration: true, isKeyFrame: false, presentationTimeUs: nil, payload: configuration)))
        retiredAfterDecode.consume(.packet(.init(isConfiguration: false, isKeyFrame: true, presentationTimeUs: 1_000_000, payload: annexB)))
        guard queued.wait(timeout: .now() + 3) == .success else { throw Failure("synthetic decode did not reach held playout queue") }
        active.admitted = false
        playoutQueue.resume()
        playoutQueue.sync {}
        guard active.frames == 0 && active.errors == 0 else { throw Failure("retired decoded frame crossed playout admission") }
        retiredAfterDecode.invalidate()
        decodeQueue.sync {}
        print("PASS camera permit revocation at independently held packet/decode and decoded/playout queues")

        let overload = CameraSpecState()
        let recovered = DispatchSemaphore(value: 0)
        decodeQueue.suspend()
        let bounded = VideoToolboxDecoder(cameraAdmission: { overload.admitted }, queue: decodeQueue,
            frameHandler: { _, _, _ in overload.recordFrame(); recovered.signal() },
            failureHandler: { _ in overload.recordError() })
        feed(bounded, configuration: configuration, annexB: annexB)
        for _ in 0 ..< 100 {
            bounded.consume(.packet(.init(isConfiguration: false, isKeyFrame: false,
                                         presentationTimeUs: 1_000_000, payload: annexB)))
        }
        decodeQueue.resume()
        decodeQueue.sync {}
        guard overload.frames == 0 && overload.errors == 1 else {
            throw Failure("camera queue overflow must coalesce error and discard pre-gap dependent frames")
        }
        bounded.consume(.packet(.init(isConfiguration: false, isKeyFrame: true,
                                     presentationTimeUs: 1_000_000, payload: annexB)))
        guard recovered.wait(timeout: .now() + 3) == .success else { throw Failure("camera must recover on a useful post-gap keyframe") }
        bounded.invalidate()
        decodeQueue.sync {}
        print("PASS bounded camera decode overload drops pre-gap frames and recovers on the next keyframe")
    }

    private static func feed(_ decoder: VideoToolboxDecoder, configuration: Data, annexB: Data) {
        decoder.consume(.codec(.h264))
        decoder.consume(.videoSession(.init(width: 64, height: 64, clientResized: true)), epoch: 1)
        decoder.consume(.packet(.init(isConfiguration: true, isKeyFrame: false, presentationTimeUs: nil, payload: configuration)))
        decoder.consume(.packet(.init(isConfiguration: false, isKeyFrame: true, presentationTimeUs: 1_000_000, payload: annexB)))
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw Failure("OSStatus \(status)") }
    }
}

private final class EncodedSample: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    var status: OSStatus = noErr
    var sample: CMSampleBuffer?
}

private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

private final class CameraSpecState: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var frameCount = 0
    private var errorCount = 0
    var admitted: Bool {
        get { lock.withLock { allowed } }
        set { lock.withLock { allowed = newValue } }
    }
    var frames: Int { lock.withLock { frameCount } }
    var errors: Int { lock.withLock { errorCount } }
    func recordFrame() { lock.withLock { frameCount += 1 } }
    func recordError() { lock.withLock { errorCount += 1 } }
}
