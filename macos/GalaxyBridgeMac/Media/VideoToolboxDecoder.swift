import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore
import OSLog
import VideoToolbox

enum VideoDecoderError: Error, LocalizedError {
    case unsupportedCodec
    case missingParameterSets
    case formatDescription(OSStatus)
    case decompressionSession(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)
    case cameraQueueFull

    var errorDescription: String? { String(localized: "ERROR_VIDEO_PLAYBACK") }
}

final class VideoToolboxDecoder: @unchecked Sendable {
    enum QueuedInputDecision {case consume,drop}
    // Per-instance host-test stimulus only. Production leaves this nil. The
    // real queued work, immutable identity and ordinary loss path remain owned.
    var queuedInputDecision:(@Sendable(NativeMediaSourceIdentity)->QueuedInputDecision)?
    typealias FrameHandler = @Sendable (CVPixelBuffer, CMTime, UInt32) -> Void
    typealias FailureHandler = @Sendable (Error) -> Void

    private let queue: DispatchQueue
    private let playoutQueue: DispatchQueue
    private let playoutQueueKey = DispatchSpecificKey<UInt8>()
    private let frameHandler: FrameHandler
    private let diagnosticFrameHandler: (@Sendable (CVPixelBuffer, CMTime, UInt32, PrimaryMediaTrace?) -> Void)?
    private let failureHandler: FailureHandler
    private let playoutClock: MediaPlayoutClock
    private let immediateVideoPlayout: Bool
    private let recoverCorruptFrames: Bool
    private let nowSeconds: @Sendable () -> TimeInterval
    private let cameraAdmission: (@Sendable () -> Bool)?
    private let cameraOutputQueued: (@Sendable () -> Void)?
    private let cameraEventBudget = CameraDecoderBudget(limit: 16)
    private let cameraFrameBudget = CameraDecoderBudget(limit: 8)
    private let decoderGenerationLock = NSLock()
    private var codec: ScrcpyCodec?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var videoSession: ScrcpyVideoSession?
    private var epoch: UInt32 = 0
    private var decoderGeneration: UInt64 = 0
    private var recoverableErrorPending: UInt64?
    private var submittedFrameSequence: UInt64 = 0
    private var decodedKeyFrameSequence: UInt64 = 0
    private var recoveredFrameErrors: UInt64 = 0
    var recoveredFrameErrorCount: UInt64 { decoderGenerationLock.withLock { recoveredFrameErrors } }
    var hasPendingFrameRecovery: Bool { decoderGenerationLock.withLock { recoverableErrorPending != nil } }
    private static let recoveryLogger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "VideoFrameRecovery")
    private var waitingForKeyFrame = true
    private let nativeAttempt: NativeMediaAttempt?
    private let ownedFrameHandler: (@Sendable (NativeDecodedFrame) -> Void)?
    private let nativeOutputQueued: (@Sendable () -> Void)?
    private var nativeCleanupFence: NativeMediaLease?
    private var nativeCodecWork: NativeMediaWork?
    private var nativeSessionWork: NativeMediaWork?
    private var nativeConfigurationWork: NativeMediaWork?
    private var nativeConfigurationStorage: NativeMediaLease?
    private struct InstalledConfiguration {
        let id: UUID
        let work: NativeMediaWork
    }
    private let installedConfigurationLock = NSLock()
    private var installedConfiguration: InstalledConfiguration?
    private var installationRevision = UUID()

    /// Only a completed real VT installation can lend its already charged input.
    /// The returned envelope has the new delivery identity, not the old trace.
    func reuseInstalledConfiguration(_ event: ScrcpyStreamEvent, identity: NativeMediaSourceIdentity,
                                     binding: NativeFrameBinding?, trace: PrimaryMediaTrace?) -> NativeMediaWork? {
        guard nativeAttempt?.isAdmitted == true else { return nil }
        let receipt = installedConfigurationLock.withLock { installedConfiguration }
        guard let receipt, Self.matchesConfiguration(receipt.work, event: event, identity: identity) else { return nil }
        let original = receipt.work
        return NativeMediaWork(attempt: original.attempt, job: original.job, input: original.input,
            event: original.event, binding: binding, trace: trace, sourceIdentity: identity,
            pressurePolicy: original.pressurePolicy,
            installedConfigurationID: receipt.id)
    }

    private static func matchesConfiguration(_ original: NativeMediaWork, event: ScrcpyStreamEvent,
                                             identity: NativeMediaSourceIdentity) -> Bool {
        guard let old = original.sourceIdentity,
              old.owner == identity.owner, old.generation == identity.generation,
              old.targetToken == identity.targetToken, old.scid == identity.scid,
              old.displayID == identity.displayID, old.epoch == identity.epoch,
              old.configuration == identity.configuration, old.track == identity.track,
              old.flags == identity.flags,
              old.captureKind == identity.captureKind, old.enabled == identity.enabled,
              old.session == identity.session,
              case let .packet(a) = original.event, a.isConfiguration,
              case let .packet(b) = event, b.isConfiguration else { return false }
        return a.payload == b.payload && a.isKeyFrame == b.isKeyFrame
    }

    private func clearInstalledConfiguration() {
        let previous = installedConfigurationLock.withLock {
            let previous = installedConfiguration; installedConfiguration = nil
            installationRevision = UUID()
            return previous
        }
        withExtendedLifetime(previous) {}
    }
    private let nativeOutputLock = NSLock()
    private var nativeOutputs: [UUID: NativeDecodedFrame] = [:]
    private var unsafeRetirementRetention: VideoToolboxDecoder?

    init(
        playoutClock: MediaPlayoutClock = MediaPlayoutClock(),
        immediateVideoPlayout: Bool = false,
        recoverCorruptFrames: Bool = false,
        nowSeconds: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        cameraAdmission: (@Sendable () -> Bool)? = nil,
        queue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.videotoolbox"),
        playoutQueue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.video-playout"),
        cameraOutputQueued: (@Sendable () -> Void)? = nil,
        nativeAttempt: NativeMediaAttempt? = nil,
        ownedFrameHandler: (@Sendable (NativeDecodedFrame) -> Void)? = nil,
        nativeOutputQueued: (@Sendable () -> Void)? = nil,
        frameHandler: @escaping FrameHandler,
        diagnosticFrameHandler: (@Sendable (CVPixelBuffer, CMTime, UInt32, PrimaryMediaTrace?) -> Void)? = nil,
        failureHandler: @escaping FailureHandler
    ) {
        self.playoutClock = playoutClock
        self.immediateVideoPlayout = immediateVideoPlayout
        self.recoverCorruptFrames = recoverCorruptFrames
        self.nowSeconds = nowSeconds
        self.cameraAdmission = cameraAdmission
        self.queue = queue
        self.playoutQueue = playoutQueue
        self.playoutQueue.setSpecific(key: playoutQueueKey, value: 1)
        self.cameraOutputQueued = cameraOutputQueued
        self.frameHandler = frameHandler
        self.diagnosticFrameHandler = diagnosticFrameHandler
        self.failureHandler = failureHandler
        self.nativeAttempt = nativeAttempt
        self.ownedFrameHandler = ownedFrameHandler
        self.nativeOutputQueued = nativeOutputQueued
        if let nativeAttempt {
            nativeCleanupFence = nativeAttempt.registerCleanup { [weak self] in self?.retireNative() }
        }
    }

    func consume(_ event: ScrcpyStreamEvent, epoch sourceEpoch: UInt32? = nil, diagnosticTrace: PrimaryMediaTrace? = nil,
                 nativeWork suppliedWork: NativeMediaWork? = nil) {
        let work = suppliedWork ?? nativeAttempt?.admit(event, audio: false, binding: nil, trace: diagnosticTrace)
        if nativeAttempt != nil && work == nil {
            if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
            return
        }
        let event = work?.event ?? event
        guard cameraAdmission?() ?? true else { return }
        let reservation = cameraAdmission == nil ? nil : cameraEventBudget.reserve()
        if cameraAdmission != nil && reservation == nil {
            if cameraEventBudget.markGap() { failureHandler(VideoDecoderError.cameraQueueFull) }
            return
        }
        if let trace = diagnosticTrace { trace.collector.enter(.decoder, trace: trace) }
        queue.async { [weak self] in
            if let trace = diagnosticTrace {
                trace.collector.leave(.decoder, trace: trace)
                trace.collector.mark(.decoder, trace: trace)
            }
            defer { withExtendedLifetime(reservation) {} }
            guard let self, self.cameraAdmission?() ?? true else {
                if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
                return
            }
            let operation = work?.attempt.operation()
            guard work == nil || operation != nil else {
                if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
                return
            }
            defer { withExtendedLifetime(operation) {} }
            if let work,let identity=work.sourceIdentity,
               case let .packet(packet)=event,!packet.isConfiguration,
               self.queuedInputDecision?(identity) == .drop {
                self.discardAdmittedInput(work,trace:diagnosticTrace)
                return
            }
            if let reservation {
                // A gap occurs after already queued packets. Do not let an old
                // queued IDR reopen dependent-frame admission across that gap.
                if !self.cameraEventBudget.isCurrent(reservation.generation) {
                    self.waitingForKeyFrame = true
                    if case let .packet(packet) = event, !packet.isConfiguration { return }
                } else if self.cameraEventBudget.takeGap() { self.waitingForKeyFrame = true }
            }
            do { try self.consumeOnQueue(event, sourceEpoch: sourceEpoch, diagnosticTrace: diagnosticTrace, work: work) } catch {
                if case let VideoDecoderError.decode(status) = error {
                    let recovered = self.handleDecodeFailure(status)
                    if let trace = diagnosticTrace { trace.collector.finish(trace, reason: recovered ? .dropped : .failed) }
                } else {
                    if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .failed) }
                    if work?.attempt.isAdmitted ?? true { self.failureHandler(error) }
                }
            }
        }
    }

    private func discardAdmittedInput(_ work:NativeMediaWork,trace:PrimaryMediaTrace?) {
        waitingForKeyFrame=true
        work.attempt.recordMedia(work.sourceIdentity,inputLost:true)
        if let trace {trace.collector.finish(trace,reason:.dropped)}
    }

    /// Shared by synchronous submit errors and asynchronous VT callbacks.
    /// A callback from a retired decoder generation cannot affect its successor.
    @discardableResult
    func handleDecodeFailure(_ status: OSStatus, generation: UInt64? = nil, sequence: UInt64? = nil) -> Bool {
        var startedRecovery = false
        let recover = decoderGenerationLock.withLock { () -> Bool? in
            if let generation, generation != decoderGeneration { return nil }
            guard recoverCorruptFrames,
                  status == kVTVideoDecoderBadDataErr || status == kVTVideoDecoderReferenceMissingErr
            else { return false }
            if let sequence, sequence < decodedKeyFrameSequence { return nil }
            startedRecovery = recoverableErrorPending == nil
            recoverableErrorPending = max(recoverableErrorPending ?? 0, sequence ?? submittedFrameSequence)
            if recoveredFrameErrors < UInt64.max { recoveredFrameErrors += 1 }
            return true
        }
        guard let recover else { return true } // Obsolete callback is discarded.
        if recover {
            if startedRecovery { Self.recoveryLogger.info("Discarding corrupt video frame; awaiting IDR status=\(status)") }
        } else if nativeAttempt?.isAdmitted ?? true {
            failureHandler(VideoDecoderError.decode(status))
        }
        return recover
    }

    /// A successful IDR repairs only earlier submissions, never an error of
    /// that IDR itself. A late delta callback cannot re-close a repaired chain.
    func decodedKeyFrame(sequence: UInt64, generation: UInt64) {
        decoderGenerationLock.withLock {
            guard generation == decoderGeneration else { return }
            decodedKeyFrameSequence = max(decodedKeyFrameSequence, sequence)
            if let pending = recoverableErrorPending, pending < sequence {
                recoverableErrorPending = nil
            }
        }
    }

    /// Ordered behind every previously admitted decoder job. A missing encoded
    /// AU invalidates VideoToolbox's inter-frame references even though the
    /// already-installed parameter sets remain current. Recreate only the VT
    /// session, then exclude dependent frames until an IDR is admitted.
    func markInputGap() {
        queue.async { [weak self] in
            guard let self else { return }
            self.waitingForKeyFrame = true
            var status: OSStatus = noErr
            if let session = self.decompressionSession {
                // The gap boundary is ordered after all previously submitted
                // decoder jobs. Drain their valid callbacks and immediate
                // playout before revoking the decoder generation; otherwise a
                // complete IDR can be decoded successfully and then discarded
                // solely because the following AU was lost.
                status = VTDecompressionSessionWaitForAsynchronousFrames(session)
                if DispatchQueue.getSpecific(key: self.playoutQueueKey) == nil {
                    self.playoutQueue.sync {}
                }
            }
            self.decoderGenerationLock.lock()
            self.decoderGeneration &+= 1
            self.recoverableErrorPending = nil
            self.submittedFrameSequence = 0
            self.decodedKeyFrameSequence = 0
            self.decoderGenerationLock.unlock()
            if let session = self.decompressionSession {
                VTDecompressionSessionInvalidate(session)
            }
            self.decompressionSession = nil
            self.playoutClock.reset(epoch: self.epoch)
            guard status == noErr else {
                self.nativeAttempt?.fail(.nativeCleanup(status))
                self.failureHandler(VideoDecoderError.decode(status))
                return
            }
            guard let format = self.formatDescription else { return }
            do {
                try self.createDecompressionSession(format: format)
            } catch {
                self.failureHandler(error)
            }
        }
    }

    func invalidate() {
        clearInstalledConfiguration()
        if cameraAdmission != nil {
            // Keep the camera decoder alive until VT's unretained callback
            // reference is drained. Retiring its ingress releases the session.
            queue.async { [self] in
                resetDecoder()
                playoutClock.reset()
            }
            return
        }
        queue.async { [weak self] in
            self?.resetDecoder()
            self?.playoutClock.reset()
        }
    }

    func beginNativeRetirement() -> NativeMediaRetirement? { nativeAttempt?.retire() }

    private func retireNative() {
        clearInstalledConfiguration()
        // Taking the payloads releases real pixels/leases now. Scheduled wakes
        // capture only weak self and IDs, never the removed payloads.
        let canceled = nativeOutputLock.withLock { let frames = nativeOutputs; nativeOutputs.removeAll(); return frames }
        for frame in canceled.values {
            if let trace = frame.trace {
                trace.collector.leave(.output, trace: trace)
                trace.collector.finish(trace, reason: .dropped)
            }
        }
        queue.async { [self] in
            let status = resetDecoder()
            guard status == noErr, unsafeRetirementRetention == nil else {
                unsafeRetirementRetention = self
                if status != noErr { nativeAttempt?.fail(.nativeCleanup(status)) }
                return
            }
            playoutClock.reset()
            nativeCodecWork = nil
            nativeSessionWork = nil
            nativeConfigurationWork = nil
            nativeConfigurationStorage = nil
            nativeCleanupFence = nil
        }
    }

    private func consumeOnQueue(_ event: ScrcpyStreamEvent, sourceEpoch: UInt32?, diagnosticTrace: PrimaryMediaTrace?, work: NativeMediaWork?) throws {
        switch event {
        case let .codec(codec):
            guard codec == .h264 || codec == .h265 else { throw VideoDecoderError.unsupportedCodec }
            self.codec = codec
            nativeCodecWork = work
            if let trace = diagnosticTrace { trace.collector.finish(trace) }
        case let .videoSession(session):
            nativeSessionWork = work
            let nextEpoch = sourceEpoch ?? (epoch &+ 1)
            if videoSession != session || epoch != nextEpoch {
                epoch = nextEpoch
                videoSession = session
                resetDecoder()
                playoutClock.reset(epoch: epoch)
            }
            if let trace = diagnosticTrace { trace.collector.finish(trace) }
        case let .packet(packet):
            if packet.isConfiguration {
                if let work {
                    if let reused = work.installedConfigurationID {
                        let current = installedConfigurationLock.withLock { installedConfiguration }
                        guard let current, current.id == reused,
                              current.work.attempt === work.attempt, work.attempt.isAdmitted,
                              let identity = work.sourceIdentity,
                              Self.matchesConfiguration(current.work, event: event, identity: identity) else {
                            if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
                            return
                        }
                        if let trace = diagnosticTrace { trace.collector.finish(trace) }
                        return
                    }
                    guard let codec else { throw VideoDecoderError.unsupportedCodec }
                    guard let (format, storage) = try NativeAnnexB.formatDescription(from: packet.payload, codec: codec, work: work) else { return }
                    resetDecoder()
                    let revision = installedConfigurationLock.withLock { installationRevision }
                    formatDescription = format
                    try createDecompressionSession(format: format)
                    nativeConfigurationWork = work
                    nativeConfigurationStorage = storage
                    if work.sourceIdentity != nil, work.attempt.isAdmitted {
                        installedConfigurationLock.withLock {
                            if installationRevision == revision {
                                installedConfiguration = InstalledConfiguration(id: UUID(), work: work)
                            }
                        }
                    }
                } else {
                    try configure(with: packet.payload)
                }
                if let trace = diagnosticTrace { trace.collector.finish(trace) }
            } else {
                try decode(packet, diagnosticTrace: diagnosticTrace, work: work)
            }
        }
    }

    private func configure(with data: Data) throws {
        guard let codec else { throw VideoDecoderError.unsupportedCodec }
        let units = AnnexB.nalUnits(in: data)
        let format: CMVideoFormatDescription
        switch codec {
        case .h264:
            guard let sps = units.first(where: { $0.first.map { $0 & 0x1F == 7 } == true }),
                  let pps = units.first(where: { $0.first.map { $0 & 0x1F == 8 } == true })
            else { throw VideoDecoderError.missingParameterSets }
            format = try makeH264FormatDescription(sps: sps, pps: pps)
        case .h265:
            guard let vps = units.first(where: { $0.first.map { ($0 >> 1) & 0x3F == 32 } == true }),
                  let sps = units.first(where: { $0.first.map { ($0 >> 1) & 0x3F == 33 } == true }),
                  let pps = units.first(where: { $0.first.map { ($0 >> 1) & 0x3F == 34 } == true })
            else { throw VideoDecoderError.missingParameterSets }
            format = try makeHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
        default:
            throw VideoDecoderError.unsupportedCodec
        }
        resetDecoder()
        formatDescription = format
        try createDecompressionSession(format: format)
    }

    private func createDecompressionSession(format: CMVideoFormatDescription) throws {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { reference, sourceFrameReference, status, _, imageBuffer, presentationTime, _ in
                let frameContext = sourceFrameReference.map {
                    Unmanaged<DecodedFrameContext>.fromOpaque($0).takeRetainedValue()
                }
                if let trace = frameContext?.diagnosticTrace {
                    trace.collector.leave(.vt, trace: trace)
                    trace.collector.mark(.callback, trace: trace)
                }
                guard let reference else { return }
                let decoder = Unmanaged<VideoToolboxDecoder>.fromOpaque(reference).takeUnretainedValue()
                let operation = frameContext?.nativeWork?.attempt.operation()
                guard frameContext?.nativeWork == nil || operation != nil else {
                    if let trace = frameContext?.diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
                    return
                }
                defer { withExtendedLifetime(operation) {} }
                guard let frameContext,
                      decoder.cameraAdmission?() ?? true,
                      decoder.isCurrentDecoderGeneration(frameContext.decoderGeneration)
                else {
                    if let trace = frameContext?.diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
                    return
                }
                guard status == noErr else {
                    let recovered = decoder.handleDecodeFailure(status, generation: frameContext.decoderGeneration,
                        sequence: frameContext.sequence)
                    if let trace = frameContext.diagnosticTrace { trace.collector.finish(trace, reason: recovered ? .dropped : .failed) }
                    return
                }
                guard let imageBuffer else {
                    if let trace = frameContext.diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
                    return
                }
                if frameContext.isKeyFrame {
                    decoder.decodedKeyFrame(sequence: frameContext.sequence, generation: frameContext.decoderGeneration)
                }
                decoder.enqueue(
                    imageBuffer,
                    presentationTime: presentationTime,
                    presentationTimeUs: frameContext.presentationTimeUs,
                    epoch: frameContext.epoch,
                    decoderGeneration: frameContext.decoderGeneration,
                    cameraReservation: frameContext.cameraReservation,
                    diagnosticTrace: frameContext.diagnosticTrace,
                    nativeWork: frameContext.nativeWork
                )
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let decoderSpecification = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true,
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true,
        ] as CFDictionary
        let imageAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: imageAttributes,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { throw VideoDecoderError.decompressionSession(status) }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decompressionSession = session
    }

    private func decode(_ packet: ScrcpyPacket, diagnosticTrace: PrimaryMediaTrace?, work: NativeMediaWork?) throws {
        if recoverCorruptFrames {
            let lostReference = decoderGenerationLock.withLock {
                let pending = recoverableErrorPending != nil
                recoverableErrorPending = nil
                return pending
            }
            if lostReference { waitingForKeyFrame = true }
        }
        if waitingForKeyFrame && !packet.isKeyFrame {
            if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
            return
        }
        let reservation = cameraAdmission == nil ? nil : cameraFrameBudget.reserve()
        if cameraAdmission != nil && reservation == nil {
            waitingForKeyFrame = true
            throw VideoDecoderError.cameraQueueFull
        }
        guard let session = decompressionSession, let formatDescription else {
            throw VideoDecoderError.missingParameterSets
        }
        let storage: NativeMediaLease?
        let sampleData: Data
        if let work {
            guard let sample = NativeAnnexB.lengthPrefixedSample(from: packet.payload, work: work) else {
                if work.attempt.isAdmitted { discardAdmittedInput(work,trace:diagnosticTrace) }
                return
            }
            (sampleData, storage) = sample
        } else {
            storage = nil
            sampleData = AnnexB.lengthPrefixedSample(from: packet.payload)
        }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw VideoDecoderError.blockBuffer(status) }
        status = sampleData.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: sampleData.count)
        }
        guard status == kCMBlockBufferNoErr else { throw VideoDecoderError.blockBuffer(status) }
        let presentationTime = CMTime(value: Int64(packet.presentationTimeUs ?? 0), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw VideoDecoderError.sampleBuffer(status) }
        var flags: VTDecodeInfoFlags = []
        let sequence = decoderGenerationLock.withLock {
            submittedFrameSequence &+= 1
            return submittedFrameSequence
        }
        let frameContext = Unmanaged.passRetained(
            DecodedFrameContext(
                epoch: epoch,
                presentationTimeUs: packet.presentationTimeUs,
                decoderGeneration: currentDecoderGeneration(),
                sequence: sequence, isKeyFrame: packet.isKeyFrame,
                cameraReservation: reservation,
                diagnosticTrace: diagnosticTrace,
                nativeWork: work,
                nativeStorage: storage,
                nativeOwner: work == nil ? nil : self
            )
        )
        if let trace = diagnosticTrace {
            trace.collector.mark(.submitted, trace: trace)
            trace.collector.enter(.vt, trace: trace)
        }
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            // Mirroring has no B-frame reordering. Temporal processing opts
            // into indefinitely delayed callbacks for a stationary screen.
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: frameContext.toOpaque(),
            infoFlagsOut: &flags,
        )
        guard status == noErr else {
            if let trace = diagnosticTrace { trace.collector.leave(.vt, trace: trace) }
            waitingForKeyFrame = true
            frameContext.release()
            throw VideoDecoderError.decode(status)
        }
        if packet.isKeyFrame {
            // A mirror cannot wait for a successor AU before presenting its
            // first independently decodable image. In particular, HEVC may
            // legally defer this asynchronous callback; if the successor is
            // then lost, gap recovery would otherwise revoke the generation
            // before any good frame became visible. Drain only IDRs, leaving
            // ordinary 60 fps delta decoding fully asynchronous.
            let drainStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard drainStatus == noErr else {
                waitingForKeyFrame = true
                throw VideoDecoderError.decode(drainStatus)
            }
        }
        waitingForKeyFrame = false
    }

    private func enqueue(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        presentationTimeUs: UInt64?,
        epoch: UInt32,
        decoderGeneration: UInt64,
        cameraReservation: CameraDecoderReservation?,
        diagnosticTrace: PrimaryMediaTrace?,
        nativeWork: NativeMediaWork?
    ) {
        guard isCurrentDecoderGeneration(decoderGeneration) else {
            if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
            return
        }
        if let nativeWork {
            enqueueOwned(pixelBuffer, presentationTime: presentationTime, presentationTimeUs: presentationTimeUs,
                         epoch: epoch, decoderGeneration: decoderGeneration, work: nativeWork)
            return
        }
        let now = nowSeconds()
        let decision = playoutClock.decision(
            track: .video,
            presentationTimeUs: immediateVideoPlayout ? nil : presentationTimeUs,
            epoch: epoch,
            now: now,
            diagnosticTrace: diagnosticTrace
        )
        let frame = SendableDecodedPixelBuffer(pixelBuffer)
        if let trace = diagnosticTrace { trace.collector.enter(.output, trace: trace) }
        let deliver: @Sendable () -> Void = { [weak self] in
            defer { withExtendedLifetime(cameraReservation) {} }
            if let trace = diagnosticTrace {
                trace.collector.leave(.output, trace: trace)
                trace.collector.mark(.delivered, trace: trace)
            }
            guard let self,
                  self.cameraAdmission?() ?? true,
                  self.isCurrentDecoderGeneration(decoderGeneration),
                  self.playoutClock.isCurrent(generation: decision.generation)
            else {
                if let trace = diagnosticTrace { trace.collector.finish(trace, reason: .dropped) }
                return
            }
            if let handler = self.diagnosticFrameHandler {
                handler(frame.value, presentationTime, epoch, diagnosticTrace)
            } else {
                self.frameHandler(frame.value, presentationTime, epoch)
                if let trace = diagnosticTrace { trace.collector.finish(trace) }
            }
        }
        switch decision.action {
        case .drop:
            if let trace = diagnosticTrace {
                trace.collector.leave(.output, trace: trace)
                trace.collector.finish(trace, reason: .dropped)
            }
            return
        case .immediate:
            playoutQueue.async(execute: deliver)
        case let .schedule(targetHostTime):
            let delay = max(0, targetHostTime - now)
            playoutQueue.asyncAfter(deadline: .now() + delay, execute: deliver)
        }
        cameraOutputQueued?()
    }

    private func enqueueOwned(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, presentationTimeUs: UInt64?,
                              epoch: UInt32, decoderGeneration: UInt64, work: NativeMediaWork) {
        guard let allocation = work.reserveMedia(CVPixelBufferGetDataSize(pixelBuffer), kind: .decoded) else {
            if let trace = work.trace { trace.collector.finish(trace, reason: .dropped) }
            return
        }
        let now = nowSeconds()
        // sourceIdentity is installed only by owned admission. The QUIC bridge
        // admits the complete C output after G1's codec-qualified independent
        // check; an arbitrary scrcpy/camera packet flag is not this provenance.
        // This callback also requires real successful VT output. Final delivery
        // still checks attempt, binding, decoder and playout generations.
        let independent = work.sourceIdentity.map {
            $0.track == 1 && $0.epoch == epoch && $0.flags & 1 != 0
        } == true && work.attempt.isAdmitted && (work.binding?.isAdmitted ?? true)
            && isCurrentDecoderGeneration(decoderGeneration)
        let decision = playoutClock.decision(track: .video,
            presentationTimeUs: immediateVideoPlayout ? nil : presentationTimeUs,
            epoch: epoch, now: now, diagnosticTrace: work.trace, allowLateIndependentVideo: independent)
        if case .drop = decision.action {
            if let trace = work.trace { trace.collector.finish(trace, reason: .dropped) }
            return
        }
        let frame = NativeDecodedFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime,
            epoch: epoch, context: NativeMediaOutputContext(work: work, decoderGeneration: decoderGeneration,
                playoutGeneration: decision.generation), allocation: allocation)
        let id = UUID()
        if let trace = frame.trace { trace.collector.enter(.output, trace: trace) }
        let accepted = nativeOutputLock.withLock {
            guard frame.isAdmitted else { return false }
            nativeOutputs[id] = frame
            return true
        }
        guard accepted else {
            if let trace = work.trace {
                trace.collector.leave(.output, trace: trace)
                trace.collector.finish(trace, reason: .dropped)
            }
            return
        }
        work.attempt.recordMedia(work.sourceIdentity, outputPressure: false)
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self, let frame = self.nativeOutputLock.withLock({ self.nativeOutputs.removeValue(forKey: id) }) else { return }
            if let trace = frame.trace {
                trace.collector.leave(.output, trace: trace)
                trace.collector.mark(.delivered, trace: trace)
            }
            guard let operation = frame.context.attempt.operation(), frame.isAdmitted,
                  self.isCurrentDecoderGeneration(frame.context.decoderGeneration),
                  self.playoutClock.isCurrent(generation: frame.context.playoutGeneration) else {
                if let trace = frame.trace { trace.collector.finish(trace, reason: .dropped) }
                return
            }
            defer { withExtendedLifetime(operation) {} }
            if let handler = self.ownedFrameHandler { handler(frame) }
            else if let handler = self.diagnosticFrameHandler {
                handler(frame.pixelBuffer, frame.presentationTime, frame.epoch, frame.trace)
            } else {
                self.frameHandler(frame.pixelBuffer, frame.presentationTime, frame.epoch)
                if let trace = frame.trace { trace.collector.finish(trace) }
            }
        }
        switch decision.action {
        case .drop: break
        case .immediate: playoutQueue.async(execute: deliver)
        case let .schedule(target): playoutQueue.asyncAfter(deadline: .now() + max(0, target - now), execute: deliver)
        }
        nativeOutputQueued?()
    }

    @discardableResult private func resetDecoder() -> OSStatus {
        clearInstalledConfiguration()
        waitingForKeyFrame = true
        decoderGenerationLock.lock()
        decoderGeneration &+= 1
        recoverableErrorPending = nil
        submittedFrameSequence = 0
        decodedKeyFrameSequence = 0
        decoderGenerationLock.unlock()
        var status: OSStatus = noErr
        if let decompressionSession {
            status = VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
        formatDescription = nil
        if status != noErr, let nativeAttempt {
            unsafeRetirementRetention = self
            nativeAttempt.fail(.nativeCleanup(status))
        }
        return status
    }

    private func currentDecoderGeneration() -> UInt64 {
        decoderGenerationLock.lock()
        defer { decoderGenerationLock.unlock() }
        return decoderGeneration
    }

    private func isCurrentDecoderGeneration(_ candidate: UInt64) -> Bool {
        decoderGenerationLock.lock()
        defer { decoderGenerationLock.unlock() }
        return candidate == decoderGeneration
    }

    private func makeH264FormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var output: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                var pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &output
                )
            }
        }
        guard status == noErr, let output else { throw VideoDecoderError.formatDescription(status) }
        return output
    }

    private func makeHEVCFormatDescription(vps: Data, sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var output: CMFormatDescription?
        let status = vps.withUnsafeBytes { vpsBytes in
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    var pointers = [
                        vpsBytes.bindMemory(to: UInt8.self).baseAddress!,
                        spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                        ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ]
                    var sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointers.count,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &output
                    )
                }
            }
        }
        guard status == noErr, let output else { throw VideoDecoderError.formatDescription(status) }
        return output
    }
}

