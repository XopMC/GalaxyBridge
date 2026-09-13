#if !GALAXYBRIDGE_APP_STORE && canImport(GalaxyBridgeQuicBackend)
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeQuicBackend

final class QuicFirstErrorEmitter: @unchecked Sendable {
    static let shared = QuicFirstErrorEmitter { try? FileHandle.standardError.write(contentsOf: $0) }
    private let permit = DispatchSemaphore(value: 1)
    private let queue = DispatchQueue(label: "gb.quic.first-error")
    private let sink: @Sendable (Data) -> Void
    init(sink: @escaping @Sendable (Data) -> Void) { self.sink = sink }
    @discardableResult func offer(_ bytes: Data) -> Bool {
        guard bytes.count <= 1024, permit.wait(timeout: .now()) == .success else { return false }
        // One record total, queued or in service. A blocked sink retains only
        // this bounded scalar record and emitter, never a transport/native owner.
        queue.async { [self] in sink(bytes); permit.signal() }
        return true
    }
#if GB_QUIC_BACKEND_QA
    func waitUntilIdle(timeout: DispatchTime) -> Bool {
        guard permit.wait(timeout: timeout) == .success else { return false }
        permit.signal(); return true
    }
#endif
}

struct QuicBackendError: Error, LocalizedError, Equatable, Sendable {
    let status: UInt32
    var errorDescription: String? { String(localized: "ERROR_SCREEN_CONNECTION") }
}
struct QuicMediaHealth: Equatable, Sendable {
    let track, state, reason, epoch, configuration, attempt, outputPressure: UInt32
    let revision, episode, nextDeadline, admittedSequence, declined, skipped, admittedInputDropped, outputDropped: UInt64
    init(_ v: GbMediaHealth) {
        track=v.track; state=v.state; reason=v.reason; epoch=v.epoch; configuration=v.config; attempt=v.attempt
        outputPressure=v.output_pressure; revision=v.revision; episode=v.episode; nextDeadline=v.next_deadline_ns
        admittedSequence=v.admitted_sequence
        declined=v.declined; skipped=v.skipped; admittedInputDropped=v.admitted_input_dropped; outputDropped=v.output_dropped
    }
}

/// Only the enclosing dedicated owner thread may access this object. C checks
/// actual thread identity as well; a serial DispatchQueue is not sufficient.
final class QuicBackendBridge {
    struct Launch: Sendable {
        let program: String
        let arguments: [String]
        let peerIP: String
        let sidecarSHA: [UInt8]
        let generation: UInt64
        let targetToken: UInt64
        let scid: UInt32
        let displayID: UInt32
        let captureKind: UInt8
        let enabled: UInt8
    }

    struct Identity: Equatable, Sendable {
        let owner, generation, targetToken, sequence: UInt64
        let scid, displayID, epoch, configuration, flags, track: UInt32
        let captureKind, enabled: UInt32
        let session: [UInt8]
        init(_ e: GbEvent) {
            owner = e.receiver_owner; generation = e.generation; targetToken = e.target_token
            sequence = e.sequence; scid = e.scid; displayID = e.display_id
            epoch = e.epoch; configuration = e.config; flags = e.flags; track = e.track
            captureKind = e.capture_kind; enabled = e.enabled
            var bytes = e.session
            session = withUnsafeBytes(of: &bytes) { Array($0) }
        }
        var native: NativeMediaSourceIdentity {
            .init(owner: owner, generation: generation, targetToken: targetToken, sequence: sequence,
                scid: scid, displayID: displayID, epoch: epoch, configuration: configuration, flags: flags,
                track: track, captureKind: captureKind, enabled: enabled, session: session)
        }
    }

    struct AdmittedMedia: Sendable {
        let identity: Identity
        let work: NativeMediaWork
    }
    enum MediaAdmission {
        case admitted(AdmittedMedia)
        case declined(UInt32)
    }

