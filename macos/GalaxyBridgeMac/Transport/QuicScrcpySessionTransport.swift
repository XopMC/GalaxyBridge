#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import GalaxyBridgeQuicBackend
import OSLog
#if GB_QUIC_BACKEND_QA
@_silgen_name("gb_backend_qa_control_observation")
private func qaControlObservation(_ owner: UInt64, _ values: UnsafeMutablePointer<UInt64>) -> UInt32
#endif

/// One dedicated OS thread owns every non-release C call. The condition only
/// protects bounded ingress/scalars; no vendor call or actor hop holds it.
struct QuicMediaHealthLogGate {
    private var last:[UInt64?]=[nil,nil,nil]
    private var dirty=[false,false,false]
    private var finished=[false,false,false]
    mutating func take(track:Int,changed:Bool,now:UInt64,enabled:Bool,final:Bool)->Bool {
        guard enabled,(1...2).contains(track),!finished[track] else{return false}
        dirty[track] = dirty[track] || changed
        if final {finished[track]=true}
        guard dirty[track], final || last[track].map({now >= $0 && now-$0 >= 250_000_000}) ?? true else{return false}
        last[track]=now;dirty[track]=false;return true
    }
}

/// VideoToolbox keeps inter-frame reference state.  QUIC deliberately drops a
/// complete stale AU after any incomplete datagram assembly, so the next AU
/// handed to Swift may be valid bytes while still being non-contiguous with
/// the decoder's reference chain.  Detect that exact boundary without
/// interpreting still-screen gaps as loss.
struct QuicVideoSequenceContinuity {
    private var last: UInt64?

    mutating func observe(_ sequence: UInt64) -> Bool {
        defer { last = sequence }
        guard let last else { return false }
        return sequence != last &+ 1
    }

    mutating func reset() { last = nil }
}