private final class DecodedFrameContext: @unchecked Sendable {
    let epoch: UInt32
    let presentationTimeUs: UInt64?
    let decoderGeneration: UInt64
    let sequence: UInt64
    let isKeyFrame: Bool
    let cameraReservation: CameraDecoderReservation?
    let diagnosticTrace: PrimaryMediaTrace?
    let nativeWork: NativeMediaWork?
    let nativeStorage: NativeMediaLease?
    let nativeOwner: VideoToolboxDecoder?

    init(epoch: UInt32, presentationTimeUs: UInt64?, decoderGeneration: UInt64,
         sequence: UInt64, isKeyFrame: Bool,
         cameraReservation: CameraDecoderReservation?, diagnosticTrace: PrimaryMediaTrace?,
         nativeWork: NativeMediaWork?, nativeStorage: NativeMediaLease?, nativeOwner: VideoToolboxDecoder?) {
        self.epoch = epoch
        self.presentationTimeUs = presentationTimeUs
        self.decoderGeneration = decoderGeneration
        self.sequence = sequence
        self.isKeyFrame = isKeyFrame
        self.cameraReservation = cameraReservation
        self.diagnosticTrace = diagnosticTrace
        self.nativeWork = nativeWork
        self.nativeStorage = nativeStorage
        self.nativeOwner = nativeOwner
    }
}

/// Camera-only bound spanning queued events, VT callbacks and scheduled playout.
/// Screen callers do not reserve capacity and retain their existing behavior.
private final class CameraDecoderBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    private var gap = false
    private var generation: UInt64 = 0
    init(limit: Int) { self.limit = limit }
    func reserve() -> CameraDecoderReservation? {
        lock.withLock {
            guard count < limit else { return nil }
            count += 1
            return CameraDecoderReservation(generation: generation) { [self] in lock.withLock { count -= 1 } }
        }
    }
    func markGap() -> Bool { lock.withLock { let first = !gap; gap = true; generation &+= 1; return first } }
    func isCurrent(_ candidate: UInt64) -> Bool { lock.withLock { candidate == generation } }
    func takeGap() -> Bool { lock.withLock { let value = gap; gap = false; return value } }
}

private final class CameraDecoderReservation: @unchecked Sendable {
    let generation: UInt64
    private let release: @Sendable () -> Void
    init(generation: UInt64, release: @escaping @Sendable () -> Void) {
        self.generation = generation
        self.release = release
    }
    deinit { release() }
}

private struct SendableDecodedPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}