    private(set) var owner: UInt64
    private(set) var consumed = false
    private(set) var cleanupFailed = false
    // Last checked boundary on the one C owner thread; diagnostic only.
    private(set) var diagnosticOperation: UInt32 = 0
    func mediaHealth(_ track: UInt32) throws -> QuicMediaHealth {
        var value=GbMediaHealth(); value.h=Self.header(GbMediaHealth.self)
        try Self.check(gb_backend_media_health(owner,track,&value))
        return QuicMediaHealth(value)
    }
    func retryMedia(episode: UInt64) throws {
        try Self.check(gb_backend_media_retry(owner, episode))
    }
    func nativeMediaStatus(_ status: NativeMediaStatus) throws {
        let identity=status.identity
        var value=GbEvent(); value.h=Self.header(GbEvent.self)
        value.receiver_owner=identity.owner; value.generation=identity.generation; value.target_token=identity.targetToken
        value.scid=identity.scid; value.display_id=identity.displayID; value.epoch=identity.epoch; value.config=identity.configuration
        value.track=identity.track; value.capture_kind=identity.captureKind; value.enabled=identity.enabled
        withUnsafeMutableBytes(of:&value.session) { $0.copyBytes(from:identity.session) }
        try Self.check(gb_backend_media_native_status(owner,&value,status.inputLostThrough,status.inputDropped,status.outputSequence,status.outputPressure ? 1 : 0,status.outputDropped))
    }

    static func header<T>(_ type: T.Type) -> GbHeader {
        GbHeader(abi: 1, size: UInt32(MemoryLayout<T>.size), reserved: (0, 0))
    }

    init(_ launch: Launch) throws {
        guard launch.sidecarSHA.count == 32, launch.arguments.count <= 63 else {
            throw QuicBackendError(status: UInt32(GB_PROTOCOL))
        }
        var config = GbConfig()
        config.h = Self.header(GbConfig.self)
        config.generation = launch.generation; config.target_token = launch.targetToken
        config.scid = launch.scid; config.display_id = launch.displayID
        config.capture_kind = launch.captureKind; config.enabled = launch.enabled
        withUnsafeMutableBytes(of: &config.sidecar_sha) { $0.copyBytes(from: launch.sidecarSHA) }
        let strings = [launch.peerIP, launch.program] + launch.arguments
        let storage = strings.map { Array($0.utf8) }
        var created: UInt64 = 0
        // All pointers are scoped to the synchronous create. No argv secrets.
        func withSlices(_ index: Int, _ slices: [GbSlice]) throws {
            if index == storage.count {
                config.peer_ip = slices[0]; config.program = slices[1]
                try Array(slices.dropFirst(2)).withUnsafeBufferPointer { arguments in
                    config.args = arguments.baseAddress; config.argc = UInt32(arguments.count)
                    try Self.check(gb_backend_create(&config, &created))
                }
                return
            }
            try storage[index].withUnsafeBufferPointer { bytes in
                try withSlices(index + 1, slices + [GbSlice(data: bytes.baseAddress, length: bytes.count)])
            }
        }
        try withSlices(0, [])
        owner = created
    }

    static func check(_ status: UInt32) throws {
        guard status == GB_OK else { throw QuicBackendError(status: status) }
    }

    func now() throws -> UInt64 {
        diagnosticOperation = 1
        var result: UInt64 = 0
        try Self.check(gb_backend_now_ns(owner, &result))
        return result
    }

    func poll() throws -> GbPoll {
        diagnosticOperation = 2
        var result = GbPoll(); result.h = Self.header(GbPoll.self)
        let status = gb_backend_poll(owner, &result)
        cleanupFailed = cleanupFailed || result.cleanup_failed != 0
        guard status == GB_OK || status == GB_RETIRED || status == GB_CLEANUP else {
            throw QuicBackendError(status: status)
        }
        return result
    }

    func next() throws -> GbEvent? {
        diagnosticOperation = 3
        var result = GbEvent(); result.h = Self.header(GbEvent.self)
        let status = gb_backend_next_event(owner, &result)
        if status == GB_EMPTY { return nil }
        try Self.check(status)
        return result
    }