final class QuicScrcpySessionTransport: ScrcpySessionTransport, @unchecked Sendable {
    struct Callbacks: Sendable {
        let ready: @Sendable () -> Void
        let media: @Sendable (QuicBackendBridge.AdmittedMedia) -> Void
        let device: @Sendable (ScrcpyDeviceMessage, QuicDeviceDelivery) -> Void
        let display: @Sendable (ScrcpyOwnedProcessOutputEvent) -> Void
        let failure: @Sendable (QuicBackendError) -> Void
        var health: @Sendable (QuicMediaHealth) -> Void = { _ in }
    }
    private final class Command: @unchecked Sendable {
        private(set) var bytes: Data
        let received: UInt64
        let trace: PrimaryMediaTrace?
        private let release: @Sendable () -> Void
        init(bytes: Data, received: UInt64, trace: PrimaryMediaTrace?, release: @escaping @Sendable () -> Void) {
            self.bytes = bytes; self.received = received; self.trace = trace; self.release = release
        }
        deinit { bytes = Data(); release() }
    }
    private enum CommandCompletion {
        case processed, failed, dropped
    }
    private struct PendingDevice {
        let message: ScrcpyDeviceMessage
        let delivery: QuicDeviceDelivery
        let bytes: Int
    }
    private let condition = NSCondition()
    private var healthRevisions = [UInt64.max, UInt64.max, UInt64.max]
    private var latestHealth: [QuicMediaHealth?] = [nil,nil,nil]
    private var healthLogGate=QuicMediaHealthLogGate()
    private var mediaRetryGate=BoundedMediaRecoveryRetryGate()
    private let healthLogger = Logger(subsystem:"com.xopmc.GalaxyBridge",category:"scrcpy")
    private func publishHealth(_ backend: QuicBackendBridge, final: Bool = false) throws {
        let now=QuicReceiptClock.now
        for track in 1...2 {
            let value=try backend.mediaHealth(UInt32(track))
            let changed=latestHealth[track] != value
            latestHealth[track]=value
            if healthRevisions[track] != value.revision {
                healthRevisions[track]=value.revision; callbacks.health(value)
            }
            if healthLogGate.take(track:track,changed:changed,now:now,enabled:diagnostics != nil,final:final) {
                let line="GBQH1 \(launch.generation) \(launch.scid) \(track) \(value.state) \(value.reason) \(value.epoch) \(value.configuration) \(value.revision) \(value.episode) \(value.attempt) \(value.declined) \(value.skipped) \(value.admittedInputDropped) \(value.outputDropped) \(value.outputPressure)"
                healthLogger.info("\(line,privacy:.public)")
            }
        }
    }
    private func serviceBoundedMediaRetry(_ backend: QuicBackendBridge) throws {
        let health = try backend.mediaHealth(1)
        if let episode = mediaRetryGate.retryEpisode(
            state: health.state,
            reason: health.reason,
            attempt: health.attempt,
            episode: health.episode
        ) {
            try backend.retryMedia(episode: episode)
        }
    }
    private var commands: [Command] = []
    private var queuedBytes = 0
    private var retainedCommands = 0
    private var nativeSettlement: NativeMediaSettlement?
    private var stopping = false
    private var deviceReferences = 0
    private var physical = false
    private var outcome: ScrcpyTransportSettlement?
    private var waiters: [CheckedContinuation<ScrcpyTransportSettlement, Never>] = []
    private let native: ScrcpyNativeMediaOwner
    private let callbacks: Callbacks
    private let launch: QuicBackendBridge.Launch
    private let diagnostics: PrimaryMediaDiagnostics?
    private var initialFailure: UInt32 = 0
    // Mutable only so the QA target can exercise the opt-in path without
    // mutating the process environment shared by unrelated parallel tests.
    var firstErrorEnabled = ProcessInfo.processInfo.environment["GB_QUIC_FIRST_ERROR_DIAGNOSTICS"] == "1"
    private var firstErrorReported = false
    // Internal scheduling observation only; nil in ordinary callers.
    var beforeCleanup: (@Sendable () -> Void)?
    var beforeCommandService: (@Sendable () -> Void)?
#if GB_QUIC_BACKEND_QA
    var stockObservation: (@Sendable ([UInt64]) -> Void)?
    var firstErrorObservation: (@Sendable (String) -> Void)?
    var beforeFirstErrorEmission: (@Sendable (UInt32) -> Void)?
    var beforeOwnerPoll: (@Sendable (UInt64) -> Void)?
    var firstErrorEmitter: QuicFirstErrorEmitter?
#endif
    private struct FirstError {
        let status, operation: UInt32
        let owner: UInt64
        let bridgeOperation: UInt32
        let used, limit, requested, bytes, byteLimit: Int
    }
    // Caller holds the original decision lock. Only immutable scalars escape.
    private func claimFirstErrorLocked(_ status: UInt32, operation: UInt32, owner: UInt64 = 0,
                                      bridgeOperation: UInt32 = 0, used: Int = 0, limit: Int = 0,
                                      requested: Int = 0, bytes: Int = 0, byteLimit: Int = 0) -> FirstError? {
        guard firstErrorEnabled, !firstErrorReported else { return nil }
        firstErrorReported = true
        return FirstError(status: status, operation: operation, owner: owner, bridgeOperation: bridgeOperation,
                          used: used, limit: limit, requested: requested, bytes: bytes, byteLimit: byteLimit)
    }
    private func reportFirstError(_ status: UInt32, operation: UInt32, bridge: QuicBackendBridge? = nil,
                                  used: Int = 0, limit: Int = 0, requested: Int = 0, bytes: Int = 0, byteLimit: Int = 0) {
        let record = condition.withLock {
            claimFirstErrorLocked(status, operation: operation, owner: bridge?.owner ?? 0,
                                  bridgeOperation: bridge?.diagnosticOperation ?? 0, used: used, limit: limit,
                                  requested: requested, bytes: bytes, byteLimit: byteLimit)
        }
        emitFirstError(record)
    }
    private func emitFirstError(_ record: FirstError?) {
        guard let r = record else { return }
#if GB_QUIC_BACKEND_QA
        beforeFirstErrorEmission?(r.status)
#endif
        // Native counts are a post-error snapshot, not a claim that a specific
        // native limit caused a bridge error. Command/reverse counts above are
        // captured at their original reject comparison.
        let snapshot = native.attempt.snapshot
        let line = "GBQF1 S \(r.owner) \(launch.generation) \(launch.targetToken) \(r.operation) \(r.bridgeOperation) \(r.status) \(r.used) \(r.limit) \(r.requested) \(r.bytes) \(r.byteLimit) \(snapshot.jobs) \(snapshot.bytes) \(snapshot.decoded) \(snapshot.pcm)\n"
        // Fixed nonnegative integers only; <= 15*20 + fixed separators.
        let emitter: QuicFirstErrorEmitter
#if GB_QUIC_BACKEND_QA
        emitter = firstErrorEmitter ?? .shared
#else
        emitter = .shared
#endif
        emitter.offer(Data(line.utf8))
#if GB_QUIC_BACKEND_QA
        firstErrorObservation?(line)
#endif
    }
    var ingressUsage: (commands: Int, bytes: Int) { condition.withLock { (retainedCommands, queuedBytes) } }

