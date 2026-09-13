import CoreMedia
import CoreVideo
import Foundation

/// Local authorization only. Camera media has no request/generation field on
/// today's wire; this cannot classify old packets arriving after a new Start.
final class CameraPublicationPermit: @unchecked Sendable {
    let deviceID: String
    let companionID: String
    let connectionGeneration: UInt64
    let attemptID = UUID()
    let requestID: String
    let attemptOrdinal: UInt64
    private let lock = NSLock()
    private var admitted = true
    private var retirement: CameraRetirement?
    private var state = CameraLifecycleState()
    private let startedAt: UInt64
    private let now: @Sendable () -> UInt64
    private let diagnostic: @Sendable (CameraLifecycleDiagnostic) -> Void

    init(deviceID: String, companionID: String, connectionGeneration: UInt64, requestID: String,
         attemptOrdinal: UInt64 = 0,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         diagnostic: @escaping @Sendable (CameraLifecycleDiagnostic) -> Void = CameraLifecycleDiagnostic.log) {
        self.deviceID = deviceID
        self.companionID = companionID
        self.connectionGeneration = connectionGeneration
        self.requestID = requestID
        self.attemptOrdinal = attemptOrdinal
        self.now = now
        self.startedAt = now()
        self.diagnostic = diagnostic
        record(.started)
    }

    var isAdmitted: Bool { lock.withLock { admitted } }
    var lifecycle: CameraLifecycleState { lock.withLock { state } }
    func revoke(reason: CameraRetirementReason = .generationLoss) {
        lock.withLock {
            // Ingress/session invalidation may repeat after a cleanup result.
            // Closing already-closed admission is not a cleanup retry.
            guard admitted else { return }
            admitted = false
            if state.retire(reason: reason) { record(.retiring) }
        }
    }

    /// Called only immediately before an actual retained-writer cleanup attempt.
    /// The physical retry keeps the first retirement's cause and identity.
    fileprivate func retryWriterCleanup() -> Bool {
        lock.withLock {
            guard state.phase == .cleanupFailed, let reason = state.retirementReason,
                  state.retire(reason: reason) else { return false }
            record(.retiring)
            return true
        }
    }

    fileprivate func published() -> Bool {
        lock.withLock {
            guard admitted, state.publish() else { return false }
            record(.publishing)
            return true
        }
    }

    fileprivate func completedRetirement(_ result: Result<Void, Error>) -> Bool {
        lock.withLock {
            let succeeded: Bool
            if case .success = result { succeeded = true } else { succeeded = false }
            guard state.completeRetirement(succeeded: succeeded) else { return false }
            record(succeeded ? .retired : .cleanupFailed)
            return true
        }
    }

    // Called under the permit lock, keeping diagnostic order equal to actual
    // transition order even when a worker success races synchronous Stop.
    private func record(_ kind: CameraLifecycleDiagnostic.Kind) {
        let timestamp = now()
        diagnostic(.init(kind: kind, attemptOrdinal: attemptOrdinal, connectionGeneration: connectionGeneration,
                         reason: state.retirementReason, elapsedMilliseconds: (timestamp >= startedAt ? timestamp - startedAt : 0) / 1_000_000))
    }

    fileprivate func beginRetirement(reason: CameraRetirementReason) -> (barrier: CameraRetirement, isNew: Bool) {
        lock.withLock {
            admitted = false
            if let retirement, !retirement.hasFailed { return (retirement, false) }
            if state.retire(reason: reason) { record(.retiring) }
            let barrier = CameraRetirement()
            retirement = barrier
            return (barrier, true)
        }
    }
}

final class CameraRetirement: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Result<Void, Error>, Never>] = []

    fileprivate var hasFailed: Bool {
        lock.withLock { if case .failure? = result { return true }; return false }
    }

    func wait() async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    fileprivate func finish(_ result: Result<Void, Error>) {
        let continuations = lock.withLock {
            self.result = result
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        continuations.forEach { $0.resume(returning: result) }
    }
}

protocol CameraRingPublishing: AnyObject, Sendable {
    func write(_ pixelBuffer: CVPixelBuffer, epoch: UInt32) throws
    func retire() throws
}

extension CameraRingBufferWriter: CameraRingPublishing {}

struct CameraPublicationFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let epoch: UInt32
    let permit: CameraPublicationPermit
}