    func release(_ event: GbEvent) throws {
        if event.handle != 0 { try Self.check(gb_backend_event_release(owner, event.handle)) }
    }
    func deviceCutoffs(_ event: GbEvent) throws -> GbDeviceEligibility {
        diagnosticOperation = 4
        var result = GbDeviceEligibility(); result.h = Self.header(GbDeviceEligibility.self)
        try Self.check(gb_backend_device_eligibility(owner, event.handle, &result))
        return result
    }

    /// A borrowed C pointer is never sent to an actor/native queue. Reserve G1
    /// first (eight in-transfer AU slots, shared aggregate bytes), then the
    /// existing native budget/copy, then fresh atomic native commit+transfer
    /// into at most64 retained storage tickets. The C event owns original storage through that
    /// synchronous borrow; the input lease holds immutable identity, copied
    /// storage charge and configuration through the final owned work reference.
    func admit(_ event: GbEvent, into native: ScrcpyNativeMediaOwner,
               trace: PrimaryMediaTrace? = nil) throws -> AdmittedMedia {
        switch try admitMedia(event, into: native, trace: trace) {
        case let .admitted(value): return value
        case let .declined(status): throw QuicBackendError(status: status)
        }
    }
    func admitMedia(_ event: GbEvent, into native: ScrcpyNativeMediaOwner,
                    trace: PrimaryMediaTrace? = nil) throws -> MediaAdmission {
        // The C event is a synchronous borrow, not the native backing lease.
        // Releasing it after commit allows the existing source AU ACK to run.
        // Native admission synchronously creates independent owned bytes before
        // this event releases its original AU pointer. Only the actual copy and
        // exact configuration stay charged through the final native reference.
        defer { try? release(event) }
        var checked = GbEvent(); checked.h = Self.header(GbEvent.self)
        diagnosticOperation = 5
        let initial = gb_backend_media_admission_check(owner, event.handle, &checked)
        if initial == GB_MEDIA_EXPIRED { return .declined(initial) }
        try Self.check(initial)
        let identity = Identity(checked)
        guard identity == Identity(event) else { throw QuicBackendError(status: UInt32(GB_PROTOCOL)) }
        if checked.record_kind == 4, checked.track == 1,
           let reused = native.reuseInstalledConfiguration(try Self.streamEvent(checked), identity: identity.native, trace: trace) {
            // Byte comparison is synchronous while C's original borrow is live.
            // No copied buffer or native job is created for this exact installed
            // version. Its existing charged input survives via the new envelope.
            var final = GbEvent(); final.h = Self.header(GbEvent.self)
            diagnosticOperation = 9
            try Self.check(gb_backend_media_admission_check(owner, event.handle, &final))
            guard Identity(final) == identity else { throw QuicBackendError(status: UInt32(GB_PROTOCOL)) }
            diagnosticOperation = 10
            try Self.check(gb_backend_media_commit(owner, event.handle))
            return .admitted(AdmittedMedia(identity: identity, work: reused))
        }
        var copy: UInt64 = 0
        diagnosticOperation = 6
        let reserved = checked.record_kind == 5
            ? gb_backend_media_copy_reserve(owner, event.handle, &copy)
            : gb_backend_payload_copy_reserve(owner, event.handle, &copy)
        if reserved == GB_MEDIA_PRESSURE {
            try Self.check(gb_backend_media_decline(owner, event.handle, 1)); return .declined(reserved)
        }
        if reserved == GB_MEDIA_EXPIRED { return .declined(reserved) }
        try Self.check(reserved)
        let ownerID = owner, handle = event.handle, copyID = copy
        let retention = NativeMediaLease {
            _ = gb_backend_copy_release(ownerID, copyID)
            withExtendedLifetime(identity) {}
        }
        diagnosticOperation = 7
        let stream = try Self.streamEvent(checked)
        diagnosticOperation = 8
        let work: NativeMediaWork
        if checked.record_kind == 5 {
            switch native.admitMedia(stream, audio: checked.track == 2, trace: trace, externalRetention: retention, sourceIdentity: identity.native) {
            case let .granted(value): work = value
            case .pressure:
                try Self.check(gb_backend_media_decline(owner, handle, 1)); return .declined(UInt32(GB_MEDIA_PRESSURE))
            case .obsolete: throw QuicBackendError(status: UInt32(GB_RETIRED))
            case let .fatal(reason): native.attempt.fail(reason); throw QuicBackendError(status: UInt32(GB_PROTOCOL))
            }
        } else {
            guard let value = native.admit(stream, audio: checked.track == 2, trace: trace,
                                          externalRetention: retention, sourceIdentity: identity.native) else {
                throw QuicBackendError(status: UInt32(GB_CAPACITY))
            }
            work = value
        }
        // Copy/admission may have consumed time. Never trust the earlier view.
        var final = GbEvent(); final.h = Self.header(GbEvent.self)
        do {
            diagnosticOperation = 9
            let fresh = gb_backend_media_admission_check(owner, handle, &final)
            if fresh == GB_MEDIA_EXPIRED { return .declined(fresh) }
            try Self.check(fresh)
            diagnosticOperation = 10
            if checked.record_kind == 5 {
                // No asynchronous native consumer is invoked until this method
                // returns. Destination copy/job admission is already held.
                let committed = gb_backend_native_copy_commit(owner, handle, copyID)
                if committed == GB_MEDIA_PRESSURE {
                    try Self.check(gb_backend_media_decline(owner, handle, 1)); return .declined(committed)
                }
                if committed == GB_MEDIA_EXPIRED { return .declined(committed) }
                try Self.check(committed)
            } else {
                try Self.check(gb_backend_media_commit(owner, handle))
            }
        } catch {
            native.retire()
            throw error
        }
        return .admitted(AdmittedMedia(identity: identity, work: work))
    }

