@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Darwin
import Foundation

private enum FixtureError: Error { case failed(String) }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw FixtureError.failed(message) } }
private final class PCMSource: @unchecked Sendable {
    let format: AVAudioFormat
    var cursor = 0
    init(format: AVAudioFormat) { self.format = format }
    func next(_ requested: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard cursor < 48_000 else { status.pointee = .endOfStream; return nil }
        let count = min(Int(requested), 48_000 - cursor)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        pcm.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 { for frame in 0..<count {
            pcm.floatChannelData![channel][frame] = Float(sin(Double(cursor + frame) * 2 * .pi * 440 / 48_000) * 0.2)
        } }
        cursor += count; status.pointee = .haveData
        return pcm
    }
}
private final class Failures: @unchecked Sendable {
    private let lock = NSLock(); private var errors: [Error] = []
    func record(_ error: Error) { lock.lock(); errors.append(error); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
}

@main struct ScreenRecorderAudioSpec {
    static func finish(_ recorder: ScreenRecorder) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in
            precondition(recorder.finish { continuation.resume(returning: $0) })
        }
    }
    static func aacPackets() throws -> [Data] {
        let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                          AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])!
        let converter = AVAudioConverter(from: pcm, to: aac)!
        let source = PCMSource(format: pcm)
        var packets: [Data] = []
        for _ in 0..<200 {
            let output = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: 8192)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, status in
                source.next(requested, status: status)
            }
            if let error { throw error }
            try require(status != .error, "AAC encoder failed")
            if output.packetCount > 0 {
                try require(output.packetCount == 1, "fixture packetization")
                packets.append(Data(bytes: output.data, count: Int(output.byteLength)))
            }
            if status == .endOfStream { break }
        }
        try require(packets.count >= 30 && packets.allSatisfy { !$0.isEmpty }, "real AAC packets missing")
        return packets
    }
    static func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        try require(status == kCVReturnSuccess && buffer != nil, "pixel buffer")
        let result = buffer!
        CVPixelBufferLockBaseAddress(result, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(result, 0), 90, CVPixelBufferGetBytesPerRowOfPlane(result, 0) * 48)
        memset(CVPixelBufferGetBaseAddressOfPlane(result, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(result, 1) * 24)
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-recording-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { if ProcessInfo.processInfo.environment["GB_KEEP_AUDIO_FIXTURE"] == nil { try? FileManager.default.removeItem(at: root) } }
        let configBacking = UnsafeMutableRawPointer.allocate(byteCount: 2, alignment: 1)
        defer { configBacking.deallocate() }
        configBacking.storeBytes(of: UInt8(0x11), as: UInt8.self)
        configBacking.advanced(by: 1).storeBytes(of: UInt8(0x90), as: UInt8.self)
        let config = try RecordingAACConfiguration(audioSpecificConfig:
            Data(bytesNoCopy: configBacking, count: 2, deallocator: .none))
        memset(configBacking, 0, 2)
        try require(config.audioSpecificConfig == Data([0x11, 0x90]), "ASC must own copied backend bytes")
        try require(config.sampleRate == 48_000 && config.channels == 2, "ASC parsing")
        for bad in [Data(), Data([0x29, 0x90]), Data([0x11, 0x91]), Data([0x11, 0x90, 0])] {
            do { _ = try RecordingAACConfiguration(audioSpecificConfig: bad); throw FixtureError.failed("bad ASC admitted") }
            catch ScreenRecorderError.audioConfiguration { }
        }
        let packets = try aacPackets()
        let sourceID = UUID(), errors = Failures()
        let output = root.appendingPathComponent("av.mov")
        let workQueue = DispatchQueue(label: "recording-borrowed-input")
        let recorder = try ScreenRecorder(outputURL: output, width: 64, height: 48,
            audioConfiguration: config, sourceID: sourceID, failureHandler: errors.record, workQueue: workQueue)
        // A pre-video unit is discarded, never independently rebased to audio time zero.
        recorder.appendAudio(packets[0], presentationTimeUs: 9_990_000, epoch: 1, sourceID: sourceID)
        for index in 0..<24 {
            let pts = UInt64(10_000_000 + index * 1024 * 1_000_000 / 48_000)
            recorder.append(try frame(), presentationTime: CMTime(value: Int64(pts), timescale: 1_000_000), epoch: 3, sourceID: sourceID)
            workQueue.suspend()
            let backing = UnsafeMutableRawPointer.allocate(byteCount: packets[index].count, alignment: 1)
            packets[index].copyBytes(to: backing.assumingMemoryBound(to: UInt8.self), count: packets[index].count)
            recorder.appendAudio(Data(bytesNoCopy: backing, count: packets[index].count, deallocator: .none),
                                 presentationTimeUs: pts + 10_000, epoch: 1, sourceID: sourceID)
            memset(backing, 0, packets[index].count)
            backing.deallocate()
            workQueue.resume()
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await finish(recorder).get()
        try require(errors.count == 0, "unexpected recorder failure")
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(video.count == 1 && audio.count == 1, "MOV must contain both tracks")
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video[0], outputSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let audioOutput = AVAssetReaderTrackOutput(track: audio[0], outputSettings: nil)
        reader.add(videoOutput); reader.add(audioOutput)
        try require(reader.startReading(), "reader start")
        var videoTimes: [CMTime] = [], audioTimes: [CMTime] = []
        var audioDuration = 0.0, compressedSamples = 0
        while let sample = videoOutput.copyNextSampleBuffer() {
            try require(CMSampleBufferGetImageBuffer(sample) != nil, "video decode")
            videoTimes.append(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        while let sample = audioOutput.copyNextSampleBuffer() {
            // Reader coalesces access units and emits edit markers. Output timing includes
            // the MOV edit/trim metadata; raw packet PTS alone is not its rendered position.
            let count = CMSampleBufferGetNumSamples(sample)
            if count > 0 {
                compressedSamples += count
                audioTimes.append(CMSampleBufferGetOutputPresentationTimeStamp(sample))
                audioDuration += CMSampleBufferGetOutputDuration(sample).seconds
            }
        }
        try require(reader.status == .completed, "reader completion")
        try require(videoTimes.count == 24 && compressedSamples >= 24 && !audioTimes.isEmpty, "mux packet/frame count")
        try require(abs(videoTimes[0].seconds) < 0.0001 && abs(audioTimes[0].seconds - 0.01) < 0.0001, "shared source PTS origin")
        try require(abs(audioDuration - 24.0 * 1024 / 48_000) < 0.001, "audio source duration drift")
        try require(abs(videoTimes.last!.seconds - 23.0 * 1024 / 48_000) < 0.0001, "video source duration drift")
        let audioReader = try AVAssetReader(asset: asset)
        let pcmOutput = AVAssetReaderTrackOutput(track: audio[0], outputSettings:
            [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        audioReader.add(pcmOutput)
        try require(audioReader.startReading(), "AAC decode start")
        var pcmFrames = 0
        while let sample = pcmOutput.copyNextSampleBuffer() { pcmFrames += CMSampleBufferGetNumSamples(sample) }
        try require(audioReader.status == .completed && pcmFrames > 20_000, "AAC must really decode to PCM")

        // Source/config/epoch changes become one visible failure and cannot report success.
        for kind in 0..<7 {
            let failure = Failures(), identity = UUID()
            let queue = DispatchQueue(label: "recording-failure-\(kind)")
            let candidate = try ScreenRecorder(outputURL: root.appendingPathComponent("failure-\(kind).mov"), width: 64, height: 48,
                audioConfiguration: config, sourceID: identity, failureHandler: failure.record, workQueue: queue)
            candidate.append(try frame(), presentationTime: .zero, epoch: 1, sourceID: identity)
            candidate.appendAudio(packets[0], presentationTimeUs: 10_000, epoch: 1, sourceID: identity)
            queue.sync {}
            switch kind {
            case 0: candidate.appendAudio(packets[1], presentationTimeUs: 31_333, epoch: 2, sourceID: identity)
            case 1: candidate.appendAudio(packets[1], presentationTimeUs: 31_333, epoch: 1, sourceID: UUID())
            case 2: candidate.validateAudioConfiguration(try RecordingAACConfiguration(audioSpecificConfig: Data([0x12, 0x10])), epoch: 1, sourceID: identity)
            case 3: candidate.appendAudio(Data(repeating: 0, count: 65_537), presentationTimeUs: 31_333, sourceID: identity)
            case 4: candidate.rejectAudioConfiguration()
            case 5: candidate.appendAudio(packets[1], presentationTimeUs: UInt64.max, sourceID: identity)
            default: candidate.appendAudio(packets[1], presentationTimeUs: 1, epoch: 1, sourceID: identity)
            }
            let result = await finish(candidate)
            if case .success = result { throw FixtureError.failed("invalid stream reported success") }
            try require(failure.count == 1, "terminal error must be visible exactly once")
        }
        let boundedQueue = DispatchQueue(label: "recording-admission-bound")
        let overflow = Failures()
        let bounded = try ScreenRecorder(outputURL: root.appendingPathComponent("bounded.mov"), width: 64, height: 48,
            audioConfiguration: config, failureHandler: overflow.record, workQueue: boundedQueue)
        boundedQueue.suspend()
        for _ in 0..<300 { bounded.validateAudioConfiguration(config) }
        let done = Task { await finish(bounded) }
        boundedQueue.resume()
        if case .success = await done.value { throw FixtureError.failed("queue overflow reported success") }
        try require(overflow.count == 1, "bounded queue must fail visibly once")
        let videoOnly = try ScreenRecorder(outputURL: root.appendingPathComponent("video-only.mov"), width: 64, height: 48)
        try require(!videoOnly.recordsAudio, "legacy caller unexpectedly records audio")
        videoOnly.rejectAudioConfiguration() // Late unsupported audio never breaks a deliberate video-only sink.
        videoOnly.append(try frame(), presentationTime: .zero)
        _ = try await finish(videoOnly).get()
        print("PASS real AAC converter -> MOV -> AVAssetReader: two tracks,source offset/duration,PCM decode,preroll,borrowed-input ownership,source/epoch/config/packet/queue fences")
    }
}
