import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore

struct NativeMediaAttemptID: Hashable, Sendable {
    let sessionID: UUID
    let attemptID: UUID
    init(sessionID: UUID = UUID(), attemptID: UUID = UUID()) {
        self.sessionID = sessionID
        self.attemptID = attemptID
    }
}

enum NativeMediaFailure: Error, LocalizedError, Equatable, Sendable {
    case capacity
    case invalidSize
    case nativeCleanup(Int32)
    case cleanupIncomplete
    case codec(String)

    var errorDescription: String? {
        switch self {
        case .capacity, .invalidSize, .codec: String(localized: "ERROR_MEDIA_PLAYBACK")
        case .nativeCleanup, .cleanupIncomplete: String(localized: "ERROR_MEDIA_CLEANUP")
        }
    }
}
enum NativeMediaAdmission<Value> {
    case granted(Value)
    case pressure
    case obsolete
    case fatal(NativeMediaFailure)
}

enum NativeMediaPressurePolicy: Equatable, Sendable {
    case strict
    case recoverableRealtime
}
struct NativeMediaStatus: Sendable {
    let identity: NativeMediaSourceIdentity
    var inputLostThrough: UInt64 = 0
    var inputDropped: UInt64 = 0
    var outputSequence: UInt64 = 0
    var outputPressure: Bool = false
    var outputDropped: UInt64 = 0
}

struct NativeMediaSnapshot: Equatable, Sendable {
    let jobs: Int
    let bytes: Int
    let decoded: Int
    let pcm: Int
    let operations: Int
    let fences: Int
    let retired: Bool
    var actuallySettled: Bool { retired && jobs == 0 && bytes == 0 && operations == 0 && fences == 0 }
}

struct NativeMediaSettlement: Sendable {
    let attemptID: NativeMediaAttemptID
    let snapshot: NativeMediaSnapshot
    let failure: NativeMediaFailure?
    let sourceFailure: NativeMediaFailure?
    var succeeded: Bool { snapshot.actuallySettled && failure == nil }
}

struct NativeMediaRetirement: Sendable {
    fileprivate let attempt: NativeMediaAttempt
    var snapshot: NativeMediaSnapshot { attempt.snapshot }
    /// The first retirement deadline also bounds a caller's joint resources.
    /// Native success remains immutable even if those other references linger.
    var originalCutoffExpired: Bool { attempt.originalRetirementCutoffExpired }
    func wait() async -> NativeMediaSettlement { await attempt.wait() }
}

/// Identity and explicit native reference accounting, not a measurement of
/// opaque vendor allocations or downstream renderer/recorder ownership.
final class NativeMediaAttempt: @unchecked Sendable {
    static let maximumJobs = 64
    // Audio is allowed to use most of the shared ingress budget, but it must
    // never occupy every owned copy/job while a complete video IDR is waiting.
    // Keeping one output-window worth of jobs available prevents AAC bursts
    // from declining the only independently decodable frame during startup or
    // bounded recovery.
    static let maximumAudioJobs = maximumJobs - maximumOutputs
    static let maximumBytes = 128 * 1024 * 1024
    static let maximumVideoPayload = 4 * 1024 * 1024
    static let maximumConfiguration = 64 * 1024
    static let maximumDecoded = 16 * 1024 * 1024
    static let maximumPCM = 1024 * 1024
    static let maximumOutputs = 16
    static let retirementSeconds = 5.0