/// The state lock only changes admission/mailboxes. All file operations,
/// normalization and copies run on the serial worker. At most one frame waits
/// behind the executing frame; newer useful frames replace that pending frame.
final class CameraPublication: @unchecked Sendable {
    private let lock = NSLock()
    private let worker: DispatchQueue
    private let makeWriter: @Sendable () throws -> any CameraRingPublishing
    private let failure: @Sendable (Error, CameraPublicationPermit?) -> Void
    private let transition: @Sendable (CameraPublicationPermit) -> Void
    private let now: @Sendable () -> UInt64
    private let diagnostic: @Sendable (CameraLifecycleDiagnostic) -> Void
    private var owner: CameraPublicationPermit?
    private var terminal = false
    private var pending: CameraPublicationFrame?
    private var scheduledPermit: CameraPublicationPermit?
    private var lifecycleRevision: UInt64 = 0
    private var nextAttemptOrdinal: UInt64 = 0
    // Worker-confined state; retain failed retirement for an explicit retry.
    private var writer: (any CameraRingPublishing)?
    private var writerPermit: CameraPublicationPermit?

    init(worker: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.camera-publication"),
         makeWriter: @escaping @Sendable () throws -> any CameraRingPublishing = { try CameraRingBufferWriter() },
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         diagnostic: @escaping @Sendable (CameraLifecycleDiagnostic) -> Void = CameraLifecycleDiagnostic.log,
         transition: @escaping @Sendable (CameraPublicationPermit) -> Void = { _ in },
         failure: @escaping @Sendable (Error, CameraPublicationPermit?) -> Void) {
        self.worker = worker
        self.makeWriter = makeWriter
        self.failure = failure
        self.now = now
        self.diagnostic = diagnostic
        self.transition = transition
    }

    var currentPermit: CameraPublicationPermit? { lock.withLock { owner } }
    var revision: UInt64 { lock.withLock { lifecycleRevision } }

    func owner(deviceID: String, companionID: String? = nil,
               connectionGeneration: UInt64? = nil, requestID: String? = nil) -> CameraPublicationPermit? {
        lock.withLock {
            guard let owner, owner.deviceID == deviceID,
                  companionID == nil || owner.companionID == companionID,
                  connectionGeneration == nil || owner.connectionGeneration == connectionGeneration,
                  requestID == nil || owner.requestID == requestID else { return nil }
            return owner
        }
    }

    /// Only the explicit Start action may call this method.
    func start(deviceID: String, companionID: String, connectionGeneration: UInt64,
               requestID: String) -> CameraPublicationPermit? {
        lock.withLock {
            guard !terminal else { return nil }
            lifecycleRevision &+= 1
            owner?.revoke(reason: .replacement)
            pending = nil
            scheduledPermit = nil
            nextAttemptOrdinal &+= 1
            let permit = CameraPublicationPermit(deviceID: deviceID, companionID: companionID,
                                                 connectionGeneration: connectionGeneration, requestID: requestID,
                                                 attemptOrdinal: nextAttemptOrdinal, now: now, diagnostic: diagnostic)
            owner = permit
            worker.async { [self] in
                do {
                    try retireWriter()
                    guard permit.isAdmitted else { return }
                    writer = try makeWriter()
                    writerPermit = permit
                } catch {
                    permit.revoke(reason: .publicationFailure)
                    transition(permit)
                    failure(error, permit)
                }
            }
            return permit
        }
    }

    func submit(_ frame: CameraPublicationFrame) {
        lock.withLock {
            guard owner === frame.permit, frame.permit.isAdmitted else { return }
            pending = frame
            guard scheduledPermit !== frame.permit else { return }
            scheduledPermit = frame.permit
            let permit = frame.permit
            worker.async { [self] in drainOne(for: permit) }
        }
    }

    /// Closes admission before returning; its result completes after any write
    /// already executing and the sanitization/flush. A stale retire is a no-op.
    func retire(_ permit: CameraPublicationPermit, reason: CameraRetirementReason = .stop) -> CameraRetirement {
        lock.withLock {
            let (barrier, isNew) = permit.beginRetirement(reason: reason)
            guard isNew else { return barrier }
            transition(permit)
            if owner === permit {
                lifecycleRevision &+= 1
                owner = nil
                pending = nil
                scheduledPermit = nil
            }
            worker.async { [self] in
                do {
                    if writerPermit === permit { try retireWriter() }
                    if permit.completedRetirement(.success(())) { transition(permit) }
                    barrier.finish(.success(()))
                } catch {
                    failure(error, permit)
                    if permit.completedRetirement(.failure(error)) { transition(permit) }
                    barrier.finish(.failure(error))
                }
            }
            return barrier
        }
    }

