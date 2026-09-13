import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum QuicFixtureError: Error { case unsupported, status(OSStatus), malformed, capacity, timeout, child(Int32) }
struct QuicEncodedPacket: Sendable { let bytes: Data; let pts: UInt64; let key: Bool; let marker: UInt8 }
struct QuicVideoFixture: Sendable { let hevc: Bool; let configuration: Data; let packets: [QuicEncodedPacket]; var width: Int = 64; var height: Int = 64 }
struct QuicAudioFixture: Sendable { let configuration: Data; let packets: [QuicEncodedPacket] }

enum QuicCodecFixtureFactory {
    static func audio() throws -> QuicAudioFixture {
        try audio(sampleCount: 8_192)
    }
    static func audio(sampleCount: Int) throws -> QuicAudioFixture {
        guard (8_192...288_000).contains(sampleCount) else {throw QuicFixtureError.capacity}
        let packetCapacity=UInt32((sampleCount+1023)/1024+8)
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false),
              let aacFormat = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]),
              let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channels = pcm.floatChannelData,
              let converter = AVAudioConverter(from: pcmFormat, to: aacFormat) else { throw QuicFixtureError.unsupported }
        pcm.frameLength = AVAudioFrameCount(sampleCount)
        for frame in 0..<sampleCount { let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.001); channels[0][frame] = value; channels[1][frame] = value }
        let maximum = converter.maximumOutputPacketSize
        guard maximum > 0, maximum <= 65_536 else { throw QuicFixtureError.malformed }
        let output = AVAudioCompressedBuffer(format: aacFormat, packetCapacity: packetCapacity, maximumPacketSize: maximum)
        let input = QuicPCMInput(pcm)
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in input.next(status) }
        guard result != .error, error == nil, output.packetCount >= 5, output.packetCount <= packetCapacity,
              let descriptions = output.packetDescriptions, let cookie = converter.magicCookie else { throw QuicFixtureError.malformed }
        let configuration = try audioSpecificConfiguration(cookie)
        let packets = try (0..<Int(output.packetCount)).map { index -> QuicEncodedPacket in
            let description = descriptions[index]
            let offset = Int(description.mStartOffset); let count = Int(description.mDataByteSize)
            guard offset >= 0, count > 0, count <= 65_536, offset + count <= Int(output.byteLength) else { throw QuicFixtureError.malformed }
            return QuicEncodedPacket(bytes: Data(bytes: output.data.advanced(by: offset), count: count), pts: 1_000_000 + UInt64(index) * 1_024_000_000 / 48_000, key: false, marker: 0)
        }
        return QuicAudioFixture(configuration: configuration, packets: packets)
    }
    private static func audioSpecificConfiguration(_ cookie: Data) throws -> Data {
        // AVAudioConverter may return a raw ASC or an MPEG-4 descriptor cookie.
        // Extract exactly one two-byte DecoderSpecificInfo; never substitute a default.
        if cookie.count == 2 { guard cookie == Data([0x11,0x90]) else { throw QuicFixtureError.unsupported }; return cookie }
        guard cookie.count <= 4_096 else { throw QuicFixtureError.malformed }
        var candidates: [Data] = []
        for start in cookie.indices where cookie[start] == 5 {
            var at = start + 1; var length = 0; var ended = false
            for _ in 0..<4 { guard at < cookie.count else { break }; let byte = cookie[at]; at += 1; length = (length << 7) | Int(byte & 127); if byte & 128 == 0 { ended = true; break } }
            if ended, length == 2, at + length <= cookie.count { candidates.append(Data(cookie[at..<at + length])) }
        }
        guard candidates.count == 1, candidates[0] == Data([0x11,0x90]) else { throw QuicFixtureError.unsupported }
        return candidates[0]
    }
    static func stockVideo(_ fixture: QuicVideoFixture) -> [Data] {
        var geometry = Data([128,0,0,1])
        for dimension in [fixture.width, fixture.height] { var value = UInt32(dimension).bigEndian; withUnsafeBytes(of: &value) { geometry.append(contentsOf: $0) } }
        var records = [Data(fixture.hevc ? [104,50,54,53] : [104,50,54,52]), geometry]
        records.append(stockPacket(fixture.configuration, pts: 0, flags: 1 << 62))
        records.append(contentsOf: fixture.packets.map { stockPacket($0.bytes, pts: $0.pts, flags: $0.key ? 1 << 61 : 0) })
        return records
    }
    static func stockPacket(_ bytes: Data, pts: UInt64, flags: UInt64) -> Data {
        var header = Data(); var value = (pts | flags).bigEndian; var count = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &value) { header.append(contentsOf: $0) }; withUnsafeBytes(of: &count) { header.append(contentsOf: $0) }; header.append(bytes); return header
    }
    static func video(hevc: Bool) throws -> QuicVideoFixture {
        try video(hevc: hevc, frameCount: 5, width: 64, height: 64, keyframes: [0, 4], motion: false)
    }
    static func video(hevc: Bool, frameCount: Int, width: Int, height: Int, keyframes: Set<Int>, motion: Bool) throws -> QuicVideoFixture {
        guard (1...360).contains(frameCount), (64...1920).contains(width), (64...1080).contains(height), width % 2 == 0, height % 2 == 0,
              keyframes.contains(0), keyframes.allSatisfy({ (0..<frameCount).contains($0) }) else { throw QuicFixtureError.capacity }
        let output = QuicCompressionOutput(limit: frameCount)
        var session: VTCompressionSession?
        try check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, sample in
                guard let ref else { return }
                Unmanaged<QuicCompressionOutput>.fromOpaque(ref).takeUnretainedValue().add(status, sample)
            }, refcon: Unmanaged.passUnretained(output).toOpaque(), compressionSessionOut: &session))
        guard let session else { throw QuicFixtureError.malformed }
        defer { VTCompressionSessionInvalidate(session); withExtendedLifetime(output) {} }
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue))
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse))
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse))
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Baseline_AutoLevel))
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (motion ? 600 : 120) as CFNumber))
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_000_000 as CFNumber))
        try check(VTCompressionSessionPrepareToEncodeFrames(session))
        for index in 0..<frameCount {
            let pts = CMTime(value: 1_000_000 + (motion ? Int64(index) * 1_000_000 / 60 : Int64(index) * 16_667), timescale: 1_000_000)
            let frame = try nv12(marker: UInt8(truncatingIfNeeded: 40 + index * 30), width: width, height: height, motionIndex: motion ? index : nil)
            let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: keyframes.contains(index)] as CFDictionary
            try check(VTCompressionSessionEncodeFrame(session, imageBuffer: frame, presentationTimeStamp: pts,
                duration: CMTime(value: 16_667, timescale: 1_000_000), frameProperties: properties,
                sourceFrameRefcon: nil, infoFlagsOut: nil))
        }
        try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid))
        let samples = try output.take()
        guard samples.count == frameCount, let format = samples.first.flatMap(CMSampleBufferGetFormatDescription) else { throw QuicFixtureError.malformed }
        let configuration = try parameterSets(format, hevc: hevc)
        let packets = try samples.enumerated().map { index, sample -> QuicEncodedPacket in
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw QuicFixtureError.malformed }
            let count = CMBlockBufferGetDataLength(block)
            guard count > 0, count <= 4 * 1024 * 1024 else { throw QuicFixtureError.malformed }
            var lengthPrefixed = Data(count: count)
            try lengthPrefixed.withUnsafeMutableBytes { try check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)) }
            var annexB = Data(); var cursor = 0
            while cursor < count {
                guard cursor + 4 <= count else { throw QuicFixtureError.malformed }
                let length = lengthPrefixed[cursor..<cursor + 4].reduce(0) { ($0 << 8) | Int($1) }; cursor += 4
                guard length > 0, length <= count - cursor else { throw QuicFixtureError.malformed }
                annexB.append(contentsOf: [0,0,0,1]); annexB.append(lengthPrefixed[cursor..<cursor + length]); cursor += length
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
            let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default)
            guard pts.isValid, pts.value >= 0 else { throw QuicFixtureError.malformed }
            return QuicEncodedPacket(bytes: annexB, pts: UInt64(pts.value), key: key, marker: UInt8(truncatingIfNeeded: 40 + index * 30))
        }
        return QuicVideoFixture(hevc: hevc, configuration: configuration, packets: packets, width: width, height: height)
    }
    static func check(_ status: OSStatus) throws { if status != noErr { throw QuicFixtureError.status(status) } }
    static func nv12(marker: UInt8, width: Int = 64, height: Int = 64, motionIndex: Int? = nil) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer))
        guard let buffer else { throw QuicFixtureError.malformed }
        try check(CVPixelBufferLockBaseAddress(buffer, [])); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            guard let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { throw QuicFixtureError.malformed }
            memset(address, plane == 0 ? Int32(marker) : 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else { throw QuicFixtureError.malformed }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        var random: UInt32 = 0x12345678 &+ UInt32(motionIndex ?? 0)
        for y in 0..<height { for x in 0..<width {
            random ^= random << 13; random ^= random >> 17; random ^= random << 5
            if !(24..<40).contains(x) || !(24..<40).contains(y) { luma[y * stride + x] = UInt8(16 + random % 220) }
        } }
        return buffer
    }
    private static func parameterSets(_ format: CMFormatDescription, hevc: Bool) throws -> Data {
        var result = Data(); var count = 0; var lengthSize: Int32 = 0; var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?; var size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
            try check(status)
            guard let pointer, size > 0, count <= 32, lengthSize == 4, result.count + size + 4 <= 65_536 else { throw QuicFixtureError.malformed }
            result.append(contentsOf: [0,0,0,1]); result.append(pointer, count: size); index += 1
        } while index < count
        return result
    }
}

private final class QuicCompressionOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private var failure: OSStatus = noErr
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func add(_ status: OSStatus, _ sample: CMSampleBuffer?) {
        lock.withLock { if status != noErr { failure = status }; if let sample { if samples.count < limit { samples.append(sample) } else { failure = kVTParameterErr } } }
    }
    func take() throws -> [CMSampleBuffer] { try lock.withLock { try QuicCodecFixtureFactory.check(failure); return samples } }
}

private final class QuicPCMInput: @unchecked Sendable {
    private let pcm: AVAudioPCMBuffer
    private let lock = NSLock(); private var supplied = false
    init(_ pcm: AVAudioPCMBuffer) { self.pcm = pcm }
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock { if supplied { status.pointee = .endOfStream; return nil }; supplied = true; status.pointee = .haveData; return pcm }
    }
}