    private static func streamEvent(_ e: GbEvent) throws -> ScrcpyStreamEvent {
        guard let pointer = e.bytes.data, e.bytes.length > 0 else { throw QuicBackendError(status: UInt32(GB_PROTOCOL)) }
        let bytes = UnsafeBufferPointer(start: pointer, count: e.bytes.length)
        func word(_ at: Int) -> UInt32 { bytes[at..<at+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        switch e.record_kind {
        case 2:
            guard bytes.count == 4, let codec = ScrcpyCodec(rawValue: word(0)) else {
                throw QuicBackendError(status: UInt32(GB_CODEC))
            }
            return .codec(codec)
        case 3:
            guard bytes.count == 12 else { throw QuicBackendError(status: UInt32(GB_PROTOCOL)) }
            return .videoSession(.init(width: word(4), height: word(8), clientResized: word(0) & 1 != 0))
        case 4, 5:
            // No allocation/escaping borrow here; Attempt.admit immediately
            // creates its own explicitly charged immutable buffer.
            let borrowed = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: bytes.count, deallocator: .none)
            return .packet(.init(isConfiguration: e.record_kind == 4, isKeyFrame: e.flags & 1 != 0,
                presentationTimeUs: e.record_kind == 5 ? e.pts : nil, payload: borrowed))
        default: throw QuicBackendError(status: UInt32(GB_PROTOCOL))
        }
    }

    func submit(_ bytes: Data, kind: UInt32, received: UInt64) throws -> UInt64 {
        diagnosticOperation = 11
        var ticket: UInt64 = 0
        try bytes.withUnsafeBytes { buffer in
            var input = GbInput(); input.h = Self.header(GbInput.self)
            input.kind = kind; input.received_ns = received
            input.bytes = GbSlice(data: buffer.bindMemory(to: UInt8.self).baseAddress, length: buffer.count)
            try Self.check(gb_backend_submit(owner, &input, &ticket))
        }
        return ticket
    }

    func retire() throws { try Self.check(gb_backend_retire(owner)) }

    /// 118 retains ownership. Both 0 and 111 consume it, independently of a
    /// preceding poll snapshot. Foreign final releases remain legal afterwards.
    func destroyIfSettled() throws -> Bool {
        guard !consumed else { return true }
        let status = gb_backend_destroy(owner)
        if status == GB_CLEANUP_PENDING { return false }
        guard status == GB_OK || status == GB_CLEANUP else { throw QuicBackendError(status: status) }
        cleanupFailed = cleanupFailed || status == GB_CLEANUP
        consumed = true
        return true
    }
}
#endif