    func shutdown() -> CameraRetirement {
        let barrier = CameraRetirement()
        lock.withLock {
            terminal = true
            lifecycleRevision &+= 1
            let retiringOwner = owner
            retiringOwner?.revoke(reason: .quit)
            if let retiringOwner { transition(retiringOwner) }
            owner = nil
            pending = nil
            scheduledPermit = nil
            worker.async { [self] in
                do {
                    try retireWriter()
                    if let retiringOwner, retiringOwner.completedRetirement(.success(())) { transition(retiringOwner) }
                    barrier.finish(.success(()))
                } catch {
                    failure(error, nil)
                    if let retiringOwner, retiringOwner.completedRetirement(.failure(error)) { transition(retiringOwner) }
                    barrier.finish(.failure(error))
                }
            }
        }
        return barrier
    }

    private func retireWriter() throws {
        guard let writer else { return }
        // Start, explicit retirement and Quit all use this exact physical
        // boundary. A retained failure enters retry only when it is operated.
        if let writerPermit, writerPermit.retryWriterCleanup() { transition(writerPermit) }
        do { try writer.retire() }
        catch {
            if let writerPermit, writerPermit.completedRetirement(.failure(error)) { transition(writerPermit) }
            throw error
        }
        // Also completes a writer displaced directly by Start. AppModel normally
        // retires explicitly first; the exact permit barrier still owns its wait.
        if let writerPermit, writerPermit.completedRetirement(.success(())) { transition(writerPermit) }
        self.writer = nil
        writerPermit = nil
    }

    private func drainOne(for permit: CameraPublicationPermit) {
        let frame = lock.withLock {
            guard scheduledPermit === permit, pending?.permit === permit else { return nil as CameraPublicationFrame? }
            let frame = pending
            pending = nil
            return frame
        }
        if let frame, frame.permit.isAdmitted, writerPermit === frame.permit, let writer {
            do {
                try writer.write(frame.pixelBuffer, epoch: frame.epoch)
                if frame.permit.published() { transition(frame.permit) }
            } catch {
                frame.permit.revoke(reason: .publicationFailure)
                transition(frame.permit)
                failure(error, frame.permit)
            }
        }
        lock.withLock {
            guard scheduledPermit === permit else { return }
            if pending?.permit === permit { worker.async { [self] in drainOne(for: permit) } }
            else { scheduledPermit = nil }
        }
    }
}

/// Latest permit only, no retained frames and at most one pending MainActor
/// transition task. Successful repeated writes do not enter this seam at all.
final class CameraPublicationTransitionDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CameraPublicationPermit?
    private var scheduled = false
    private let schedule: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    private let deliver: @MainActor @Sendable (CameraPublicationPermit) -> Void

    init(schedule: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { action in Task { @MainActor in action() } },
         deliver: @escaping @MainActor @Sendable (CameraPublicationPermit) -> Void) {
        self.schedule = schedule
        self.deliver = deliver
    }

    func submit(_ permit: CameraPublicationPermit) {
        let enqueue = lock.withLock {
            // Ordinals are monotonic within the one publication service. Late
            // A completion cannot replace a pending B transition.
            if pending == nil || pending!.attemptOrdinal <= permit.attemptOrdinal { pending = permit }
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if enqueue {
            schedule { [self] in
                let latest = lock.withLock {
                    let value = pending
                    pending = nil
                    scheduled = false
                    return value
                }
                if let latest { deliver(latest) }
            }
        }
    }
}

/// One pending preview frame/one MainActor task per attempt; old callbacks carry
/// their original permit through this hop and are checked again before display.
final class CameraPreviewDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CameraPublicationFrame?
    private var scheduled = false
    private let deliver: @MainActor @Sendable (CameraPublicationFrame) -> Void

    init(deliver: @escaping @MainActor @Sendable (CameraPublicationFrame) -> Void) { self.deliver = deliver }

    func submit(_ frame: CameraPublicationFrame) {
        lock.withLock {
            guard frame.permit.isAdmitted else { return }
            pending = frame
            guard !scheduled else { return }
            scheduled = true
            Task { @MainActor [self] in
                let latest = lock.withLock {
                    let value = pending
                    pending = nil
                    scheduled = false
                    return value
                }
                if let latest, latest.permit.isAdmitted { deliver(latest) }
            }
        }
    }

    func clear() { lock.withLock { pending = nil } }
}
