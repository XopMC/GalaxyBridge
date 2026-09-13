import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import GalaxyBridgeCore
import Testing
@testable import GalaxyBridgeMac

@Suite(.serialized)
struct QuicMediaConsumerFixture {
    init() { QuicNativeWatchdog.arm() }
    @Test
    func privatePipeHeaderRejectsUnknownKindAndIrrelevantScalarBeforeAllocation() throws {
        var ready=Data(repeating: 0,count: 40);ready[0]=65
        try QuicFixtureChild.validateHeader(ready)
        var unknown=ready;unknown[0]=0
        #expect(throws: (any Error).self) { try QuicFixtureChild.validateHeader(unknown) }
        var bad=ready;bad[8]=1
        #expect(throws: (any Error).self) { try QuicFixtureChild.validateHeader(bad) }
        var au=Data(repeating: 0,count: 40);au[0]=5;au[1]=1;au[3]=3;au[15]=1;au[19]=1;au[23]=1;au[31]=1
        #expect(throws: (any Error).self) { try QuicFixtureChild.validateHeader(au) }
        au[7]=1;try QuicFixtureChild.validateHeader(au)
        au[5]=64;au[7]=1
        #expect(throws: (any Error).self) { try QuicFixtureChild.validateHeader(au) }
    }
    @Test
    func privatePipeOutputBudgetCountsFinalSharedReferencesBeforeAllocation() throws {
        let budget = QuicPipeBudget()
        var held: [QuicPipeCharge] = []
        for _ in 0..<8 { held.append(try budget.acquire(kind: 5,track: 1,bytes: 1)) }
        var clone: QuicPipeCharge? = held[0]
        held.removeFirst()
        #expect(throws: (any Error).self) { _ = try budget.acquire(kind: 5,track: 1,bytes: 1) }
        withExtendedLifetime(clone) {};clone = nil
        held.append(try budget.acquire(kind: 5,track: 1,bytes: 1));held.removeAll()
        #expect(budget.usage == [0,0,0,0])
        for _ in 0..<4 { held.append(try budget.acquire(kind: 5,track: 1,bytes: 4*1024*1024)) }
        #expect(throws: (any Error).self) { _ = try budget.acquire(kind: 5,track: 1,bytes: 1) }
        held.removeAll()
        for track: UInt8 in [1,2] { for _ in 0..<2 { held.append(try budget.acquire(kind: 4,track: track,bytes: 65536)) } }
        #expect(throws: (any Error).self) { _ = try budget.acquire(kind: 4,track: 1,bytes: 1) }
        held.removeAll();#expect(budget.usage == [0,0,0,0])
    }
    @Test(.timeLimit(.minutes(1)))
    func realCodecForgedKeyAndTruncatedSecondVCLNeverReachNativeAdmission() throws {
        for hevc in [false,true] {
            let fixture=try QuicCodecFixtureFactory.video(hevc: hevc)
            let stock=QuicCodecFixtureFactory.stockVideo(fixture)
            var truncated=fixture.packets[0].bytes
            truncated.append(contentsOf: hevc ? [0,0,0,1,38,1] : [0,0,0,1,101])
            for (variant,bytes) in [fixture.packets[1].bytes,truncated].enumerated() {
                print("g1_codec_negative codec=\(hevc ? 2 : 1) variant=\(variant)")
                let child=try QuicFixtureChild();defer { child.cleanup() }
                for metadata in stock.prefix(3) {
                    try child.command(1,track: 1,body: metadata)
                    let event=try child.readEvent()
                    try child.command(2,body: QuicFixtureChild.token(event.token))
                    try child.command(3,body: QuicFixtureChild.token(event.token))
                }
                #expect(throws: (any Error).self) {
                    try child.command(1,track: 1,body: QuicCodecFixtureFactory.stockPacket(bytes,pts: 1_000_000,flags: 1 << 61))
                }
                // HEVC's declared header policy rejects a two-byte-only NAL
                // as Unsupported before the slice bit reader; neither is admitted.
                try child.expectFailure(hevc && variant==1 ? 6 : 7)
                #expect(child.nativeAdmissions==0)
            }
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func actualSyntheticCompressionProducesBothCodecFixtures() throws {
        for hevc in [false,true] {
            let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
            #expect(!fixture.configuration.isEmpty)
            #expect(fixture.packets.count == 5)
            let expected: [UInt64] = [1_000_000, 1_016_667, 1_033_334, 1_050_001, 1_066_668]
            #expect(fixture.packets.map(\.pts) == expected)
            #expect(fixture.packets.first?.key == true)
            #expect(fixture.packets.last?.key == true)
            #expect(fixture.packets[1...3].allSatisfy { !$0.key })
            #expect(fixture.packets[0].bytes.count > 960, "native selective-repair fixture must span multiple G1 fragments")
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func noImpairmentStockBaselineActuallyDecodesMarkersAndOriginalPTS() async throws {
        for hevc in [false, true] {
            let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
            let output = QuicNativeFrames()
            let queue = DispatchQueue(label: "quic.fixture.vt.baseline")
            let playout = DispatchQueue(label: "quic.fixture.vt.playout")
            let decoder = VideoToolboxDecoder(queue: queue, playoutQueue: playout,
                frameHandler: { output.add($0, $1, $2) }, failureHandler: { output.fail($0) })
            defer { decoder.invalidate(); queue.sync {}; playout.sync {}; withExtendedLifetime(decoder) {} }
            var parser = ScrcpyStreamDecoder(kind: .video, maxPayloadLength: 4 * 1024 * 1024)
            let records = QuicCodecFixtureFactory.stockVideo(fixture)
            for bytes in records {
                for event in try parser.append(bytes) { decoder.consume(event, epoch: 1) }
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while output.count < 5 && output.errorCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            #expect(output.errorCount == 0)
            let frames = output.values
            #expect(frames.count == fixture.packets.count)
            for (frame, packet) in zip(frames, fixture.packets) {
                #expect(CVPixelBufferGetWidth(frame.buffer) == 64)
                #expect(CVPixelBufferGetHeight(frame.buffer) == 64)
                #expect(frame.epoch == 1)
                #expect(CMTimeCompare(frame.pts, CMTime(value: Int64(packet.pts), timescale: 1_000_000)) == 0)
                #expect(abs(try frame.luma() - Int(packet.marker)) <= 3)
            }
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func decoderInputGapRecreatesReferencesAndRecoversOnNextIDR() async throws {
        for hevc in [false, true] {
            let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
            let output = QuicNativeFrames()
            let queue = DispatchQueue(label: "quic.fixture.vt.input-gap")
            let playout = DispatchQueue(label: "quic.fixture.vt.input-gap-playout")
            let decoder = VideoToolboxDecoder(queue: queue, playoutQueue: playout,
                frameHandler: { output.add($0, $1, $2) }, failureHandler: { output.fail($0) })
            defer { decoder.invalidate(); queue.sync {}; playout.sync {}; withExtendedLifetime(decoder) {} }

            decoder.consume(.codec(hevc ? .h265 : .h264), epoch: 1)
            decoder.consume(.videoSession(.init(width: 64, height: 64, clientResized: false)), epoch: 1)
            decoder.consume(.packet(.init(isConfiguration: true, isKeyFrame: false,
                presentationTimeUs: nil, payload: fixture.configuration)), epoch: 1)
            let first = fixture.packets[0]
            decoder.consume(.packet(.init(isConfiguration: false, isKeyFrame: first.key,
                presentationTimeUs: first.pts, payload: first.bytes)), epoch: 1)

            var deadline = ContinuousClock.now + .seconds(2)
            while output.count < 1 && output.errorCount == 0 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(output.count == 1 && output.errorCount == 0)

            decoder.markInputGap()
            let dependent = fixture.packets[1]
            decoder.consume(.packet(.init(isConfiguration: false, isKeyFrame: dependent.key,
                presentationTimeUs: dependent.pts, payload: dependent.bytes)), epoch: 1)
            let replacement = fixture.packets[4]
            decoder.consume(.packet(.init(isConfiguration: false, isKeyFrame: replacement.key,
                presentationTimeUs: replacement.pts, payload: replacement.bytes)), epoch: 1)

            deadline = ContinuousClock.now + .seconds(2)
            while output.count < 2 && output.errorCount == 0 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(output.errorCount == 0)
            let frames = output.values
            #expect(frames.count == 2)
            if frames.count == 2 {
                #expect(abs(try frames[0].luma() - Int(first.marker)) <= 3)
                #expect(abs(try frames[1].luma() - Int(replacement.marker)) <= 3)
                #expect(CMTimeCompare(frames[1].pts,
                    CMTime(value: Int64(replacement.pts), timescale: 1_000_000)) == 0)
            }
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func g1PrivateLoopbackPreservesRealVideoEvents() throws {
        for hevc in [false, true] {
            let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
            let child = try QuicFixtureChild()
            defer { child.cleanup() }
            for (index, bytes) in QuicCodecFixtureFactory.stockVideo(fixture).enumerated() {
                try child.command(1, track: 1, body: bytes)
                let event = try child.readEvent()
                let expectedKind: UInt8 = index == 0 ? 2 : index == 1 ? 3 : index == 2 ? 4 : 5
                #expect(event.kind == expectedKind)
                #expect(event.body == (index < 2 ? bytes : Data(bytes.dropFirst(12))))
                try child.command(2, body: QuicFixtureChild.token(event.token))
                try child.command(3, body: QuicFixtureChild.token(event.token))
            }
            try child.finish()
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func actualAACConsumeRecordsNonemptyConversionOnOriginalTrace() throws {
        let fixture = try QuicCodecFixtureFactory.audio()
        #expect(fixture.configuration == Data([0x11,0x90]))
        #expect(fixture.packets.count >= 5)
        let diagnostics = PrimaryMediaDiagnostics(generation: 1) { _ in }
        let failures = QuicNativeFrames()
        let queue = DispatchQueue(label: "quic.fixture.aac")
        let player = AACAudioPlayer(queue: queue, failureHandler: { failures.fail($0) })
        defer { player.stop(); queue.sync {}; withExtendedLifetime(player) {} }
        player.consume(.codec(.aac), epoch: 1)
        player.consume(.packet(ScrcpyPacket(isConfiguration: true, isKeyFrame: false, presentationTimeUs: nil, payload: fixture.configuration)), epoch: 1)
        for packet in fixture.packets {
            let trace = diagnostics.received(stream: .audio, bytes: packet.bytes.count, pts: packet.pts, epoch: 1)
            player.consume(.packet(ScrcpyPacket(isConfiguration: false, isKeyFrame: false, presentationTimeUs: packet.pts, payload: packet.bytes)), epoch: 1, diagnosticTrace: trace)
        }
        queue.sync {}
        #expect(failures.errorCount == 0)
        #expect(diagnostics.snapshot(now: ProcessInfo.processInfo.systemUptime).clockTracks[0] > 0, "Only actual nonempty AVAudioConverter output reaches the live audio clock counter")
    }
    @Test(.timeLimit(.minutes(1)))
    func g1ReturnedVideoLeasesActuallyDecodeAndFinalizeReadableMOV() async throws {
        for hevc in [false,true] { for mode in ["none","drop-once","whole-once"] {
            print("g1_native_case codec=\(hevc ? "hevc" : "h264") mode=\(mode)")
            let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
            let child = try QuicFixtureChild(mode: mode); defer { child.cleanup() }
            let output = QuicNativeFrames()
            let queue = DispatchQueue(label: "quic.fixture.g1.vt")
            let playout = DispatchQueue(label: "quic.fixture.g1.playout")
            let recorderQueue = DispatchQueue(label: "quic.fixture.g1.recorder")
            let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GB_QUIC_MEDIA_ARTIFACTS"]), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(hevc ? "hevc" : "h264")-\(mode)-\(UUID().uuidString).mov")
            let recorder = try ScreenRecorder(outputURL: url, width: 64, height: 64, workQueue: recorderQueue)
            let decoder = VideoToolboxDecoder(queue: queue, playoutQueue: playout,
                frameHandler: { buffer, pts, epoch in output.add(buffer, pts, epoch); recorder.append(buffer, presentationTime: pts) }, failureHandler: { output.fail($0) })
            defer { decoder.invalidate(); queue.sync {}; playout.sync {}; withExtendedLifetime(decoder) {} }
            var receivedFrames = 0
            for bytes in QuicCodecFixtureFactory.stockVideo(fixture) {
                try child.command(1, track: 1, body: bytes)
                let event = try child.readEvent()
                print("g1_native_boundary kind=\(event.kind) track=\(event.track) flags=\(event.flags) sequence=\(event.sequence) bytes=\(event.body.count)")
                try child.handoffVideo(event) {
                    decoder.consume(try event.stockEvent(), epoch: event.epoch == 0 ? nil : event.epoch)
                    queue.sync {}
                }
                if event.kind == 5 {
                    receivedFrames += 1
                    let deadline = ContinuousClock.now + .seconds(1)
                    while output.count < receivedFrames && output.errorCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
                    #expect(output.count == receivedFrames)
                }
                try child.command(3, body: QuicFixtureChild.token(event.token))
            }
            try child.finish()
            #expect(output.errorCount == 0)
            let frames = output.values
            #expect(frames.count == 5)
            for (frame, packet) in zip(frames, fixture.packets) {
                #expect(frame.epoch == 1)
                #expect(CVPixelBufferGetWidth(frame.buffer) == 64 && CVPixelBufferGetHeight(frame.buffer) == 64)
                #expect(abs(try frame.luma() - Int(packet.marker)) <= 3)
                #expect(CMTimeCompare(frame.pts, CMTime(value: Int64(packet.pts), timescale: 1_000_000)) == 0)
            }
            recorderQueue.sync {}
            let completed: Result<URL,Error> = await withCheckedContinuation { continuation in recorder.finish { continuation.resume(returning: $0) } }
            _ = try completed.get(); withExtendedLifetime(recorder) {}
            let movie = try await quicReadMovie(url)
            #expect(movie.count == 5)
            for (index, frame) in movie.enumerated() {
                #expect(CVPixelBufferGetWidth(frame.buffer) == 64 && CVPixelBufferGetHeight(frame.buffer) == 64)
                #expect(abs(try frame.luma() - Int(fixture.packets[index].marker)) <= 3)
                let expected = CMTime(value: Int64(fixture.packets[index].pts - fixture.packets[0].pts), timescale: 1_000_000)
                #expect(abs(CMTimeGetSeconds(CMTimeSubtract(frame.pts, expected))) < 0.00001)
            }
        } }
    }
    @Test(.timeLimit(.minutes(1)))
    func fix1HeldExpiredRealAUDoesNotEnterRepairedVideoHandoff() async throws {
        for hevc in [false,true] {
            let fixture=try QuicCodecFixtureFactory.video(hevc: hevc)
            let child=try QuicFixtureChild();defer { child.cleanup() }
            let frames=QuicNativeFrames()
            let queue=DispatchQueue(label: "quic.fixture.expired.vt")
            let playout=DispatchQueue(label: "quic.fixture.expired.playout")
            let decoder=VideoToolboxDecoder(queue: queue,playoutQueue: playout,
                frameHandler: { frames.add($0,$1,$2) },failureHandler: { frames.fail($0) })
            defer { decoder.invalidate();queue.sync {};playout.sync {};withExtendedLifetime(decoder) {} }
            let stock=QuicCodecFixtureFactory.stockVideo(fixture)
            for bytes in stock.prefix(3) {
                try child.command(1,track: 1,body: bytes);let event=try child.readEvent()
                try child.handoffVideo(event) { decoder.consume(try event.stockEvent(),epoch: event.epoch==0 ? nil : event.epoch);queue.sync {} }
                try child.command(3,body: QuicFixtureChild.token(event.token))
            }
            try child.command(1,track: 1,body: stock[3]);let au=try child.readEvent()
            #expect(au.kind==5 && au.body.count>960)
            let admitted=child.nativeAdmissions
            try await Task.sleep(for: .milliseconds(520)) // first IDR owns the bounded 500 ms cold-start deadline
            var closureCalls=0
            #expect(throws: (any Error).self) {
                try child.handoffVideo(au) {
                    closureCalls += 1
                    decoder.consume(try au.stockEvent(),epoch: au.epoch);queue.sync {}
                }
            }
            #expect(closureCalls==0)
            #expect(child.nativeAdmissions==admitted)
            withExtendedLifetime(au) {}
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func actualVideoHoleSuppressesDescendantsAndRecoversOnNextIDR() async throws {
        for hevc in [false,true] {
            let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
            let child = try QuicFixtureChild(mode: "hole"); defer { child.cleanup() }
            let frames = QuicNativeFrames()
            let queue = DispatchQueue(label: "quic.fixture.hole.vt")
            let playout = DispatchQueue(label: "quic.fixture.hole.playout")
            let work = DispatchQueue(label: "quic.fixture.hole.recorder")
            let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GB_QUIC_MEDIA_ARTIFACTS"]), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(hevc ? "hevc" : "h264")-hole-recovery-\(UUID().uuidString).mov")
            let recorder = try ScreenRecorder(outputURL: url, width: 64, height: 64, workQueue: work)
            let decoder = VideoToolboxDecoder(queue: queue, playoutQueue: playout,
                frameHandler: { buffer, pts, epoch in frames.add(buffer,pts,epoch); recorder.append(buffer,presentationTime: pts) }, failureHandler: { frames.fail($0) })
            defer { decoder.invalidate(); queue.sync {}; playout.sync {}; withExtendedLifetime(decoder) {} }
            let stock = QuicCodecFixtureFactory.stockVideo(fixture)
            for bytes in stock.prefix(4) {
                try child.command(1,track: 1,body: bytes);let event = try child.readEvent()
                try child.admit(event) { decoder.consume(try event.stockEvent(),epoch: event.epoch == 0 ? nil : event.epoch);queue.sync {} }
                if event.kind == 5 {
                    let until = ContinuousClock.now + .seconds(1)
                    while frames.count < 1 && frames.errorCount == 0 && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(1)) }
                    #expect(frames.count == 1)
                }
                try child.command(3,body: QuicFixtureChild.token(event.token))
            }
            try child.command(1,track: 1,body: stock[4])
            let gap = try child.readEvent()
            #expect(gap.kind == 67 && gap.track == 1 && gap.sequence == 2)
            try child.command(1,track: 1,body: stock[5]);try child.command(1,track: 1,body: stock[6])
            #expect(frames.count == 1)
            // The media receiver deliberately stays alive while waiting for a
            // producer-requested IDR. Bounded retry/exhaustion belongs to the
            // backend recovery coordinator, not this datagram consumer.
            try child.command(1,track: 1,body: stock[7])
            let configuration = try child.readEvent()
            #expect(configuration.kind == 4 && configuration.body == fixture.configuration)
            try child.admit(configuration) { decoder.consume(try configuration.stockEvent(),epoch: configuration.epoch);queue.sync {} }
            try child.command(3,body: QuicFixtureChild.token(configuration.token))
            let idr = try child.readEvent();#expect(idr.kind == 5 && idr.sequence == 5)
            try child.admit(idr) { decoder.consume(try idr.stockEvent(),epoch: idr.epoch);queue.sync {} }
            let until = ContinuousClock.now + .seconds(1)
            while frames.count < 2 && frames.errorCount == 0 && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(1)) }
            #expect(frames.count == 2 && frames.errorCount == 0)
            try child.command(3,body: QuicFixtureChild.token(idr.token));try child.finish()
            for (frame,packet) in zip(frames.values,[fixture.packets[0],fixture.packets[4]]) {
                #expect(abs(try frame.luma()-Int(packet.marker)) <= 3)
                #expect(CMTimeCompare(frame.pts,CMTime(value: Int64(packet.pts),timescale: 1_000_000)) == 0)
            }
            work.sync {}
            let completed: Result<URL,Error> = await withCheckedContinuation { continuation in recorder.finish { continuation.resume(returning: $0) } }
            _ = try completed.get();withExtendedLifetime(recorder) {}
            let movie = try await quicReadMovie(url);#expect(movie.count == 2)
            if movie.count == 2 {
                #expect(abs(CMTimeGetSeconds(CMTimeSubtract(movie[1].pts,movie[0].pts))-0.066668) < 0.00001)
                #expect(abs(try movie[0].luma()-40) <= 3)
                #expect(abs(try movie[1].luma()-160) <= 3)
            }
        }
    }
    @Test(.timeLimit(.minutes(1)))
    func g1AACConversionRejectsAnOldPreConsumeOwnerLease() throws {
        let fixture = try QuicCodecFixtureFactory.audio()
        let queue = DispatchQueue(label: "quic.fixture.aac.owner")
        let failures = QuicNativeFrames()
        let clock = MediaPlayoutClock()
        let player = AACAudioPlayer(playoutClock: clock, queue: queue, failureHandler: { failures.fail($0) })
        defer { player.stop(); queue.sync {}; withExtendedLifetime(player) {} }
        let old = try QuicFixtureChild(); defer { old.cleanup() }
        let metadata = [Data([0,97,97,99]), QuicCodecFixtureFactory.stockPacket(fixture.configuration, pts: 0, flags: 1 << 62)]
        for bytes in metadata {
            try old.command(1, track: 2, body: bytes); let event = try old.readEvent()
            try old.admit(event) { player.consume(try event.stockEvent(), epoch: 1); queue.sync {} }
            try old.command(3, body: QuicFixtureChild.token(event.token))
        }
        let first = fixture.packets[0]
        try old.command(1, track: 2, body: QuicCodecFixtureFactory.stockPacket(first.bytes, pts: first.pts, flags: 0))
        let held = try old.readEvent(); old.cleanup()
        let replacement = try QuicFixtureChild(); defer { replacement.cleanup() }
        let diagnostics = PrimaryMediaDiagnostics(generation: 2) { _ in }
        for bytes in metadata {
            try replacement.command(1, track: 2, body: bytes); let event = try replacement.readEvent()
            try replacement.admit(event) { player.consume(try event.stockEvent(), epoch: 1); queue.sync {} }
            try replacement.command(3, body: QuicFixtureChild.token(event.token))
        }
        for packet in fixture.packets {
            try replacement.command(1, track: 2, body: QuicCodecFixtureFactory.stockPacket(packet.bytes, pts: packet.pts, flags: 0))
            let event = try replacement.readEvent(); #expect(event.body == packet.bytes); #expect(event.pts == packet.pts)
            let trace = diagnostics.received(stream: .audio, bytes: event.body.count, pts: event.pts, epoch: event.epoch)
            try replacement.admit(event) { player.consume(try event.stockEvent(), epoch: event.epoch, diagnosticTrace: trace); queue.sync {} }
            try replacement.command(3, body: QuicFixtureChild.token(event.token))
        }
        let before = replacement.nativeAdmissions
        var rejected = false
        do { try replacement.admit(held) { player.consume(try held.stockEvent(), epoch: held.epoch); queue.sync {} } } catch { rejected = true }
        #expect(rejected); #expect(replacement.nativeAdmissions == before)
        let snapshot = diagnostics.snapshot(now: ProcessInfo.processInfo.systemUptime)
        #expect(snapshot.clockTracks[0] > 0); #expect(snapshot.clockTracks[1] == 0)
        #expect(snapshot.clockActions.values.reduce(UInt64(0),+) == snapshot.clockTracks[0])
        #expect(failures.errorCount == 0)
        try replacement.finish()
    }
    @Test(.timeLimit(.minutes(1)))
    func delayedActualAACQueueKeepsOriginalTraceAcrossRealVideoClockAdvance() async throws {
        let audio = try QuicCodecFixtureFactory.audio(); let video = try QuicCodecFixtureFactory.video(hevc: false)
        let clock = MediaPlayoutClock(); let failures = QuicNativeFrames()
        let aacQueue = DispatchQueue(label: "quic.fixture.aac.delayed")
        let vtQueue = DispatchQueue(label: "quic.fixture.vt.advance")
        let playout = DispatchQueue(label: "quic.fixture.vt.advance.playout")
        let player = AACAudioPlayer(playoutClock: clock, queue: aacQueue, failureHandler: { failures.fail($0) })
        let decoder = VideoToolboxDecoder(playoutClock: clock, queue: vtQueue, playoutQueue: playout,
            frameHandler: { failures.add($0,$1,$2) }, failureHandler: { failures.fail($0) })
        var suspended = false
        defer {
            if suspended { aacQueue.resume() }
            player.stop(); aacQueue.sync {}; decoder.invalidate(); vtQueue.sync {}; playout.sync {}
            withExtendedLifetime(player) {}; withExtendedLifetime(decoder) {}
        }
        player.consume(.codec(.aac), epoch: 1)
        player.consume(.packet(ScrcpyPacket(isConfiguration: true, isKeyFrame: false, presentationTimeUs: nil, payload: audio.configuration)), epoch: 1)
        for packet in audio.packets.prefix(3) { player.consume(.packet(ScrcpyPacket(isConfiguration: false, isKeyFrame: false, presentationTimeUs: packet.pts, payload: packet.bytes)), epoch: 1) }
        aacQueue.sync {}
        let original = PrimaryMediaDiagnostics(generation: 101) { _ in }
        let videoCollector = PrimaryMediaDiagnostics(generation: 202) { _ in }
        let delayed = audio.packets[3]
        let trace = try #require(original.received(stream: .audio, bytes: delayed.bytes.count, pts: delayed.pts, epoch: 1))
        aacQueue.suspend(); suspended = true
        player.consume(.packet(ScrcpyPacket(isConfiguration: false, isKeyFrame: false, presentationTimeUs: delayed.pts, payload: delayed.bytes)), epoch: 1, diagnosticTrace: trace)
        decoder.consume(.codec(.h264), epoch: 2)
        decoder.consume(.videoSession(ScrcpyVideoSession(width: 64, height: 64, clientResized: true)), epoch: 2)
        decoder.consume(.packet(ScrcpyPacket(isConfiguration: true, isKeyFrame: false, presentationTimeUs: nil, payload: video.configuration)), epoch: 2)
        let packet = video.packets[0]
        let videoTrace = videoCollector.received(stream: .video, bytes: packet.bytes.count, pts: packet.pts, epoch: 2)
        decoder.consume(.packet(ScrcpyPacket(isConfiguration: false, isKeyFrame: true, presentationTimeUs: packet.pts, payload: packet.bytes)), epoch: 2, diagnosticTrace: videoTrace)
        let deadline = ContinuousClock.now + .seconds(1)
        while failures.count == 0 && failures.errorCount == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(failures.count == 1)
        #expect(original.snapshot(now: ProcessInfo.processInfo.systemUptime).clockTracks[0] == 0)
        aacQueue.resume(); suspended = false; aacQueue.sync {}
        let a = original.snapshot(now: ProcessInfo.processInfo.systemUptime)
        let v = videoCollector.snapshot(now: ProcessInfo.processInfo.systemUptime)
        #expect(a.clockTracks[0] > 0 && a.clockTracks[1] == 0)
        #expect(v.clockTracks[1] > 0 && v.clockTracks[0] == 0)
        #expect(a.clockActions.values.reduce(UInt64(0),+) == a.clockTracks[0])
        #expect(a.clockReasons[.epoch, default: 0] > 0)
        #expect(failures.errorCount == 0)
        // This observes existing late cross-track audio behavior. It is not AAC
        // overtaking on one suspended queue, nor cancellation of queued native work.
    }
}

// Bounds this task-owned native test process even if a vendor call prevents
// cooperative Swift Testing cancellation. Children independently retain their
// hard lifetime and observe these pipe closures. No other process is signalled.
private final class QuicNativeWatchdog: @unchecked Sendable {
    private static let shared = QuicNativeWatchdog()
    private let timer: DispatchSourceTimer
    private init() {
        timer=DispatchSource.makeTimerSource(queue: DispatchQueue(label: "quic.fixture.watchdog"))
        timer.schedule(deadline: .now() + .seconds(60))
        timer.setEventHandler { Darwin._exit(124) }
        timer.resume()
    }
    static func arm() { withExtendedLifetime(shared) {} }
}

private final class QuicPipeCharge {
    let budget: QuicPipeBudget;let media: Bool;let track: Int;let configuration: Bool;let bytes: Int
    init(_ budget: QuicPipeBudget,media: Bool,track: Int,configuration: Bool,bytes: Int) {
        self.budget=budget;self.media=media;self.track=track;self.configuration=configuration;self.bytes=bytes
    }
    deinit { budget.release(self) }
}
private final class QuicPipeBudget {
    private let lock = NSLock()
    private var counts = [0,0,0,0]
    private var configurations = [0,0,0]
    var usage: [Int] { lock.withLock { counts } }
    func acquire(kind: UInt8,track: UInt8,bytes: Int) throws -> QuicPipeCharge {
        try lock.withLock {
            guard [2,3,4,5,12].contains(kind),[1,2].contains(track),bytes>0 else { throw QuicFixtureError.malformed }
            let media=kind==5;let offset=media ? 0 : 2;let limit=media ? 16*1024*1024 : 256*1024
            let objectLimit=media && track==1 ? 4*1024*1024 : 65536
            guard bytes<=objectLimit,counts[offset]<(media ? 8 : 16),bytes<=limit-counts[offset+1],kind != 4 || configurations[Int(track)]<2 else { throw QuicFixtureError.capacity }
            counts[offset]+=1;counts[offset+1]+=bytes
            if kind==4 { configurations[Int(track)]+=1 }
            return QuicPipeCharge(self,media: media,track: Int(track),configuration: kind==4,bytes: bytes)
        }
    }
    fileprivate func release(_ charge: QuicPipeCharge) {
        lock.withLock {
            let offset=charge.media ? 0 : 2
            counts[offset]-=1;counts[offset+1]-=charge.bytes
            if charge.configuration { configurations[charge.track]-=1 }
        }
    }
}
private struct QuicPipeEvent { let owner: UUID; let kind: UInt8; let track: UInt8; let flags: UInt16; let token: UInt64; let epoch: UInt32; let sequence: UInt64; let pts: UInt64; let body: Data; let charge: QuicPipeCharge? }
private extension QuicPipeEvent {
    func stockEvent() throws -> ScrcpyStreamEvent {
        switch kind {
        case 2:
            guard body.count == 4, let codec = ScrcpyCodec(rawValue: body.reduce(0) { ($0 << 8) | UInt32($1) }) else { throw QuicFixtureError.malformed }
            return .codec(codec)
        case 3:
            guard body.count == 12 else { throw QuicFixtureError.malformed }
            let width = body[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; let height = body[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return .videoSession(ScrcpyVideoSession(width: width, height: height, clientResized: body[3] & 1 != 0))
        case 4,5:
            return .packet(ScrcpyPacket(isConfiguration: kind == 4, isKeyFrame: flags & 1 != 0, presentationTimeUs: kind == 5 ? pts : nil, payload: body))
        default: throw QuicFixtureError.malformed
        }
    }
}
private final class QuicFixtureChild {
    private let owner = UUID()
    private(set) var nativeAdmissions = 0
    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var output: Int32 = -1
    private var reaped = false
    private var status: Int32 = 0
    private let deadline = ContinuousClock.now + .seconds(8)
    private var deferred: [QuicPipeEvent] = []
    private let budget = QuicPipeBudget()
    init(mode: String = "none") throws {
        guard ["none","drop-once","whole-once","hole"].contains(mode),
              let path = ProcessInfo.processInfo.environment["GB_QUIC_MEDIA_FIXTURE"], path.hasSuffix("/gb-quic-media-fixture") else { throw QuicFixtureError.unsupported }
        var incoming: [Int32] = [-1,-1]; var outgoing: [Int32] = [-1,-1]
        defer { for fd in incoming+outgoing where fd>=0 { close(fd) } }
        guard pipe(&incoming) == 0, pipe(&outgoing) == 0 else { throw QuicFixtureError.malformed }
        for fd in incoming+outgoing {
            let flags=fcntl(fd,F_GETFD)
            guard flags>=0,fcntl(fd,F_SETFD,flags|FD_CLOEXEC)==0 else { throw QuicFixtureError.malformed }
        }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw QuicFixtureError.malformed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO)==0,
              posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO)==0 else { throw QuicFixtureError.malformed }
        for fd in incoming + outgoing { guard posix_spawn_file_actions_addclose(&actions, fd)==0 else { throw QuicFixtureError.malformed } }
        let strings: [UnsafeMutablePointer<CChar>?] = [path, "--stdio-fixture", mode].map { value in value.withCString { strdup($0) } }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({$0 != nil}) else { throw QuicFixtureError.capacity }
        var argv = strings + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let result = posix_spawn(&pid, path, &actions, nil, &argv, &environment)
        guard result == 0 else { throw QuicFixtureError.status(result) }
        close(incoming[0]);incoming[0] = -1;close(outgoing[1]);outgoing[1] = -1
        input = incoming[1];incoming[1] = -1;output = outgoing[0];outgoing[0] = -1
        do {
            let inputFlags=fcntl(input,F_GETFL);let outputFlags=fcntl(output,F_GETFL)
            guard inputFlags>=0,outputFlags>=0,fcntl(input,F_SETFL,inputFlags|O_NONBLOCK)==0,
                  fcntl(output,F_SETFL,outputFlags|O_NONBLOCK)==0,fcntl(input,F_SETNOSIGPIPE,1)==0 else { throw QuicFixtureError.malformed }
            let ready = try receive(); guard ready.kind == 65, ready.body.isEmpty else { throw QuicFixtureError.malformed }
        } catch { cleanup(); throw error }
    }
    deinit { cleanup() }
    func handoffVideo(_ event: QuicPipeEvent, consume: () throws -> Void) throws {
        try admit(event,consume: consume)
    }
    func admit(_ event: QuicPipeEvent, consume: () throws -> Void) throws {
        guard event.owner == owner, input >= 0, !reaped, nativeAdmissions < 128,
              [2,3,4,5].contains(event.kind) else { throw QuicFixtureError.malformed }
        // Last child-side software eligibility check, not cancellation of a native call.
        try command(5, body: Self.token(event.token))
        try consume(); nativeAdmissions += 1
        try command(2, body: Self.token(event.token))
    }
    static func token(_ token: UInt64) -> Data { var value = token.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    func command(_ kind: UInt8, track: UInt8 = 0, body: Data = Data()) throws {
        guard input >= 0, !reaped, body.count <= 32 * 1024 else { throw QuicFixtureError.malformed }
        var header = Data([kind, track, 0, 0]); var count = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &count) { header.append(contentsOf: $0) }; try write(header); try write(body)
        if kind == 4 { return }
        while true { let event = try receive(); if event.kind == 64 { return }; guard deferred.count < 16 else { throw QuicFixtureError.malformed }; deferred.append(event) }
    }
    func readEvent() throws -> QuicPipeEvent { if !deferred.isEmpty { return deferred.removeFirst() }; return try receive() }
    private func receive() throws -> QuicPipeEvent {
        let h = try read(40)
        try Self.validateHeader(h)
        func value(_ start: Int, _ count: Int) -> UInt64 { h[start..<start + count].reduce(0) { ($0 << 8) | UInt64($1) } }
        let length = Int(value(4,4)); guard length <= 4 * 1024 * 1024 else { throw QuicFixtureError.malformed }
        let charge = length > 0 ? try budget.acquire(kind: h[0],track: h[1],bytes: length) : nil
        return QuicPipeEvent(owner: owner, kind: h[0], track: h[1], flags: UInt16(value(2,2)), token: value(8,8), epoch: UInt32(value(16,4)), sequence: value(24,8), pts: value(32,8), body: try read(length),charge: charge)
    }
    static func validateHeader(_ h: Data) throws {
        guard h.count==40 else { throw QuicFixtureError.malformed }
        func value(_ at: Int,_ size: Int)->UInt64 { h[at..<at+size].reduce(0) { ($0<<8)|UInt64($1) } }
        let kind=h[0],track=h[1];let flags=value(2,2),length=value(4,4),token=value(8,8)
        let epoch=value(16,4),configuration=value(20,4),sequence=value(24,8),pts=value(32,8)
        if [64,65,66].contains(kind) {
            guard h.dropFirst().allSatisfy({$0==0}) else { throw QuicFixtureError.malformed };return
        }
        if kind==67 {
            guard length==0,token==0,configuration==0,pts==0 else { throw QuicFixtureError.malformed }
            switch track {
            case 1:guard [256,512].contains(flags),epoch>0,sequence>0 else { throw QuicFixtureError.malformed }
            case 2:guard flags==0,epoch==0,sequence>0 else { throw QuicFixtureError.malformed }
            case 3:guard (1...9).contains(flags),epoch<=7,(epoch==0 || flags==5) else { throw QuicFixtureError.malformed }
            default:throw QuicFixtureError.malformed
            };return
        }
        guard [2,3,4,5,12].contains(kind),[1,2].contains(track),token>0,length>0,
              length<=((kind==5 && track==1) ? 4*1024*1024 : 65536) else { throw QuicFixtureError.malformed }
        if kind==5 {
            guard flags & 2 == 2,flags & ~UInt64(3)==0,epoch>0,configuration>0,sequence>0 else { throw QuicFixtureError.malformed }
        } else {
            guard flags==0,pts==0 else { throw QuicFixtureError.malformed }
            switch kind {
            case 2,12:guard length==4,epoch==0,configuration==0,sequence==0 else { throw QuicFixtureError.malformed }
            case 3:guard length==12,track==1,epoch>0,configuration==0,sequence>0 else { throw QuicFixtureError.malformed }
            case 4:guard epoch>0,configuration>0,sequence>0 else { throw QuicFixtureError.malformed }
            default:throw QuicFixtureError.malformed
            }
        }
    }
    private func ready(_ fd: Int32, _ event: Int16) throws {
        guard ContinuousClock.now < deadline else { throw QuicFixtureError.timeout }
        var state = pollfd(fd: fd, events: event, revents: 0)
        let result = poll(&state, 1, 10)
        guard result >= 0 || errno == EINTR else { throw QuicFixtureError.malformed }
    }
    private func read(_ count: Int) throws -> Data {
        var data = Data(count: count); var used = 0
        while used < count {
            try ready(output, Int16(POLLIN))
            let n = data.withUnsafeMutableBytes { Darwin.read(output, $0.baseAddress!.advanced(by: used), count - used) }
            if n > 0 { used += n } else if n == 0 { throw QuicFixtureError.child(status) } else if errno != EAGAIN && errno != EINTR { throw QuicFixtureError.malformed }
        }; return data
    }
    private func write(_ bytes: Data) throws {
        var used = 0
        while used < bytes.count {
            try ready(input, Int16(POLLOUT))
            let n = bytes.withUnsafeBytes { Darwin.write(input, $0.baseAddress!.advanced(by: used), bytes.count - used) }
            if n > 0 { used += n } else if n == 0 || errno != EAGAIN && errno != EINTR { throw QuicFixtureError.malformed }
        }
    }
    func finish() throws {
        try command(4); let event = try readEvent(); guard event.kind == 66 else { throw QuicFixtureError.malformed }
        cleanup(); guard reaped, status == 0 else { throw QuicFixtureError.child(status) }
    }
    func expectFailure(_ code: UInt8,skippedVideo: UInt64? = nil) throws {
        let event = try readEvent()
        print("g1_terminal kind=\(event.kind) subtype=\(event.track) reason=\(event.flags) transport_reason=\(event.epoch)")
        guard event.kind == 67, event.track == 3, event.flags == UInt16(code), event.body.isEmpty else { throw QuicFixtureError.malformed }
        if let skippedVideo { guard event.sequence==skippedVideo else { throw QuicFixtureError.malformed } }
        cleanup();guard reaped,status == Int32(code) << 8 else { throw QuicFixtureError.child(status) }
    }
    func cleanup() {
        if input >= 0 { close(input); input = -1 }
        if pid > 0 && !reaped {
            let until = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < until {
                if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
                usleep(1_000)
            }
            if !reaped {
                // This exact child has not been reaped, so its PID cannot be reused.
                _ = kill(pid, SIGKILL)
                let killDeadline = ContinuousClock.now + .seconds(1)
                while ContinuousClock.now < killDeadline {
                    if waitpid(pid, &status, WNOHANG) == pid { reaped = true; break }
                    usleep(1_000)
                }
            }
        }
        if output >= 0 { close(output); output = -1 }
    }
}

private struct QuicNativeFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer; let pts: CMTime; let epoch: UInt32
    func luma() throws -> Int {
        try QuicCodecFixtureFactory.check(CVPixelBufferLockBaseAddress(buffer, .readOnly)); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { throw QuicFixtureError.malformed }
        return Int(base.assumingMemoryBound(to: UInt8.self)[32 * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + 32])
    }
}
private final class QuicNativeFrames: @unchecked Sendable {
    private let lock = NSLock(); private var frames: [QuicNativeFrame] = []; private var errors: [String] = []
    var count: Int { lock.withLock { frames.count } }
    var values: [QuicNativeFrame] { lock.withLock { frames } }
    var errorCount: Int { lock.withLock { errors.count } }
    func add(_ buffer: CVPixelBuffer, _ pts: CMTime, _ epoch: UInt32) { lock.withLock { if frames.count < 32 { frames.append(QuicNativeFrame(buffer: buffer, pts: pts, epoch: epoch)) } } }
    func fail(_ error: Error) { lock.withLock { if errors.count < 16 { errors.append(String(describing: error)) } } }
}

private func quicReadMovie(_ url: URL) async throws -> [QuicNativeFrame] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    try #require(reader.canAdd(output)); reader.add(output); try #require(reader.startReading())
    defer { reader.cancelReading() }
    var frames: [QuicNativeFrame] = []
    while let sample = output.copyNextSampleBuffer() {
        guard frames.count < 32, let buffer = CMSampleBufferGetImageBuffer(sample) else { throw QuicFixtureError.malformed }
        frames.append(QuicNativeFrame(buffer: buffer, pts: CMSampleBufferGetPresentationTimeStamp(sample), epoch: 1))
    }
    #expect(reader.status == .completed)
    return frames
}
