import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import GalaxyBridgeCore

enum AACAudioPlayerError: Error, LocalizedError {
    case unsupportedCodec
    case invalidConfiguration
    case converterUnavailable
    case engine(Error)
    case conversion(Error?)

    var errorDescription: String? { String(localized: "ERROR_AUDIO_PLAYBACK") }
}

final class AACAudioPlayer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let engine = AVAudioEngine()
    private let player: AVAudioPlayerNode
    private let failureHandler: @Sendable (Error) -> Void
    private let nowSeconds: @Sendable () -> TimeInterval
    private let playoutClock: MediaPlayoutClock
    private var codec: ScrcpyCodec?
    private var compressedFormat: AVAudioFormat?
    private var pcmFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var playoutGeneration: UInt64?
    private let nativeAttempt: NativeMediaAttempt?
    private var nativeCleanupFence: NativeMediaLease?
    private var nativeCodecWork: NativeMediaWork?
    private var nativeConfigurationWork: NativeMediaWork?
    private var nativeConfigurationStorage: NativeMediaLease?
    private var nativeOutputEvent: (@Sendable (NativeAudioOutputEvent) -> Void)?
    private var playbackEnabled = true
    private var playbackRevision = UUID()
    private struct PlaybackRequest {
        let id: UUID
        let completion: @Sendable (UUID) -> Void
    }
    private struct PlaybackCandidate: Sendable {
        let token: UUID
        let requestID: UUID
        let revision: UUID
    }
    private var playbackRequest: PlaybackRequest?
    // Keep one physical callback in flight even after invalidating its revision.
    private var playbackCandidate: PlaybackCandidate?
    private let nativeCompletionDelivery: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(
        playoutClock: MediaPlayoutClock = MediaPlayoutClock(),
        nowSeconds: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        queue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.aac-player"),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode(),
        nativeAttempt: NativeMediaAttempt? = nil,
        nativeOutputEvent: (@Sendable (NativeAudioOutputEvent) -> Void)? = nil,
        nativeCompletionDelivery: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { $0() },
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        self.player = playerNode
        self.playoutClock = playoutClock
        self.queue = queue
        self.nowSeconds = nowSeconds
        self.failureHandler = failureHandler
        self.nativeAttempt = nativeAttempt
        self.nativeOutputEvent = nativeOutputEvent
        self.nativeCompletionDelivery = nativeCompletionDelivery
        engine.attach(player)
        if let nativeAttempt {
            nativeCleanupFence = nativeAttempt.registerCleanup { [weak self] in
                self?.retireNativeOnQueue()
            }
        }
    }

    func consume(_ event: ScrcpyStreamEvent, epoch: UInt32? = nil, diagnosticTrace: PrimaryMediaTrace? = nil,
                 nativeWork suppliedWork: NativeMediaWork? = nil) {
        let work = suppliedWork ?? nativeAttempt?.admit(event, audio: true, binding: nil, trace: diagnosticTrace)
        if nativeAttempt != nil && work == nil {
            if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
            return
        }
        let event = work?.event ?? event
        if let trace = diagnosticTrace { trace.collector.enter(.decoder, trace: trace) }
        queue.async { [weak self] in
            if let trace = diagnosticTrace {
                trace.collector.leave(.decoder, trace: trace)
                trace.collector.mark(.decoder, trace: trace)
            }
            defer { if let trace = diagnosticTrace { trace.collector.finish(trace) } }
            guard let self else { return }
            let operation = work?.attempt.operation()
            guard work == nil || operation != nil else { return }
            defer { withExtendedLifetime(operation) {} }
            do { try self.consumeOnQueue(event, epoch: epoch, diagnosticTrace: diagnosticTrace, work: work) } catch {
                self.invalidatePlaybackEvidence(clearRequest: true)
                diagnosticTrace?.collector.count(.failed)
                if work?.attempt.isAdmitted ?? true { self.failureHandler(error) }
            }
        }
    }

    /// Changes audible output only. Capture, decode, scheduling and native leases
    /// remain active for independent consumers such as an ongoing A/V recording.
    func setPlaybackEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if playbackEnabled != enabled { invalidatePlaybackEvidence() }
            playbackEnabled = enabled
            player.volume = enabled ? 1 : 0
        }
    }

    /// Arms one explicit verification attempt. Only a subsequently scheduled audible
    /// buffer's real dataPlayedBack completion can deliver the token, at most once.
    func requestPlaybackEvidence(id: UUID, completion: @escaping @Sendable (UUID) -> Void) {
        queue.async { [weak self] in
            guard let self, nativeAttempt?.isAdmitted ?? true else { return }
            invalidatePlaybackEvidence()
            playbackRequest = PlaybackRequest(id: id, completion: completion)
        }
    }

    func cancelPlaybackEvidence() {
        queue.async { [weak self] in self?.invalidatePlaybackEvidence(clearRequest: true) }
    }

    private func invalidatePlaybackEvidence(clearRequest: Bool = false) {
        playbackRevision = UUID()
        if clearRequest { playbackRequest = nil }
    }

    private func takePlaybackCandidate() -> PlaybackCandidate? {
        guard playbackCandidate == nil, playbackEnabled, player.volume > 0,
              let request = playbackRequest, nativeAttempt?.isAdmitted ?? true else { return nil }
        let candidate = PlaybackCandidate(token: UUID(), requestID: request.id, revision: playbackRevision)
        playbackCandidate = candidate
        return candidate
    }

    private func playbackCompleted(_ candidate: PlaybackCandidate, type: AVAudioPlayerNodeCompletionCallbackType) {
        // Never run player operations on AVAudioPlayerNode's completion thread.
        queue.async { [weak self] in
            guard let self, playbackCandidate?.token == candidate.token else { return }
            playbackCandidate = nil
            guard type == .dataPlayedBack, candidate.revision == playbackRevision,
                  playbackEnabled, player.volume > 0, engine.isRunning, player.isPlaying,
                  nativeAttempt?.isAdmitted ?? true,
                  let request = playbackRequest, request.id == candidate.requestID else { return }
            playbackRequest = nil
            request.completion(request.id)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.invalidatePlaybackEvidence(clearRequest: true)
            self?.player.stop()
            self?.engine.stop()
            self?.converter = nil
            self?.playoutGeneration = nil
            self?.playoutClock.reset()
        }
    }

    func beginNativeRetirement() -> NativeMediaRetirement? { nativeAttempt?.retire() }

    /// Queue-ordered observation of the existing real native events, including
    /// when this player was constructed by the session's fresh owner factory.
    func observeNativeOutput(_ observer: @escaping @Sendable (NativeAudioOutputEvent) -> Void) {
        queue.async { [self] in nativeOutputEvent = observer }
    }

    private func retireNativeOnQueue() {
        queue.async { [self] in
            invalidatePlaybackEvidence(clearRequest: true)
            player.stop()
            engine.stop()
            converter = nil
            compressedFormat = nil
            pcmFormat = nil
            codec = nil
            playoutGeneration = nil
            playoutClock.reset()
            nativeConfigurationWork = nil
            nativeConfigurationStorage = nil
            nativeCodecWork = nil
            nativeOutputEvent?(.stopped)
            nativeCleanupFence = nil
        }
    }

    private func consumeOnQueue(_ event: ScrcpyStreamEvent, epoch: UInt32?, diagnosticTrace: PrimaryMediaTrace?, work: NativeMediaWork?) throws {
        switch event {
        case let .codec(codec):
            guard codec == .aac else { throw AACAudioPlayerError.unsupportedCodec }
            self.codec = codec
            nativeCodecWork = work
        case .videoSession:
            break
        case let .packet(packet):
            if packet.isConfiguration {
                // Retain the native magic-cookie copy as well as owned input.
                let storage = work?.reserve(packet.payload.count)
                guard work == nil || storage != nil else { return }
                playoutClock.reset(epoch: epoch)
                try configure(magicCookie: packet.payload)
                nativeConfigurationWork = work
                nativeConfigurationStorage = storage
            } else {
                try play(
                    packet.payload,
                    presentationTimeUs: packet.presentationTimeUs,
                    epoch: epoch,
                    diagnosticTrace: diagnosticTrace,
                    work: work
                )
            }
        }
    }

    private func configure(magicCookie: Data) throws {
        invalidatePlaybackEvidence()
        guard codec == .aac, !magicCookie.isEmpty else { throw AACAudioPlayerError.invalidConfiguration }
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1_024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let compressed = AVAudioFormat(streamDescription: &description) else {
            throw AACAudioPlayerError.invalidConfiguration
        }
        compressed.magicCookie = magicCookie
        guard let pcm = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ), let converter = AVAudioConverter(from: compressed, to: pcm) else {
            throw AACAudioPlayerError.converterUnavailable
        }
        if engine.isRunning {
            player.stop()
            engine.stop()
            engine.disconnectNodeOutput(player)
        }
        playoutGeneration = nil
        engine.connect(player, to: engine.mainMixerNode, format: pcm)
        do { try engine.start() } catch { throw AACAudioPlayerError.engine(error) }
        compressedFormat = compressed
        pcmFormat = pcm
        self.converter = converter
    }

    private func play(_ data: Data, presentationTimeUs: UInt64?, epoch: UInt32?, diagnosticTrace: PrimaryMediaTrace?, work: NativeMediaWork?) throws {
        guard let compressedFormat, let pcmFormat, let converter else {
            throw AACAudioPlayerError.invalidConfiguration
        }
        let compressedStorage = work?.reserveMedia(data.count + MemoryLayout<AudioStreamPacketDescription>.stride, kind: .storage, inputLoss: true)
        guard work == nil || compressedStorage != nil else { return }
        // This real PCM gate precedes conversion: rejection is a queued AAC
        // input gap, not a claim of successful converter consumption.
        let outputStorage = work?.reserveMedia(4_096 * 2 * MemoryLayout<Float>.size, kind: .pcm, inputLoss: true)
        guard work == nil || outputStorage != nil else { return }
        defer { withExtendedLifetime(compressedStorage) {}; withExtendedLifetime(outputStorage) {} }
        let input = AVAudioCompressedBuffer(
            format: compressedFormat,
            packetCapacity: 1,
            maximumPacketSize: data.count
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 4_096) else {
            throw AACAudioPlayerError.converterUnavailable
        }
        input.packetCount = 1
        input.byteLength = UInt32(data.count)
        data.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: data.count)
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 1_024,
            mDataByteSize: UInt32(data.count)
        )
        let inputState = ConverterInputState(input: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outputStatus in
            inputState.next(outputStatus: outputStatus)
        }
        guard status != .error else { throw AACAudioPlayerError.conversion(conversionError) }
        // A streaming AAC converter commonly reports inputRanDry after consuming
        // one compressed packet. It may need following packets before emitting
        // PCM, so this is flow control rather than a session failure.
        if output.frameLength > 0 {
            nativeOutputEvent?(.converted(Int(output.frameLength)))
            let scheduling = work?.attempt.operation()
            guard work == nil || scheduling != nil else { return }
            defer { withExtendedLifetime(scheduling) {} }
            let decision = playoutDecision(
                clock: playoutClock,
                presentationTimeUs: presentationTimeUs,
                epoch: epoch,
                diagnosticTrace: diagnosticTrace
            )
            if playoutGeneration != decision.generation {
                invalidatePlaybackEvidence()
                player.stop()
                playoutGeneration = decision.generation
            }
            let audioTime: AVAudioTime?
            switch decision.action {
            case .drop:
                return
            case .immediate:
                audioTime = nil
            case let .schedule(targetHostTime):
                audioTime = AVAudioTime(
                    hostTime: AVAudioTime.hostTime(forSeconds: targetHostTime)
                )
            }
            let candidate = takePlaybackCandidate()
            if outputStorage != nil || candidate != nil {
                let completionDelivery = nativeCompletionDelivery
                let outputEvent = nativeOutputEvent
                // Only the one evidence buffer waits for actual device playback. All
                // other native PCM leases preserve their existing dataConsumed boundary.
                player.scheduleBuffer(output, at: audioTime, options: [],
                                      completionCallbackType: candidate == nil ? .dataConsumed : .dataPlayedBack) { [weak self] type in
                    completionDelivery { [weak self, outputStorage] in
                        if outputStorage != nil { outputEvent?(.completed) }
                        if let candidate { self?.playbackCompleted(candidate, type: type) }
                        withExtendedLifetime(outputStorage) {}
                    }
                }
                if outputStorage != nil {
                    nativeOutputEvent?(.scheduled)
                    work?.attempt.recordMedia(work?.sourceIdentity, outputPressure: false)
                }
            } else {
                player.scheduleBuffer(output, at: audioTime, options: [])
            }
            if !player.isPlaying { player.play() }
        }
    }

    func playoutDecision(clock: MediaPlayoutClock, presentationTimeUs: UInt64?, epoch: UInt32?,
                         diagnosticTrace: PrimaryMediaTrace?) -> MediaPlayoutDecision {
        clock.decision(track: .audio, presentationTimeUs: presentationTimeUs, epoch: epoch,
                       now: nowSeconds(), diagnosticTrace: diagnosticTrace)
    }
}

enum NativeAudioOutputEvent: Sendable {
    case converted(Int)
    case scheduled
    case completed
    case stopped
}

private final class ConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private let input: AVAudioCompressedBuffer
    private var supplied = false

    init(input: AVAudioCompressedBuffer) { self.input = input }

    func next(outputStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            outputStatus.pointee = .noDataNow
            return nil
        }
        supplied = true
        outputStatus.pointee = .haveData
        return input
    }
}