    enum AllocationKind: Sendable { case storage, decoded, pcm }
    let id: NativeMediaAttemptID
    private let lock = NSLock()
    private var jobs = 0
    private var audioJobs = 0
    private var bytes = 0
    private var decoded = 0
    private var pcm = 0
    private var operations = 0
    private var fences = 0
    private var mediaStatus: [NativeMediaStatus?] = [nil, nil, nil]
    private var mediaStatusDirty=[false,false,false]
    private var outputPressureDrops = 0
    var mediaOutputPressureDrops: Int { lock.withLock { outputPressureDrops } }
    func recordMedia(_ identity: NativeMediaSourceIdentity?, inputLost: Bool = false, outputPressure: Bool? = nil) {
        lock.withLock {
            guard !retired else { return }
            if outputPressure == true { outputPressureDrops += 1 }
            guard let identity, identity.track == 1 || identity.track == 2 else { return }
            let index = Int(identity.track)
            var status = mediaStatus[index] ?? NativeMediaStatus(identity: identity)
            if (status.identity.epoch, status.identity.configuration) != (identity.epoch, identity.configuration) {
                guard identity.epoch > status.identity.epoch || identity.epoch == status.identity.epoch && identity.configuration > status.identity.configuration else { return }
                status = NativeMediaStatus(identity: identity)
            }
            if inputLost,identity.sequence>status.inputLostThrough {
                status.inputLostThrough=identity.sequence;status.inputDropped+=1
            }
            if let outputPressure, identity.sequence > status.outputSequence {
                status.outputSequence = identity.sequence; status.outputPressure = outputPressure
                if outputPressure && !inputLost { status.outputDropped += 1 }
            }
            mediaStatus[index] = status
            mediaStatusDirty[index]=true
        }
    }
    func takeMediaStatus() -> [NativeMediaStatus] {
        lock.withLock {
            let values=(1...2).compactMap {mediaStatusDirty[$0] ? mediaStatus[$0]:nil}
            mediaStatusDirty=[false,false,false];return values
        }
    }
    private var retired = false
    private var retirementDeadline: TimeInterval?
    private var settledAt: TimeInterval?
    private var failure: NativeMediaFailure?
    private var outcome: NativeMediaSettlement?
    private var waiters: [CheckedContinuation<NativeMediaSettlement, Never>] = []
    private var retirementActions: [@Sendable () -> Void] = []
    private let failureHandler: @Sendable (NativeMediaFailure) -> Void
    private let now: @Sendable () -> TimeInterval
    private let watchdog: @Sendable (@escaping @Sendable () -> Void) -> Void

