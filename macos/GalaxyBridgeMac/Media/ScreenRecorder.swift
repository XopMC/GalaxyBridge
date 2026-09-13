import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

enum ScreenRecorderError: Error, LocalizedError {
    case cannotAddInput
    case noFrames
    case cancelled
    case writer(Error?)
    case audioConfiguration, audioPacket, sourceChanged, invalidTimestamp, backpressure, noAudio

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: String(localized: "ERROR_RECORDING_START")
        case .noFrames: String(localized: "ERROR_RECORDING_NO_FRAMES")
        case .cancelled: String(localized: "ERROR_RECORDING_CANCELLED")
        case .writer, .audioConfiguration, .audioPacket, .sourceChanged, .invalidTimestamp, .backpressure, .noAudio:
            String(localized: "ERROR_RECORDING_SAVE")
        }
    }
}

final class ScreenRecorder: @unchecked Sendable {
    private typealias Completion = @Sendable (Result<URL, Error>) -> Void

    private enum Lifecycle {
        case recording
        case finishing
        case finished
    }

    private let queue: DispatchQueue
    private let finishAdmissionLock = NSLock()
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var finishWasRequested = false
    private var lifecycle = Lifecycle.recording
    private var failure: Error?
    private let failureHandler: (@Sendable (Error) -> Void)?
    private let audioConfiguration: RecordingAACConfiguration?
    private let audioInput: AVAssetWriterInput?
    private let audioFormat: CMAudioFormatDescription?
    private let sourceID: UUID?
    private var videoEpoch: UInt32?
    private var audioEpoch: UInt32?
    private var lastAudioTime: CMTime?
    private var audioSampleCount = 0
    private struct AudioPacket { let payload: Data; let pts: CMTime }
    private var audioPreRoll: [AudioPacket] = []
    private var preRollBytes = 0
    private var queuedBytes = 0
    private var queuedCount = 0
    private var failedAdmission = false
    var recordsAudio: Bool { audioConfiguration != nil }
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime = .zero

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        audioConfiguration: RecordingAACConfiguration? = nil,
        sourceID: UUID? = nil,
        failureHandler: (@Sendable (Error) -> Void)? = nil,
        workQueue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.recorder")
    ) throws {
        queue = workQueue
        self.audioConfiguration = audioConfiguration
        self.sourceID = sourceID
        self.failureHandler = failureHandler
        self.audioFormat = try audioConfiguration?.formatDescription()
        if let audioFormat {
            self.audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            self.audioInput?.expectsMediaDataInRealTime = true
        } else { self.audioInput = nil }
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 20_000_000,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalKey: 120,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = true
        if audioConfiguration != nil {
            input.mediaTimeScale = 1_000_000
            writer.movieTimeScale = 1_000_000
        }
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw ScreenRecorderError.cannotAddInput }
        writer.add(input)
        if let audioInput {
            guard writer.canAdd(audioInput) else { throw ScreenRecorderError.cannotAddInput }
            writer.add(audioInput)
        }
        guard writer.startWriting() else { throw ScreenRecorderError.writer(writer.error) }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32? = nil, sourceID: UUID? = nil) {
        let frame = RecorderPixelBuffer(pixelBuffer)
        let bytes = max(CVPixelBufferGetDataSize(pixelBuffer), CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        admit(bytes: bytes) { [self] in
            guard validateSource(sourceID, epoch: epoch, audio: false) else { return }
            appendOnQueue(frame.value, presentationTime: presentationTime)
        }
    }

    func appendAudio(_ payload: Data, presentationTimeUs: UInt64, epoch: UInt32? = nil, sourceID: UUID? = nil) {
        guard !payload.isEmpty, payload.count <= 64 * 1024, presentationTimeUs <= UInt64(Int64.max) else {
            reportFailure(.audioPacket); return
        }
        admitPrepared(bytes: payload.count) { [self] in
            // Native media packets may borrow backend memory. Copy inside bounded admission
            // synchronously, before the producer returns and releases its NativeMediaWork.
            let ownedPayload = payload.withUnsafeBytes { Data($0) }
            return { [self] in
                guard audioConfiguration != nil else { failOnQueue(ScreenRecorderError.audioConfiguration); return }
                guard validateSource(sourceID, epoch: epoch, audio: true) else { return }
                let packet = AudioPacket(payload: ownedPayload, pts: CMTime(value: Int64(presentationTimeUs), timescale: 1_000_000))
                if firstPresentationTime == nil {
                    audioPreRoll.append(packet); preRollBytes += ownedPayload.count
                    // Bounded pre-roll is only used until the first admitted video establishes origin.
                    while audioPreRoll.count > 64 || preRollBytes > 256 * 1024 {
                        preRollBytes -= audioPreRoll.removeFirst().payload.count
                    }
                } else { appendAudioOnQueue(packet) }
            }
        }
    }

    func rejectAudioConfiguration() {
        guard recordsAudio else { return }
        reportFailure(.audioConfiguration)
    }

    func validateAudioConfiguration(_ configuration: RecordingAACConfiguration, epoch: UInt32? = nil, sourceID: UUID? = nil) {
        admit(bytes: 0) { [self] in
            guard validateSource(sourceID, epoch: epoch, audio: true) else { return }
            guard audioConfiguration == configuration else { failOnQueue(ScreenRecorderError.audioConfiguration); return }
        }
    }

    private func admit(bytes: Int, operation: @escaping @Sendable () -> Void) {
        admitPrepared(bytes: bytes) { operation }
    }
    private func admitPrepared(bytes: Int, prepare: () -> (@Sendable () -> Void)) {
        finishAdmissionLock.lock()
        guard !finishWasRequested, !failedAdmission else { finishAdmissionLock.unlock(); return }
        guard bytes >= 0, bytes <= 64 * 1024 * 1024 - queuedBytes, queuedCount < 256 else {
            failedAdmission = true
            queue.async { [self] in failOnQueue(ScreenRecorderError.backpressure) }
            finishAdmissionLock.unlock(); return
        }
        queuedBytes += bytes; queuedCount += 1
        let operation = prepare()
        // Enqueue under the same admission lock as finish to establish a total boundary.
        queue.async { [self] in
            defer { finishAdmissionLock.withLock { queuedBytes -= bytes; queuedCount -= 1 } }
            guard case .recording = lifecycle, failure == nil else { return }
            operation()
        }
        finishAdmissionLock.unlock()
    }

    private func reportFailure(_ error: ScreenRecorderError) {
        finishAdmissionLock.withLock {
            guard !finishWasRequested, !failedAdmission else { return }
            failedAdmission = true
            queue.async { [self] in failOnQueue(error) }
        }
    }
    private func failOnQueue(_ error: Error) {
        guard failure == nil, case .recording = lifecycle else { return }
        failure = error
        finishAdmissionLock.withLock { failedAdmission = true }
        failureHandler?(error)
    }
    private func validateSource(_ incoming: UUID?, epoch: UInt32?, audio: Bool) -> Bool {
        if let sourceID, incoming != sourceID { failOnQueue(ScreenRecorderError.sourceChanged); return false }
        if let epoch {
            let previous = audio ? audioEpoch : videoEpoch
            if let previous, previous != epoch { failOnQueue(ScreenRecorderError.sourceChanged); return false }
            if audio { audioEpoch = epoch } else { videoEpoch = epoch }
        }
        return true
    }

    private func appendAudioOnQueue(_ packet: AudioPacket) {
        guard failure == nil, let origin = firstPresentationTime, let audioInput, let audioConfiguration, let audioFormat else { return }
        let relative = CMTimeSubtract(packet.pts, origin)
        // Raw AAC cannot be partially trimmed without source encoder trim metadata. Discard
        // access units beginning before the video origin; preserve the following true offset.
        guard relative >= .zero else { return }
        if let lastAudioTime, relative <= lastAudioTime { failOnQueue(ScreenRecorderError.invalidTimestamp); return }
        guard audioInput.isReadyForMoreMediaData else { failOnQueue(ScreenRecorderError.backpressure); return }
        do {
            let sample = try audioConfiguration.sample(packet.payload, pts: relative, format: audioFormat)
            guard audioInput.append(sample) else { failOnQueue(ScreenRecorderError.writer(writer.error)); return }
            lastAudioTime = relative; audioSampleCount += 1
        } catch { failOnQueue(error) }
    }

    /// Returns `true` only for the request that owns the terminal callback.
    /// Admission is thread-safe; later requests return `false` without retaining their callback.
    @discardableResult
    func finish(completion: @escaping @Sendable (Result<URL, Error>) -> Void) -> Bool {
        finishAdmissionLock.withLock {
            guard !finishWasRequested else { return false }
            finishWasRequested = true
            queue.async { [self] in finishOnQueue(completion) }
            return true
        }
    }

    private func finishOnQueue(_ completion: @escaping Completion) {
        guard case .recording = lifecycle else { return }
        lifecycle = .finishing
        audioPreRoll.removeAll(); preRollBytes = 0
        input.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [self] in
            queue.async { [self] in completeFinalizationOnQueue(completion) }
        }
    }

    private func completeFinalizationOnQueue(_ completion: @escaping Completion) {
        guard case .finishing = lifecycle else { return }
        let result: Result<URL, Error>
        if let failure {
            result = .failure(failure)
        } else { switch writer.status {
        case .completed where firstPresentationTime != nil:
            result = audioInput != nil && audioSampleCount == 0
                ? .failure(ScreenRecorderError.noAudio) : .success(writer.outputURL)
        case .completed:
            result = .failure(ScreenRecorderError.noFrames)
        case .cancelled:
            result = .failure(ScreenRecorderError.cancelled)
        default:
            result = .failure(ScreenRecorderError.writer(writer.error))
        }
        }
        lifecycle = .finished
        completion(result)
    }

    private func appendOnQueue(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard case .recording = lifecycle else { return }
        guard input.isReadyForMoreMediaData else {
            if audioInput != nil { failOnQueue(ScreenRecorderError.backpressure) }
            return
        }
        if audioInput != nil && (!presentationTime.isNumeric || presentationTime < .zero) {
            failOnQueue(ScreenRecorderError.invalidTimestamp); return
        }
        var relative = CMTimeSubtract(
            presentationTime,
            firstPresentationTime ?? presentationTime
        )
        if !relative.isValid || relative < lastPresentationTime {
            if audioInput != nil { failOnQueue(ScreenRecorderError.invalidTimestamp); return }
            relative = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 60))
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: relative) else {
            if audioInput != nil { failOnQueue(ScreenRecorderError.writer(writer.error)) }
            return
        }
        if firstPresentationTime == nil { firstPresentationTime = presentationTime }
        lastPresentationTime = relative
        let buffered = audioPreRoll
        audioPreRoll.removeAll(); preRollBytes = 0
        for packet in buffered { appendAudioOnQueue(packet) }
    }
}

private struct RecorderPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}