    init(launch: QuicBackendBridge.Launch, native: ScrcpyNativeMediaOwner,
         diagnostics: PrimaryMediaDiagnostics? = nil, callbacks: Callbacks) {
        self.launch = launch; self.native = native; self.callbacks = callbacks; self.diagnostics = diagnostics
    }
    func start() { Thread.detachNewThread { [self] in run() } }
    var physicallySettled: Bool { condition.withLock { physical } }

    func send(_ bytes: Data, received: UInt64, trace: PrimaryMediaTrace?) {
        var rejection: FirstError?
        var enqueued = false
        let failed = condition.withLock {
            guard !stopping else { return false }
            guard retainedCommands < 64, bytes.count <= 262144, bytes.count <= 524288 - queuedBytes else {
                rejection = claimFirstErrorLocked(102, operation: 1, used: retainedCommands, limit: 64,
                                                  requested: bytes.count, bytes: queuedBytes, byteLimit: 524288)
                initialFailure = 102; stopping = true; return true
            }
            let count = bytes.count
            if let trace { trace.collector.enter(.control, trace: trace) }
            commands.append(Command(bytes: bytes, received: received, trace: trace) { [self] in
                condition.withLock { retainedCommands -= 1; queuedBytes -= count; condition.signal() }
            })
            retainedCommands += 1; queuedBytes += count
            enqueued = true
            condition.signal(); return false
        }
        if !enqueued, let trace {
            trace.collector.cancelInputProbe(trace: trace)
            trace.collector.finish(trace, reason: .dropped)
        }
        if failed {
            emitFirstError(rejection)
            native.retire(); callbacks.failure(.init(status: 102))
        }
    }
    private func complete(command trace: PrimaryMediaTrace?, dispatchedAt: Double?, as completion: CommandCompletion) {
        guard let trace else { return }
        if let dispatchedAt {
            trace.collector.duration(.dispatchToProcessed,
                                     seconds: max(0, ProcessInfo.processInfo.systemUptime - dispatchedAt))
        }
        if completion != .processed { trace.collector.cancelInputProbe(trace: trace) }
        trace.collector.leave(.control, trace: trace)
        switch completion {
        case .processed: trace.collector.finish(trace, reason: .controlProcessed)
        case .failed: trace.collector.finish(trace, reason: .controlFailed)
        case .dropped: trace.collector.finish(trace, reason: .dropped)
        }
    }
    private func drop(_ commands: ArraySlice<Command>) {
        for command in commands { complete(command: command.trace, dispatchedAt: nil, as: .dropped) }
    }
    func retire() {
        native.retire()
        condition.withLock { stopping = true; condition.signal() }
    }
    /// Called by the exact native attempt's failure callback before Session
    /// closes the route. Preserve failure in the joint outcome, not just UI.
    func nativeFailed(_ reason: NativeMediaFailure) {
        let status: UInt32
        switch reason {
        case .capacity: status = 102
        case .invalidSize: status = 101
        case .codec: status = 113
        case .nativeCleanup, .cleanupIncomplete: status = 111
        }
        let record = condition.withLock {
            let record = claimFirstErrorLocked(status, operation: 2)
            if initialFailure == 0 { initialFailure = status }
            stopping = true; condition.signal()
            return record
        }
        emitFirstError(record)
        native.retire()
    }
    func waitForCleanup() async -> ScrcpyTransportSettlement {
        await withCheckedContinuation { continuation in
            let completed: ScrcpyTransportSettlement? = condition.withLock {
                if let outcome { return outcome }
                waiters.append(continuation); return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }
    private func publish(_ result: ScrcpyTransportSettlement) {
        let pending = condition.withLock {
            guard outcome == nil else { return [CheckedContinuation<ScrcpyTransportSettlement, Never>]() }
            outcome = result; let result = waiters; waiters.removeAll(); return result
        }
        pending.forEach { $0.resume(returning: result) }
    }
    private func run() {
        var bridge: QuicBackendBridge?
        var failure: UInt32 = 0
        var heldDevice: QuicDeviceDelivery?
        var heldDeviceBytes = 0
        var pendingDevices: [PendingDevice] = []
        var pendingDeviceBytes = 0
        var operation: UInt32 = 3
        do {
            let backend = try QuicBackendBridge(launch); bridge = backend
            operation = 4
            let before = QuicReceiptClock.now, local = try backend.now(), after = QuicReceiptClock.now
            let clock = try QuicReceiptClock(hostBefore: before, backend: local, hostAfter: after)
            var encoder = QuicControlEncoder(generation: launch.generation)
            var videoContinuity = QuicVideoSequenceContinuity()
            var ready = false
            var previousDiagnosticTurn: Double?
            while !condition.withLock({ stopping }) {
                // Instrument only the established owner, not bootstrap. The
                // same opt-in collector follows this immutable generation.
                let diagnosticStart = diagnostics != nil && ready ? ProcessInfo.processInfo.systemUptime : nil
                var diagnosticWait: Double?
                if let start = diagnosticStart {
                    if let previous = previousDiagnosticTurn {
                        diagnostics?.ownerSpan(.ownerCadence, start: previous, end: start)
                    }
                    previousDiagnosticTurn = start
                }
                defer {
                    if let start = diagnosticStart {
                        let end = ProcessInfo.processInfo.systemUptime
                        diagnostics?.ownerSpan(.ownerWork, start: start, end: diagnosticWait ?? end)
                        if let wait = diagnosticWait {
                            diagnostics?.ownerSpan(.ownerWait, start: wait, end: end)
                        }
                    }
                }
                operation = 5
#if GB_QUIC_BACKEND_QA
                beforeOwnerPoll?(backend.owner)
#endif
                let poll = try backend.poll()
#if GB_QUIC_BACKEND_QA
                for _ in 0..<64 {
                    var values = [UInt64](repeating: 0, count: 8)
                    let status = qaControlObservation(backend.owner, &values)
                    if status == 1 { break }
                    try QuicBackendBridge.check(status)
                    stockObservation?(values)
                }
#endif
                if poll.terminal != 0 { throw QuicBackendError(status: poll.terminal) }
                if poll.phase == 3, !ready { ready = true; callbacks.ready() }
                do {
                    let pending: [Command] = condition.withLock {
                        guard ready else { return [] }
                        let batch = commands; commands.removeAll(keepingCapacity: true); return batch
                    }
                    for (index, command) in pending.enumerated() {
                        operation = 12
                        beforeCommandService?()
                        if condition.withLock({ stopping }) {
                            drop(pending[index...])
                            break
                        }
                        let dispatchedAt = ProcessInfo.processInfo.systemUptime
                        if let trace = command.trace {
                            if let receivedAt = trace.collector.stageTime(.received, trace: trace) {
                                trace.collector.duration(.inputToDispatch, seconds: max(0, dispatchedAt - receivedAt))
                            }
                            trace.collector.inputDispatched(trace: trace, at: dispatchedAt)
                        }
                        do {
                            // A release seals the gesture at the latest move
                            // sequence encoded into its wrapper. Give the
                            // already-coalesced move one owner-thread service
                            // turn before admitting UP/CANCEL; otherwise a
                            // same-batch release legitimately removes that
                            // move from the source queue before it ever reaches
                            // the independent high-priority input connection.
                            if command.bytes.count >= 2,
                               command.bytes[0] == 2,
                               command.bytes[1] == 1 || command.bytes[1] == 3 {
                                let releasePoll = try backend.poll()
                                if releasePoll.terminal != 0 {
                                    throw QuicBackendError(status: releasePoll.terminal)
                                }
                            }
                            let encoded = try encoder.encode(command.bytes)
                            operation = 6
                            _ = try backend.submit(encoded.bytes, kind: encoded.kind, received: clock.map(command.received))
                            complete(command: command.trace, dispatchedAt: dispatchedAt, as: .processed)
                        } catch {
                            complete(command: command.trace, dispatchedAt: dispatchedAt, as: .failed)
                            if index + 1 < pending.count { drop(pending[(index + 1)...]) }
                            throw error
                        }
                    }
                }
                if let held = heldDevice {
                    operation = 7
                    let state = held.status()
                    if state.failure != 0 { throw QuicBackendError(status: state.failure) }
                    if state.completed { heldDevice = nil; heldDeviceBytes = 0 }
                }
                // Every committed reverse event keeps its original independent
                // expiry while awaiting the one ordered MainActor callback.
                // Continue extracting media even when that actor is held.
                for pending in pendingDevices {
                    operation = 7
                    let status = pending.delivery.status()
                    if status.failure != 0 { throw QuicBackendError(status: status.failure) }
                }
                do {
                    for _ in 0..<32 {
                        operation = 8
                        guard let event = try backend.next() else { break }
                        switch event.kind {
                        case 2:
                            operation = 9
                            // This collector belongs to this launch, captured
                            // before any actor hop. C's first exported event is
                            // the observable native receipt, not UDP arrival.
                            let trace = diagnostics?.received(stream: event.track == 1 ? .video : .audio,
                                bytes: event.bytes.length, pts: event.record_kind == 5 ? event.pts : nil,
                                epoch: event.epoch, isPacket: event.record_kind == 4 || event.record_kind == 5,
                                sourceSequence: event.sequence)
                            let admitted: QuicBackendBridge.AdmittedMedia
                            do {
                                switch try backend.admitMedia(event, into: native, trace: trace) {
                                case let .admitted(value): admitted = value
                                case .declined:
                                    if let trace { trace.collector.finish(trace, reason: .dropped) }
                                    continue
                                }
                            }
                            catch { if let trace { trace.collector.finish(trace, reason: .dropped) }; throw error }
                            if admitted.identity.track == 1 {
                                encoder.epoch = admitted.identity.epoch
                                if event.record_kind == 5 {
                                    if videoContinuity.observe(admitted.identity.sequence) {
                                        native.video.markInputGap()
                                    }
                                } else {
                                    videoContinuity.reset()
                                }
                                native.video.consume(admitted.work.event, epoch: admitted.identity.epoch, diagnosticTrace: trace, nativeWork: admitted.work)
                            } else {
                                native.audio.consume(admitted.work.event, epoch: admitted.identity.epoch, diagnosticTrace: trace, nativeWork: admitted.work)
                            }
                            callbacks.media(admitted)
                        case 3:
                            operation = 10
                            var transferred = false
                            defer { if !transferred { try? backend.release(event) } }
                            guard let pointer = event.bytes.data, event.bytes.length <= 262144 else { throw QuicBackendError(status: 101) }
                            guard pendingDevices.count + (heldDevice == nil ? 0 : 1) < 64,
                                  event.bytes.length <= 524288 - pendingDeviceBytes - heldDeviceBytes else {
                                reportFirstError(102, operation: 10, bridge: backend, used: pendingDevices.count + (heldDevice == nil ? 0 : 1), limit: 64,
                                    requested: event.bytes.length, bytes: pendingDeviceBytes + heldDeviceBytes, byteLimit: 524288)
                                throw QuicBackendError(status: 102)
                            }
                            let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: event.bytes.length, deallocator: .none)
                            var decoder = ScrcpyDeviceMessageDecoder()
                            let messages = try decoder.append(bytes)
                            guard messages.count == 1 else { throw QuicBackendError(status: 101) }
                            let cutoffs = try backend.deviceCutoffs(event)
                            let reverse = try clock.cutoff(cutoffs.reverse_ns)
                            let clipboard = cutoffs.clipboard_ns == 0 ? 0 : try clock.cutoff(cutoffs.clipboard_ns)
                            let ownerID = backend.owner, handle = event.handle
                            condition.withLock { deviceReferences += 1 }
                            let retention = NativeMediaLease { [self] in
                                _ = gb_backend_event_release(ownerID, handle)
                                condition.withLock { deviceReferences -= 1; condition.signal() }
                            }
                            transferred = true
                            let delivery = QuicDeviceDelivery(reverse: reverse, clipboard: clipboard,
                                attempt: native.attempt, retention: retention)
                            try QuicBackendBridge.check(gb_backend_device_commit(ownerID, handle))
                            pendingDevices.append(.init(message: messages[0], delivery: delivery, bytes: event.bytes.length))
                            pendingDeviceBytes += event.bytes.length
                        case 7:
                            operation = 11
                            defer { try? backend.release(event) }
                            guard event.generation == launch.generation, event.target_token == launch.targetToken,
                                  event.scid == launch.scid, event.capture_kind == 1,
                                  event.enabled == launch.enabled else { throw QuicBackendError(status: 101) }
                            switch event.code {
                            case 1:
                                let fields = [event.track, event.epoch, event.config, event.display_id]
                                guard fields.allSatisfy({ $0 > 0 && $0 <= Int32.max }) else { throw QuicBackendError(status: 101) }
                                callbacks.display(.announcement(.init(width: Int32(event.track), height: Int32(event.epoch),
                                    density: Int32(event.config), displayID: Int32(event.display_id))))
                            case 2: callbacks.display(.conflict)
                            case 3: callbacks.display(.ended)
                            default: throw QuicBackendError(status: 101)
                            }
                        default:
                            try backend.release(event)
                        }
                    }
                }
                if heldDevice == nil, !pendingDevices.isEmpty {
                    let next = pendingDevices.removeFirst(); pendingDeviceBytes -= next.bytes
                    heldDevice = next.delivery; heldDeviceBytes = next.bytes
                    callbacks.device(next.message, next.delivery)
                }
                for status in native.attempt.takeMediaStatus() { try backend.nativeMediaStatus(status) }
                try serviceBoundedMediaRetry(backend)
                try publishHealth(backend)
                if diagnosticStart != nil { diagnosticWait = ProcessInfo.processInfo.systemUptime }
                condition.lock()
                if !stopping, commands.isEmpty { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.001)) }
                condition.unlock()
            }
            failure = condition.withLock { initialFailure }
        } catch {
            failure = (error as? QuicBackendError)?.status ?? 101
            reportFirstError(failure, operation: operation, bridge: bridge)
            callbacks.failure(.init(status: failure))
        }
        let abandoned = condition.withLock {
            let abandoned = commands
            commands.removeAll(keepingCapacity: false)
            return abandoned
        }
        drop(abandoned[...])
        beforeCleanup?()
        if let bridge, !bridge.consumed { try? publishHealth(bridge,final:true) }
        let retirement = native.retire()
        Task.detached { [self] in
            let result = await retirement.wait()
            condition.withLock { nativeSettlement = result; condition.signal() }
        }
        if launch.captureKind == 1 { callbacks.display(.ended) }
        condition.withLock { stopping = true }
        discardQueuedCommands()
        try? bridge?.retire()
        heldDevice?.cancel(); heldDevice = nil
        pendingDevices.forEach { $0.delivery.cancel() }; pendingDevices.removeAll()
        do {
            // Keep exact ownership after failed timing. No successor may use
            // the slot until physical backend AND native references settle.
            while true {
                do {
                    if let bridge, !bridge.consumed { _ = try bridge.poll(); _ = try bridge.destroyIfSettled() }
                } catch {
                    if failure == 0 { failure = (error as? QuicBackendError)?.status ?? 111 }
                }
                let nativeResult = condition.withLock { nativeSettlement }
                let cutoffExpired = retirement.originalCutoffExpired
                if bridge?.cleanupFailed == true || nativeResult?.failure != nil || cutoffExpired, failure == 0 { failure = 111 }
                if bridge == nil || bridge?.consumed == true, nativeResult != nil, native.attempt.snapshot.actuallySettled,
                   condition.withLock({ deviceReferences == 0 }) { break }
                if nativeResult?.failure != nil || bridge?.cleanupFailed == true || cutoffExpired {
                    publish(.init(physicallySettled: false, failed: true, status: failure == 0 ? 111 : failure))
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        condition.withLock { physical = true }
        publish(.init(physicallySettled: true, failed: failure != 0, status: failure))
    }
    private func discardQueuedCommands() {
        let discarded = condition.withLock { let batch = commands; commands.removeAll(); return batch }
        // Final Command release returns credit outside the condition lock.
        withExtendedLifetime(discarded) {}
    }
}
#endif