    convenience init(id: NativeMediaAttemptID = .init(), failureHandler: @escaping @Sendable (NativeMediaFailure) -> Void = { _ in }) {
        self.init(id: id, now: { ProcessInfo.processInfo.systemUptime }, watchdog: { action in
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.retirementSeconds, execute: action)
        }, failureHandler: failureHandler)
    }

    init(id: NativeMediaAttemptID = .init(), now: @escaping @Sendable () -> TimeInterval,
         watchdog: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
         failureHandler: @escaping @Sendable (NativeMediaFailure) -> Void = { _ in }) {
        self.id = id
        self.now = now
        self.watchdog = watchdog
        self.failureHandler = failureHandler
    }

    var isAdmitted: Bool { lock.withLock { !retired } }
    var snapshot: NativeMediaSnapshot { lock.withLock { snapshotLocked() } }
    fileprivate var originalRetirementCutoffExpired: Bool {
        lock.withLock { retirementDeadline.map { now() >= $0 } ?? false }
    }

    private func snapshotLocked() -> NativeMediaSnapshot {
        .init(jobs: jobs, bytes: bytes, decoded: decoded, pcm: pcm,
              operations: operations, fences: fences, retired: retired)
    }

    private func recordSettlementLocked() {
        if retired, settledAt == nil, snapshotLocked().actuallySettled { settledAt = now() }
    }

    /// Registered before native work begins. The returned fence is retained by
    /// the consumer through its actual cleanup, never just until queue enqueue.
    func registerCleanup(_ action: @escaping @Sendable () -> Void) -> NativeMediaLease {
        let runNow = lock.withLock {
            fences += 1
            if retired { return true }
            retirementActions.append(action)
            return false
        }
        let fence = NativeMediaLease { [self] in
            lock.withLock { fences -= 1; recordSettlementLocked() }
            publishIfSettled()
        }
        if runNow { action() }
        return fence
    }

    @discardableResult
    func retire() -> NativeMediaRetirement {
        let actions: [@Sendable () -> Void]? = lock.withLock {
            guard !retired else { return nil }
            retired = true
            retirementDeadline = now() + Self.retirementSeconds
            recordSettlementLocked()
            let actions = retirementActions
            retirementActions.removeAll()
            return actions
        }
        if let actions {
            // Delivery only wakes publication. Timeliness is decided from the
            // first retirement cutoff, even if this callback runs late.
            watchdog { [self] in
                publish(timedOut: true)
            }
            actions.forEach { $0() }
            publishIfSettled()
        }
        return .init(attempt: self)
    }

    func fail(_ reason: NativeMediaFailure) {
        let first = lock.withLock {
            guard failure == nil else { return false }
            failure = reason
            return true
        }
        retire()
        if first { failureHandler(reason) }
    }

    func admit(_ event: ScrcpyStreamEvent, audio: Bool, binding: NativeFrameBinding?, trace: PrimaryMediaTrace?, externalRetention: NativeMediaLease? = nil, sourceIdentity: NativeMediaSourceIdentity? = nil) -> NativeMediaWork? {
        switch admitMedia(event, audio: audio, binding: binding, trace: trace, externalRetention: externalRetention, sourceIdentity: sourceIdentity) {
        case let .granted(work): return work
        case .pressure: fail(.capacity); return nil
        case let .fatal(reason): fail(reason); return nil
        case .obsolete: return nil
        }
    }
    func admitMedia(_ event: ScrcpyStreamEvent, audio: Bool, binding: NativeFrameBinding?, trace: PrimaryMediaTrace?, externalRetention: NativeMediaLease? = nil, sourceIdentity: NativeMediaSourceIdentity? = nil, pressurePolicy: NativeMediaPressurePolicy = .strict) -> NativeMediaAdmission<NativeMediaWork> {
        let count: Int
        let cap: Int
        switch event {
        case .codec: count = 4; cap = Self.maximumConfiguration
        case .videoSession: count = 12; cap = Self.maximumConfiguration
        case let .packet(packet):
            count = packet.payload.count
            cap = audio || packet.isConfiguration ? Self.maximumConfiguration : Self.maximumVideoPayload
        }
        guard isAdmitted else { return .obsolete }
        guard count > 0, count <= cap else { return .fatal(.invalidSize) }
        let capacity: Int
        if case .packet = event { capacity = NativeMediaBuffer.capacity(for: count) }
        else { capacity = count }
        let accepted = lock.withLock {
            guard !retired,
                  jobs < Self.maximumJobs,
                  !audio || audioJobs < Self.maximumAudioJobs,
                  capacity <= Self.maximumBytes - bytes
            else { return false }
            jobs += 1
            if audio { audioJobs += 1 }
            bytes += capacity
            return true
        }
        guard accepted else { return isAdmitted ? .pressure : .obsolete }
        let job = NativeMediaLease { [self] in
            lock.withLock {
                jobs -= 1
                if audio { audioJobs -= 1 }
                recordSettlementLocked()
            }
            publishIfSettled()
        }
        let external = NativeMediaExternalRetention(externalRetention)
        let input = NativeMediaLease { [self, job, external] in
            external.releaseAtFinalInputReference()
            lock.withLock { bytes -= capacity; recordSettlementLocked() }
            withExtendedLifetime(job) {}
            // Heap Data and the work envelope share this lease. Inline Data
            // remains bounded by the envelope, as for the native byte charge.
            publishIfSettled()
        }
        let ownedEvent: ScrcpyStreamEvent
        if case let .packet(packet) = event {
            let payload = NativeMediaBuffer.copy(packet.payload, lease: input)
            ownedEvent = .packet(.init(isConfiguration: packet.isConfiguration, isKeyFrame: packet.isKeyFrame,
                presentationTimeUs: packet.presentationTimeUs, payload: payload))
        } else { ownedEvent = event }
        return .granted(NativeMediaWork(attempt: self, job: job, input: input, event: ownedEvent, binding: binding, trace: trace, sourceIdentity: sourceIdentity, pressurePolicy: pressurePolicy))
    }

    func operation() -> NativeMediaLease? {
        let accepted = lock.withLock {
            guard !retired else { return false }
            operations += 1
            return true
        }
        guard accepted else { return nil }
        return NativeMediaLease { [self] in
            lock.withLock { operations -= 1; recordSettlementLocked() }
            publishIfSettled()
        }
    }

    func reserve(_ count: Int, kind: AllocationKind = .storage, job: NativeMediaLease) -> NativeMediaLease? {
        switch reserveMedia(count, kind: kind, job: job) {
        case let .granted(lease): return lease
        case .pressure: fail(.capacity); return nil
        case let .fatal(reason): fail(reason); return nil
        case .obsolete: return nil
        }
    }
    func reserveMedia(_ count: Int, kind: AllocationKind, job: NativeMediaLease) -> NativeMediaAdmission<NativeMediaLease> {
        guard isAdmitted else { return .obsolete }
        let limit: Int = switch kind { case .storage: Self.maximumBytes; case .decoded: Self.maximumDecoded; case .pcm: Self.maximumPCM }
        guard count >= 0, kind == .storage || count > 0, count <= limit else { return .fatal(.invalidSize) }
        let accepted = lock.withLock {
            guard !retired, count <= Self.maximumBytes - bytes,
                  kind != .decoded || decoded < Self.maximumOutputs,
                  kind != .pcm || pcm < Self.maximumOutputs else { return false }
            bytes += count
            if kind == .decoded { decoded += 1 }
            if kind == .pcm { pcm += 1 }
            return true
        }
        guard accepted else { return isAdmitted ? .pressure : .obsolete }
        return .granted(NativeMediaLease { [self, job] in
            lock.withLock {
                bytes -= count
                if kind == .decoded { decoded -= 1 }
                if kind == .pcm { pcm -= 1 }
                recordSettlementLocked()
            }
            withExtendedLifetime(job) {}
            publishIfSettled()
        })
    }

    fileprivate func wait() async -> NativeMediaSettlement {
        await withCheckedContinuation { continuation in
            let ready: NativeMediaSettlement? = lock.withLock {
                if let outcome { return outcome }
                waiters.append(continuation)
                return nil as NativeMediaSettlement?
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func publishIfSettled() { publish(timedOut: false) }

    private func publish(timedOut: Bool) {
        let publication: (NativeMediaSettlement, [CheckedContinuation<NativeMediaSettlement, Never>])? = lock.withLock {
            guard outcome == nil, let deadline = retirementDeadline else { return nil }
            let snapshot = snapshotLocked()
            let expired = (settledAt ?? now()) >= deadline
            guard snapshot.actuallySettled || (timedOut && expired) else { return nil }
            let result = NativeMediaSettlement(attemptID: id, snapshot: snapshot,
                failure: snapshot.actuallySettled && !expired ? failure : .cleanupIncomplete, sourceFailure: failure)
            outcome = result
            let continuations = waiters
            waiters.removeAll()
            return (result, continuations)
        }
        if let (result, continuations) = publication {
            continuations.forEach { $0.resume(returning: result) }
        }
    }
}

/// Shared references to this object release capacity only at their final drop.
final class NativeMediaLease: @unchecked Sendable {
    private let release: @Sendable () -> Void
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}

final class NativeMediaWork: @unchecked Sendable {
    let attempt: NativeMediaAttempt
    let job: NativeMediaLease
    let input: NativeMediaLease
    let event: ScrcpyStreamEvent
    let binding: NativeFrameBinding?
    let trace: PrimaryMediaTrace?
    let sourceIdentity: NativeMediaSourceIdentity?
    let pressurePolicy: NativeMediaPressurePolicy
    let installedConfigurationID: UUID?
    init(attempt: NativeMediaAttempt, job: NativeMediaLease, input: NativeMediaLease, event: ScrcpyStreamEvent,
         binding: NativeFrameBinding?, trace: PrimaryMediaTrace?, sourceIdentity: NativeMediaSourceIdentity? = nil,
         pressurePolicy: NativeMediaPressurePolicy = .strict, installedConfigurationID: UUID? = nil) {
        self.attempt = attempt; self.job = job; self.input = input
        self.event = event
        self.binding = binding; self.trace = trace
        self.sourceIdentity = sourceIdentity
        self.pressurePolicy = pressurePolicy
        self.installedConfigurationID = installedConfigurationID
    }
    func reserve(_ bytes: Int, kind: NativeMediaAttempt.AllocationKind = .storage) -> NativeMediaLease? {
        if case let .packet(packet) = event, !packet.isConfiguration {
            return reserveMedia(bytes, kind: kind, inputLoss: true)
        }
        return attempt.reserve(bytes, kind: kind, job: job)
    }
    func reserveMedia(_ bytes: Int, kind: NativeMediaAttempt.AllocationKind, inputLoss: Bool = false) -> NativeMediaLease? {
        // USB/camera work keeps its original strict policy. Authenticated QUIC
        // and explicitly classified Wireless ADB realtime packets may shed one
        // output or input packet under transient pressure without retiring the
        // logical scrcpy session.
        guard sourceIdentity != nil || pressurePolicy == .recoverableRealtime else {
            return attempt.reserve(bytes, kind: kind, job: job)
        }
        switch attempt.reserveMedia(bytes, kind: kind, job: job) {
        case let .granted(lease): return lease
        case .pressure:
            attempt.recordMedia(sourceIdentity, inputLost: inputLoss, outputPressure: kind == .storage ? nil : true)
            return nil
        case .obsolete: return nil
        case let .fatal(reason): attempt.fail(reason); return nil
        }
    }
}

/// Transport-independent original admission values. Never reconstruct these
/// from mutable session state or substitute a diagnostics generation.
struct NativeMediaSourceIdentity: Equatable, Sendable {
    let owner, generation, targetToken, sequence: UInt64
    let scid, displayID, epoch, configuration, flags, track, captureKind, enabled: UInt32
    let session: [UInt8]
}

/// Output-only lifetime: no compressed event, input allocation or copy ticket.
struct NativeMediaOutputContext: Sendable {
    let attempt: NativeMediaAttempt
    let job: NativeMediaLease
    let binding: NativeFrameBinding?
    let trace: PrimaryMediaTrace?
    let sourceIdentity: NativeMediaSourceIdentity?
    let decoderGeneration: UInt64
    let playoutGeneration: UInt64
    init(work: NativeMediaWork, decoderGeneration: UInt64, playoutGeneration: UInt64) {
        attempt = work.attempt; job = work.job; binding = work.binding
        trace = work.trace; sourceIdentity = work.sourceIdentity
        self.decoderGeneration = decoderGeneration; self.playoutGeneration = playoutGeneration
    }
}

final class NativeFrameBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = true
    let handler: @MainActor @Sendable (NativeDecodedFrame) -> Void
    init(handler: @escaping @MainActor @Sendable (NativeDecodedFrame) -> Void) { self.handler = handler }
    var isAdmitted: Bool { lock.withLock { admitted } }
    func revoke() { lock.withLock { admitted = false } }
}

struct NativeDecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let epoch: UInt32
    let context: NativeMediaOutputContext
    let allocation: NativeMediaLease
    var trace: PrimaryMediaTrace? { context.trace }
    var isAdmitted: Bool { context.attempt.isAdmitted && (context.binding?.isAdmitted ?? true) }
}
