import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import Testing
@testable import GalaxyBridgeMac

@Suite(.serialized)
struct NativeMediaRetirementTests {
    @Test @MainActor func crossInstanceRetirementCannotTreatDeadlineAsPhysicalCleanup() async throws {
        let session = try ScrcpySession(serial: "native-cleanup-deadline-no-adb",
            adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false)
        let owner = try session.beginNativeAttempt()
        var held: NativeMediaWork? = try #require(owner.admit(.codec(.h264)))
        session.stop()
        #expect(!session.cleanupPhysicallySettled)
        await session.stopAndWaitForCleanup()
        #expect(held != nil)
        #expect(session.nativeRetirementOutcome?.failure == .cleanupIncomplete)
        #expect(!session.cleanupPhysicallySettled, "a timed-out owner must still block a replacement instance")
        held = nil
        try await NativeFixtures.until { owner.attempt.snapshot.actuallySettled }
        #expect(session.cleanupPhysicallySettled, "real reference release makes a later retry safe")
    }

    private static func mediaIdentity(track:UInt32,sequence:UInt64,key:Bool=false)->NativeMediaSourceIdentity {
        .init(owner:1,generation:1,targetToken:9,sequence:sequence,scid:1,displayID:0,
              epoch:1,configuration:1,flags:key ? 3:2,track:track,captureKind:0,enabled:7,session:Array(repeating:1,count:32))
    }
    @Test func mediaPolicyNilIdentityKeepsStrictUSBPressure() async throws {
        for kind:NativeMediaAttempt.AllocationKind in [.decoded,.pcm] {
            let attempt=NativeMediaAttempt()
            var work=attempt.admit(.packet(.init(isConfiguration:false,isKeyFrame:true,presentationTimeUs:1,payload:Data([1]))),audio:kind == .pcm,binding:nil,trace:nil)
            var allocations=(0..<16).compactMap {_ in work?.reserveMedia(32_768,kind:kind)}
            #expect(allocations.count==16 && attempt.isAdmitted)
            #expect(work?.reserveMedia(32_768,kind:kind)==nil)
            #expect(!attempt.isAdmitted,"nil-identity USB work retains its original strict pressure retirement")
            work=nil;allocations.removeAll()
            #expect(await attempt.retire().wait().failure == .capacity)
        }
    }
    @Test func wirelessADBRealtimePressureDropsWithoutRetiringTheOwner() async throws {
        let inputAttempt = NativeMediaAttempt()
        var heldInputs = (0..<NativeMediaAttempt.maximumJobs).compactMap { _ in
            inputAttempt.admit(.codec(.h264), audio: false, binding: nil, trace: nil)
        }
        let packet = ScrcpyStreamEvent.packet(.init(
            isConfiguration: false,
            isKeyFrame: false,
            presentationTimeUs: 1,
            payload: Data([1])
        ))
        let pressuredInput = inputAttempt.admitMedia(
            packet,
            audio: true,
            binding: nil,
            trace: nil,
            pressurePolicy: .recoverableRealtime
        )
        if case .pressure = pressuredInput {} else {
            Issue.record("wireless realtime ingress must report bounded pressure")
        }
        #expect(inputAttempt.isAdmitted)
        heldInputs.removeAll()
        #expect(await inputAttempt.retire().wait().failure == nil)

        let outputAttempt = NativeMediaAttempt()
        var admitted: NativeMediaWork? = {
            switch outputAttempt.admitMedia(
                packet,
                audio: true,
                binding: nil,
                trace: nil,
                pressurePolicy: .recoverableRealtime
            ) {
            case let .granted(work): work
            default: nil
            }
        }()
        guard admitted != nil else {
            Issue.record("wireless realtime input should be admitted before output pressure")
            return
        }
        var outputs = (0..<NativeMediaAttempt.maximumOutputs).compactMap { _ in
            admitted?.reserveMedia(32_768, kind: .pcm)
        }
        #expect(outputs.count == NativeMediaAttempt.maximumOutputs)
        #expect(admitted?.reserveMedia(32_768, kind: .pcm) == nil)
        #expect(outputAttempt.isAdmitted, "wireless realtime output pressure must shed one packet, not restart scrcpy")
        outputs.removeAll()
        admitted = nil
        #expect(await outputAttempt.retire().wait().failure == nil)
    }
    @Test func audioIngressPressureKeepsVideoIDRCapacityAvailable() async throws {
        let attempt = NativeMediaAttempt()
        let audioIdentity = Self.mediaIdentity(track: 2, sequence: 1)
        var audio: [NativeMediaWork] = []
        for sequence in 0..<NativeMediaAttempt.maximumAudioJobs {
            let admission = attempt.admitMedia(
                .packet(.init(isConfiguration: false, isKeyFrame: false,
                              presentationTimeUs: UInt64(sequence), payload: Data([1]))),
                audio: true, binding: nil, trace: nil, sourceIdentity: audioIdentity
            )
            if case let .granted(work) = admission { audio.append(work) }
        }
        #expect(audio.count == NativeMediaAttempt.maximumAudioJobs)
        let pressuredAudio = attempt.admitMedia(
            .packet(.init(isConfiguration: false, isKeyFrame: false,
                          presentationTimeUs: 99, payload: Data([2]))),
            audio: true, binding: nil, trace: nil, sourceIdentity: audioIdentity
        )
        if case .pressure = pressuredAudio {} else {
            Issue.record("audio must yield its reserved ingress window")
        }
        var videoWork: NativeMediaWork?
        switch attempt.admitMedia(
            .packet(.init(isConfiguration: false, isKeyFrame: true,
                          presentationTimeUs: 100, payload: Data([3]))),
            audio: false, binding: nil, trace: nil,
            sourceIdentity: Self.mediaIdentity(track: 1, sequence: 1, key: true)
        ) {
        case let .granted(work): videoWork = work
        default:
            Issue.record("a complete video IDR must survive an AAC ingress burst")
        }
        #expect(videoWork != nil)
        #expect(attempt.isAdmitted)
        audio.removeAll()
        videoWork = nil
        #expect(await attempt.retire().wait().failure == nil)
    }
    @Test(arguments: [false, true]) func mediaPolicyInstalledConfigurationReusesActualOwnership(hevc: Bool) async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
        let events = try NativeFixtures.videoEvents(fixture)
        let queue = DispatchQueue(label: "media-policy.installed-config")
        let attempt = NativeMediaAttempt(), released = NativeFixtureCount()
        let decoder = VideoToolboxDecoder(queue: queue, nativeAttempt: attempt,
            ownedFrameHandler: { _ in }, frameHandler: { _, _, _ in },
            failureHandler: { Issue.record("actual configuration failed: \($0)") })
        let identity = Self.mediaIdentity(track: 1, sequence: 1)
        var original: NativeMediaWork? = try #require(attempt.admit(events[2], audio: false, binding: nil, trace: nil,
            externalRetention: NativeMediaLease { released.increment() }, sourceIdentity: identity))
        #expect(decoder.reuseInstalledConfiguration(events[2], identity: identity, binding: nil, trace: nil) == nil)
        let pending = DispatchSemaphore(value: 0)
        queue.async { pending.wait() }
        decoder.consume(events[0]); decoder.consume(events[1])
        decoder.consume(events[2], nativeWork: original)
        #expect(decoder.reuseInstalledConfiguration(events[2], identity: identity, binding: nil, trace: nil) == nil,
                "admitted and queued configuration is not actual installation")
        pending.signal()
        queue.sync {}
        original = nil
        #expect(released.value == 0)
        let installedJobs = attempt.snapshot.jobs
        var held = (installedJobs..<64).compactMap { _ in attempt.admit(events[0], audio: false, binding: nil, trace: nil) }
        #expect(attempt.snapshot.jobs == 64)
        var reused = try #require(decoder.reuseInstalledConfiguration(events[2], identity: Self.mediaIdentity(track: 1, sequence: 22), binding: nil, trace: nil)) as NativeMediaWork?
        #expect(reused?.sourceIdentity?.sequence == 22)
        #expect(attempt.snapshot.jobs == 64 && attempt.isAdmitted)
        decoder.consume(events[2], nativeWork: reused); queue.sync {}
        #expect(attempt.snapshot.jobs == 64 && attempt.isAdmitted)
        #expect(released.value == 0)
        if case let .packet(packet) = events[2] {
            var changed = packet.payload; changed.append(0)
            #expect(decoder.reuseInstalledConfiguration(NativeFixtures.configuration(changed), identity: identity, binding: nil, trace: nil) == nil)
        }
        func changedIdentity(owner: UInt64 = 1, epoch: UInt32 = 1, configuration: UInt32 = 1) -> NativeMediaSourceIdentity {
            .init(owner: owner, generation: 1, targetToken: 9, sequence: 1, scid: 1, displayID: 0,
                epoch: epoch, configuration: configuration, flags: 2, track: 1, captureKind: 0, enabled: 7, session: Array(repeating: 1, count: 32))
        }
        for changed in [changedIdentity(owner: 2), changedIdentity(epoch: 2), changedIdentity(configuration: 2)] {
            #expect(decoder.reuseInstalledConfiguration(events[2], identity: changed, binding: nil, trace: nil) == nil)
        }
        // Hold the actual queue, clear the receipt before its reset can run, then
        // put the old admitted envelope behind that reset. It must not reinstall.
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        decoder.invalidate()
        #expect(decoder.reuseInstalledConfiguration(events[2], identity: identity, binding: nil, trace: nil) == nil)
        decoder.consume(events[2], nativeWork: reused)
        gate.signal(); queue.sync {}
        #expect(decoder.reuseInstalledConfiguration(events[2], identity: identity, binding: nil, trace: nil) == nil)
        #expect(attempt.isAdmitted && released.value == 0)
        held.removeAll(); reused = nil
        // A genuine new publication must use ordinary admission and actual VT
        // installation. It cannot reuse the previous version's receipt.
        do {
            let next = changedIdentity(configuration: 2)
            let work = try #require(attempt.admit(events[2], audio: false, binding: nil, trace: nil, sourceIdentity: next))
            decoder.consume(events[2], nativeWork: work); queue.sync {}
            #expect(decoder.reuseInstalledConfiguration(events[2], identity: next, binding: nil, trace: nil) != nil)
            #expect(decoder.reuseInstalledConfiguration(events[2], identity: identity, binding: nil, trace: nil) == nil)
        }
        let retirement = try #require(decoder.beginNativeRetirement())
        #expect(await retirement.wait().succeeded)
        #expect(released.value == 1 && attempt.snapshot.jobs == 0)
        #expect(decoder.reuseInstalledConfiguration(events[2], identity: identity, binding: nil, trace: nil) == nil)
    }
    @Test(arguments: 0..<8)
    func playbackEvidenceRequiresPlayedBackAndRejectsStaleCompletion(scenario: Int) async throws {
        let fixture = try QuicCodecFixtureFactory.audio(sampleCount: 32_768)
        let queue = DispatchQueue(label: "playback-evidence.\(scenario)")
        let deliveries = NativeFixtureCompletions()
        defer { deliveries.open() }
        let attempt = NativeMediaAttempt()
        let received = NativeFixtureBox<[UUID]>([])
        let id = UUID(), replacement = UUID()
        let player = AACAudioPlayer(queue: queue, nativeAttempt: attempt,
            nativeCompletionDelivery: deliveries.receive,
            failureHandler: { error in Issue.record("unexpected AAC failure: \(error)") })
        if scenario == 7 { player.setPlaybackEnabled(false) }
        player.requestPlaybackEvidence(id: id) { id in received.update { $0.append(id) } }
        player.consume(.codec(.aac))
        player.consume(NativeFixtures.configuration(fixture.configuration))
        for packet in fixture.packets.prefix(6) {
            player.consume(NativeFixtures.packet(packet)); queue.sync {}
            try await Task.sleep(for: .milliseconds(20))
        }
        // These are real AVAudioPlayerNode callbacks held at the existing native
        // delivery boundary; no manually invented played-back event is injected.
        try await NativeFixtures.until { deliveries.count == 6 }
        #expect(received.value.isEmpty, "decoded/scheduled buffers cannot complete setup")
        switch scenario {
        case 1: player.setPlaybackEnabled(false); player.setPlaybackEnabled(true)
        case 2: player.consume(NativeFixtures.configuration(fixture.configuration))
        case 3: player.stop()
        case 4: player.cancelPlaybackEvidence()
        case 5:
            player.requestPlaybackEvidence(id: replacement) { id in received.update { $0.append(id) } }
        case 6: _ = player.beginNativeRetirement()
        case 7: player.setPlaybackEnabled(true)
        default: break
        }
        queue.sync {}
        deliveries.open()
        queue.sync {}
        if scenario == 0 {
            #expect(received.value == [id])
        } else {
            #expect(received.value.isEmpty, "late or muted completion is not playback proof")
        }
        if [0, 1, 2, 5, 7].contains(scenario) {
            for packet in fixture.packets.dropFirst(6).prefix(6) {
                player.consume(NativeFixtures.packet(packet)); queue.sync {}
                try await Task.sleep(for: .milliseconds(20))
            }
            if scenario != 0 {
                try await NativeFixtures.until { received.value.count == 1 }
                #expect(received.value == [scenario == 5 ? replacement : id])
            } else {
                try await Task.sleep(for: .milliseconds(200))
                #expect(received.value == [id], "one attempt receives exactly one proof")
            }
        }
        #expect(await player.beginNativeRetirement()?.wait().succeeded == true)
    }

    @Test func mutedPlaybackKeepsAACConversionAndNativeOwnership() async throws {
        let fixture = try QuicCodecFixtureFactory.audio(sampleCount: 16_384)
        let queue = DispatchQueue(label: "recording-only.playback")
        let node = AVAudioPlayerNode()
        let events = NativeFixtureBox<[NativeAudioOutputEvent]>([])
        let completions = NativeFixtureCompletions()
        defer { completions.open() }
        let attempt = NativeMediaAttempt()
        let player = AACAudioPlayer(queue: queue, playerNode: node, nativeAttempt: attempt,
            nativeOutputEvent: { event in events.update { $0.append(event) } },
            nativeCompletionDelivery: completions.receive,
            failureHandler: { error in Issue.record("unexpected muted AAC failure: \(error)") })
        player.setPlaybackEnabled(false)
        queue.sync { #expect(node.volume == 0) }
        player.setPlaybackEnabled(true)
        queue.sync { #expect(node.volume == 1) }
        player.setPlaybackEnabled(false)
        player.consume(.codec(.aac))
        player.consume(NativeFixtures.configuration(fixture.configuration))
        for packet in fixture.packets.prefix(6) {
            player.consume(NativeFixtures.packet(packet))
            queue.sync {}
        }
        queue.sync { #expect(node.volume == 0) }
        #expect(attempt.isAdmitted)
        #expect(events.value.contains { if case .converted = $0 { true } else { false } })
        #expect(events.value.contains { if case .scheduled = $0 { true } else { false } })
        #expect(!events.value.contains { if case .stopped = $0 { true } else { false } })
        #expect(attempt.snapshot.pcm > 0, "muting must not discard native PCM completion ownership")
        completions.open()
        #expect(await player.beginNativeRetirement()?.wait().succeeded == true)
    }

    @Test func mediaPolicyActualPCMPressureKeepsAttemptAndRealCompletions() async throws {
        let fixture=try QuicCodecFixtureFactory.audio(sampleCount:32_768)
        let queue=DispatchQueue(label:"media-policy.pcm")
        let completions=NativeFixtureCompletions(),released=NativeFixtureCount()
        defer {completions.open()}
        let events=NativeFixtureBox<[NativeAudioOutputEvent]>([]),attempt=NativeMediaAttempt()
        let player=AACAudioPlayer(queue:queue,nativeAttempt:attempt,nativeOutputEvent:{event in events.update {$0.append(event)}},
            nativeCompletionDelivery:completions.receive,failureHandler:{error in Issue.record("unexpected AAC failure: \(error)")})
        player.consume(.codec(.aac));player.consume(NativeFixtures.configuration(fixture.configuration));queue.sync {}
        for (index,packet) in fixture.packets.prefix(18).enumerated() {
            do {
                let work=try #require(attempt.admit(NativeFixtures.packet(packet),audio:true,binding:nil,trace:nil,
                    externalRetention:NativeMediaLease {released.increment()},sourceIdentity:Self.mediaIdentity(track:2,sequence:UInt64(index+1))))
                player.consume(work.event,nativeWork:work)
            }
            queue.sync {}
        }
        #expect(attempt.isAdmitted && attempt.snapshot.pcm==16)
        #expect(released.value==18)
        #expect(attempt.mediaOutputPressureDrops==2)
        let scheduled=events.value.filter {if case .scheduled=$0 {return true};return false}.count
        let converted=events.value.filter {if case .converted=$0 {return true};return false}.count
        #expect(scheduled==16 && converted==16,"the existing PCM gate precedes conversion: two queued inputs were dropped")
        try await NativeFixtures.until {completions.count==16}
        completions.open()
        try await NativeFixtures.until {attempt.snapshot.pcm==0}
        do {
            let work=try #require(attempt.admit(NativeFixtures.packet(fixture.packets[18]),audio:true,binding:nil,trace:nil,sourceIdentity:Self.mediaIdentity(track:2,sequence:19)))
            player.consume(work.event,nativeWork:work)
        }
        queue.sync {}
        #expect(events.value.filter {if case .scheduled=$0 {return true};return false}.count==17)
        #expect(await player.beginNativeRetirement()?.wait().succeeded==true)
    }
    @Test(arguments: [false, true]) func mediaPolicyDecodedPressurePreservesDependentContinuity(hevc: Bool) async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: hevc, frameCount: 18, width: 64, height: 64, keyframes: [0], motion: true)
        #expect(fixture.packets.dropFirst().allSatisfy { !$0.key })
        let events = try NativeFixtures.videoEvents(fixture)
        let frames = NativeFixtureBox<[NativeDecodedFrame]>([])
        let completed = NativeFixtureCount()
        let attempt = NativeMediaAttempt()
        let decoder = VideoToolboxDecoder(nativeAttempt: attempt,
            ownedFrameHandler: { frame in frames.update { $0.append(frame) } },
            frameHandler: { _, _, _ in Issue.record("owned output required") },
            failureHandler: { error in Issue.record("unexpected actual decode failure: \(error)") })
        events.prefix(3).forEach { decoder.consume($0) }
        for index in 0..<17 {
            do {
                let work = try #require(attempt.admit(events[index + 3], audio: false, binding: nil, trace: nil,
                    externalRetention: NativeMediaLease { completed.increment() },sourceIdentity:Self.mediaIdentity(track:1,sequence:UInt64(index+1),key:index==0)))
                decoder.consume(work.event, nativeWork: work)
            }
            try await NativeFixtures.until { completed.value == index + 1 }
            if index < 16 { try await NativeFixtures.until { frames.value.count == index + 1 } }
        }
        #expect(attempt.isAdmitted, "successful seventeenth decode/output pressure must not poison the attempt")
        #expect(attempt.snapshot.decoded == 16)
        #expect(attempt.mediaOutputPressureDrops == 1)
        frames.update { $0.removeFirst() }
        if attempt.isAdmitted {
            let work=try #require(attempt.admit(events[20],audio:false,binding:nil,trace:nil,sourceIdentity:Self.mediaIdentity(track:1,sequence:18)))
            decoder.consume(work.event,nativeWork:work)
            try await NativeFixtures.until { frames.value.count == 16 }
            #expect(frames.value.last?.presentationTime == CMTime(value: Int64(fixture.packets[17].pts), timescale: 1_000_000))
        }
        frames.update { $0.removeAll() }
        let retirement = try #require(decoder.beginNativeRetirement())
        #expect(await retirement.wait().succeeded)
    }

    @Test(arguments: [false, true]) func decodedOutputDoesNotOwnCompressedInput(hevc: Bool) async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
        let events = try NativeFixtures.videoEvents(fixture)
        let decode = DispatchQueue(label: "native-transfer.decode")
        let frames = NativeFixtureBox<[NativeDecodedFrame]>([])
        let released = NativeFixtureCount()
        let attempt = NativeMediaAttempt()
        let decoder = VideoToolboxDecoder(queue: decode, nativeAttempt: attempt,
            ownedFrameHandler: { frame in frames.update { $0.append(frame) } },
            frameHandler: { _, _, _ in Issue.record("must use owned output") },
            failureHandler: { error in Issue.record("actual decoder failed: \(error)") })
        events.prefix(3).forEach { decoder.consume($0) }
        var cloned: ScrcpyStreamEvent?
        do {
            let work = try #require(attempt.admit(events[3], audio: false, binding: nil, trace: nil,
                externalRetention: NativeMediaLease { released.increment() }))
            cloned = work.event
            decoder.consume(work.event, nativeWork: work)
        }
        try await NativeFixtures.until { frames.value.count == 1 }
        decode.sync {}
        #expect(released.value == 0, "a real encoded Data clone must retain input charge")
        withExtendedLifetime(cloned) {}
        cloned = nil
        #expect(released.value == 1, "decoded pixels/context must not retain compressed input")
        #expect(attempt.snapshot.decoded == 1 && attempt.snapshot.jobs > 0)
        #expect(frames.value[0].presentationTime == CMTime(value: Int64(fixture.packets[0].pts), timescale: 1_000_000))
        #expect(abs(Int(NativeFixtures.marker(frames.value[0].pixelBuffer)) - Int(fixture.packets[0].marker)) <= 4)
        let retirement = try #require(decoder.beginNativeRetirement())
        #expect(!retirement.snapshot.actuallySettled)
        frames.update { $0.removeAll() }
        #expect(await retirement.wait().succeeded)
    }

    @Test(arguments: [2, 4096]) func externalCopyChargeFollowsFinalOwnedReference(count: Int) async throws {
        let attempt = NativeMediaAttempt()
        let released = NativeFixtureCount()
        var external: NativeMediaLease? = NativeMediaLease { released.increment() }
        var work = attempt.admit(NativeFixtures.configuration(Data(repeating: 0x67, count: count)),
            audio: false, binding: nil, trace: nil, externalRetention: external)
        #expect(work != nil)
        external = nil
        #expect(released.value == 0)
        var packet = work?.event
        let retirement = attempt.retire()
        #expect(!retirement.snapshot.actuallySettled)
        if count > MemoryLayout<Data>.size {
            work = nil
            #expect(released.value == 0)
        }
        withExtendedLifetime(packet) {}
        packet = nil; work = nil
        #expect(released.value == 1)
        #expect(await retirement.wait().succeeded)
    }

    @Test @MainActor func highNALSampleAndFinalOwnedReference() async throws {
        let attempt = NativeMediaAttempt()
        let freed = NativeFixtureCount()
        var work: NativeMediaWork?
        NativeFixtures.withOversizedNALBacking(count: 4 * 1024 * 1024, freed: freed) { event in
            work = attempt.admit(event, audio: false, binding: nil, trace: nil)
        }
        #expect(freed.value == 1)
        var retainedEvent = work?.event
        var sample: (Data, NativeMediaLease)?
        if case let .packet(packet) = retainedEvent, let admitted = work {
            sample = NativeAnnexB.lengthPrefixedSample(from: packet.payload, work: admitted)
        }
        #expect(sample?.0.count == 5 * 1024 * 1024)
        #expect(sample?.0.prefix(5) == Data([0, 0, 0, 1, 0x65]))
        #expect(sample?.0.suffix(5) == Data([0, 0, 0, 1, 0x65]))
        // Independent capacities: 4 MiB admitted input + 5 MiB sample +
        // 5 MiB CMBlockBuffer copy, plus two fixed Data inline representations.
        #expect(attempt.snapshot.bytes == 14 * 1024 * 1024 + 2 * MemoryLayout<Data>.size)
        work = nil
        let retirement = attempt.retire()
        #expect(!retirement.snapshot.actuallySettled)
        sample = nil
        #expect(retirement.snapshot.jobs == 1 && retirement.snapshot.bytes == 4 * 1024 * 1024 + MemoryLayout<Data>.size)
        withExtendedLifetime(retainedEvent) {}
        retainedEvent = nil
        #expect(await retirement.wait().succeeded)
    }

    @Test func boundedAnnexBMatchesStockLiteralSemantics() async throws {
        let literals: [[UInt8]] = [[0x65, 8], [0, 0, 1, 0x65], [0, 0, 0, 1, 0x67, 8, 0, 0, 1, 0x68, 9],
            [9, 9, 0, 0, 1, 0x65, 0, 0, 0, 1], [0, 0, 1, 0, 0, 1, 0x65]]
        for literal in literals {
            let attempt = NativeMediaAttempt()
            var work = attempt.admit(NativeFixtures.configuration(Data(literal)), audio: false, binding: nil, trace: nil)
            var result = NativeAnnexB.lengthPrefixedSample(from: Data(literal), work: try #require(work))
            #expect(result?.0 == AnnexB.lengthPrefixedSample(from: Data(literal)))
            result = nil; work = nil
            #expect(await attempt.retire().wait().succeeded)
        }
    }

    @Test(arguments: [false, true]) @MainActor func actualSuccessorAACAndVideoAfterSettlement(hevc: Bool) async throws {
        let audioFixture = try QuicCodecFixtureFactory.audio()
        let videoFixture = try QuicCodecFixtureFactory.video(hevc: hevc)
        let events = try NativeFixtures.videoEvents(videoFixture)
        let session = try NativeFixtures.session()
        let audioA = DispatchQueue(label: "native-retirement.successor-audio-A")
        let playoutA = DispatchQueue(label: "native-retirement.successor-playout-A")
        let meterA = PrimaryMediaDiagnostics(generation: 701, sink: { _ in })
        let meterB = PrimaryMediaDiagnostics(generation: 702, sink: { _ in })
        let frames = NativeFixtureBox<[NativeDecodedFrame]>([])
        session.ownedDecodedFrameHandler = { frame in frames.update { $0.append(frame) } }
        let a = try session.beginNativeAttempt(audioQueue: audioA, playoutQueue: playoutA)
        a.audio.consume(.codec(.aac)); a.audio.consume(NativeFixtures.configuration(audioFixture.configuration))
        audioA.sync {}
        let holdAudio = NativeFixtureSuspension(audioA)
        let holdPlayout = NativeFixtureSuspension(playoutA)
        defer { holdAudio.resume(); holdPlayout.resume() }
        for packet in audioFixture.packets {
            let trace = meterA.received(stream: .audio, bytes: packet.bytes.count, pts: packet.pts, epoch: nil)
            a.audio.consume(NativeFixtures.packet(packet), diagnosticTrace: trace)
        }
        events.prefix(4).forEach { session.handleVideo($0) }
        try await NativeFixtures.until { a.attempt.snapshot.decoded == 1 }
        session.stop()
        #expect(throws: NativeMediaFailure.cleanupIncomplete) { try session.beginNativeAttempt() }
        holdAudio.resume()
        await session.stopAndWaitForCleanup()
        #expect(a.attempt.snapshot.actuallySettled && session.nativeRetirementOutcome?.succeeded == true)
        holdPlayout.resume(); playoutA.sync {}
        #expect(frames.value.isEmpty)
        let beforeA = meterA.snapshot(now: ProcessInfo.processInfo.systemUptime).clockTracks
        #expect(beforeA[0] == 0)

        let audioB = DispatchQueue(label: "native-retirement.successor-audio-B")
        let b = try session.beginNativeAttempt(audioQueue: audioB)
        let output = NativeFixtureBox<[NativeAudioOutputEvent]>([])
        b.audio.observeNativeOutput { event in output.update { $0.append(event) } }
        b.audio.consume(.codec(.aac)); b.audio.consume(NativeFixtures.configuration(audioFixture.configuration))
        audioB.sync {}
        events.prefix(3).forEach { session.handleVideo($0) }
        let firstPacket = videoFixture.packets[0]
        let trace = try #require(meterB.received(stream: .video, bytes: firstPacket.bytes.count, pts: firstPacket.pts, epoch: nil))
        session.handleVideo(events[3], diagnosticTrace: trace)
        try await NativeFixtures.until { frames.value.count == 1 }
        #expect(frames.value[0].context.attempt.id == b.attempt.id && a.attempt.id != b.attempt.id)
        #expect(frames.value[0].trace?.collector === meterB && frames.value[0].trace?.sequence == trace.sequence)
        #expect(frames.value[0].presentationTime == CMTime(value: Int64(firstPacket.pts), timescale: 1_000_000))
        #expect(abs(Int(NativeFixtures.marker(frames.value[0].pixelBuffer)) - Int(firstPacket.marker)) <= 4)
        for packet in audioFixture.packets {
            let audioTrace = try #require(meterB.received(stream: .audio, bytes: packet.bytes.count, pts: packet.pts, epoch: nil))
            let event = NativeFixtures.packet(packet)
            let work = try #require(b.admit(event, audio: true, trace: audioTrace))
            #expect(work.attempt.id == b.attempt.id && work.trace?.collector === meterB)
            b.audio.consume(work.event, diagnosticTrace: audioTrace, nativeWork: work)
        }
        audioB.sync {}
        #expect(output.value.contains { if case let .converted(count) = $0 { return count > 0 }; return false })
        #expect(output.value.contains { if case .scheduled = $0 { return true }; return false })
        #expect(meterB.snapshot(now: ProcessInfo.processInfo.systemUptime).clockTracks[0] > 0)
        // Delayed A inputs still target A; no relabeling into B or clock effect.
        a.audio.consume(NativeFixtures.packet(audioFixture.packets[0]))
        a.video.consume(events[3])
        audioA.sync {}; playoutA.sync {}
        #expect(meterA.snapshot(now: ProcessInfo.processInfo.systemUptime).clockTracks == beforeA)
        #expect(frames.value.count == 1)
        frames.update { $0.removeAll() }
        await session.stopAndWaitForCleanup()
        #expect(session.nativeRetirementOutcome?.attemptID == b.attempt.id && session.nativeRetirementOutcome?.succeeded == true)
    }

    @Test(arguments: [4.999, 5.0, 5.1]) func settlementUsesOriginalCutoff(elapsed: Double) async throws {
        let time = NativeFixtureBox(100.0)
        let watchdog = NativeFixtureCompletions()
        let queue = DispatchQueue(label: "native-retirement.withheld-watchdog")
        let attempt = NativeMediaAttempt(now: { time.value }, watchdog: watchdog.receive)
        let player = AACAudioPlayer(queue: queue, nativeAttempt: attempt, failureHandler: { _ in })
        let hold = NativeFixtureSuspension(queue)
        defer { hold.resume(); watchdog.open() }
        player.consume(.codec(.aac))
        let retirement = attempt.retire()
        let sourceFailure: NativeMediaFailure? = elapsed > 5 ? .codec("original-source-failure") : nil
        if let sourceFailure { attempt.fail(sourceFailure) }
        let first = Task { await retirement.wait() }
        let second = Task { await attempt.retire().wait() }
        time.update { $0 = 100 + elapsed }
        #expect(retirement.originalCutoffExpired == (elapsed >= 5))
        hold.resume()
        queue.sync {} // Actual owned AAC cleanup, before any watchdog delivery.
        let result = await first.value
        #expect(result.snapshot.actuallySettled)
        #expect(result.failure == (elapsed < 5 ? nil : .cleanupIncomplete))
        #expect(result.sourceFailure == sourceFailure)
        #expect(await second.value.failure == result.failure)
        time.update { $0 = 106 }
        #expect(retirement.originalCutoffExpired)
        watchdog.open()
        #expect(await retirement.wait().failure == result.failure)
        withExtendedLifetime(player) {}
    }

    @Test(arguments: [false, true]) func queuedInputReleasesOversizedBorrowedBacking(audio: Bool) async throws {
        let queue = DispatchQueue(label: "native-retirement.borrowed-backing")
        let hold = NativeFixtureSuspension(queue)
        defer { hold.resume() }
        let attempt = NativeMediaAttempt()
        let freed = NativeFixtureCount()
        let count = audio ? 64 * 1024 : 4 * 1024 * 1024
        let player = AACAudioPlayer(queue: queue, nativeAttempt: attempt, failureHandler: { _ in })
        let decoder = VideoToolboxDecoder(queue: queue, nativeAttempt: attempt,
            frameHandler: { _, _, _ in }, failureHandler: { _ in })
        NativeFixtures.withOversizedNALBacking(count: count, freed: freed) { event in
            if audio { player.consume(event) } else { decoder.consume(event) }
        }
        #expect(attempt.snapshot.bytes >= count && attempt.snapshot.jobs == 1)
        #expect(freed.value == 1, "owned async queue must not retain the oversized borrowed backing")
        let retirement = attempt.retire()
        hold.resume()
        #expect(await retirement.wait().succeeded)
        #expect(freed.value == 1)
    }

    // 01-predecessor-test.swift retains the old stop-edge failure. Permanent
    // owned retirement is additive; legacy stop is still a queue-ordered reset.
    @Test func queuedActualAACRetirement() async throws {
        let fixture = try QuicCodecFixtureFactory.audio()
        let queue = DispatchQueue(label: "native-retirement.predecessor-audio")
        let meter = PrimaryMediaDiagnostics(generation: 101, sink: { _ in })
        let errors = NativeFixtureCount()
        let inputsReleased = NativeFixtureCount()
        let attempt = NativeMediaAttempt()
        let player = AACAudioPlayer(queue: queue, nativeAttempt: attempt, failureHandler: { _ in errors.increment() })
        player.consume(.codec(.aac))
        player.consume(.packet(.init(isConfiguration: true, isKeyFrame: false,
                                    presentationTimeUs: nil, payload: fixture.configuration)))
        queue.sync {}
        let suspension = NativeFixtureSuspension(queue)
        defer { suspension.resume() }
        for packet in fixture.packets {
            let trace = try #require(meter.received(stream: .audio, bytes: packet.bytes.count,
                                                   pts: packet.pts, epoch: nil))
            let work = try #require(attempt.admit(NativeFixtures.packet(packet), audio: true, binding: nil, trace: trace,
                externalRetention: NativeMediaLease { inputsReleased.increment() }))
            player.consume(work.event, diagnosticTrace: trace, nativeWork: work)
        }
        #expect(inputsReleased.value == 0, "queued AAC still owns real compressed input")
        let retirement = try #require(player.beginNativeRetirement())
        #expect(!retirement.snapshot.actuallySettled)
        suspension.resume()
        queue.sync {}
        #expect(inputsReleased.value == fixture.packets.count)
        #expect(errors.value == 0)
        #expect(meter.snapshot(now: ProcessInfo.processInfo.systemUptime).clockTracks[0] == 0,
                "retired queued AAC must not reach actual nonempty conversion/clock")
        #expect(await retirement.wait().succeeded)
        withExtendedLifetime(player) {}
    }

    @Test func realScheduledPCMRetainsCompletionCredits() async throws {
        let fixture = try QuicCodecFixtureFactory.audio()
        let queue = DispatchQueue(label: "native-retirement.scheduled-audio")
        let events = NativeFixtureBox<[NativeAudioOutputEvent]>([])
        let errors = NativeFixtureCount()
        let inputsReleased = NativeFixtureCount()
        let completions = NativeFixtureCompletions()
        defer { completions.open() }
        let attempt = NativeMediaAttempt()
        let player = AACAudioPlayer(queue: queue, nativeAttempt: attempt,
            nativeOutputEvent: { event in events.update { $0.append(event) } },
            nativeCompletionDelivery: completions.receive, failureHandler: { _ in errors.increment() })
        player.consume(.codec(.aac)); player.consume(NativeFixtures.configuration(fixture.configuration))
        for packet in fixture.packets {
            let work = try #require(attempt.admit(NativeFixtures.packet(packet), audio: true, binding: nil, trace: nil,
                externalRetention: NativeMediaLease { inputsReleased.increment() }))
            player.consume(work.event, nativeWork: work)
        }
        queue.sync {}
        #expect(inputsReleased.value == fixture.packets.count, "real scheduled PCM owns output/job, not compressed input")
        let converted = events.value.filter { if case let .converted(frames) = $0 { return frames > 0 }; return false }.count
        let scheduled = events.value.filter { if case .scheduled = $0 { return true }; return false }.count
        #expect(converted > 0 && scheduled > 0 && errors.value == 0)
        let retirement = try #require(player.beginNativeRetirement())
        queue.sync {}
        try await NativeFixtures.until { completions.count == scheduled }
        #expect(retirement.snapshot.pcm == scheduled)
        #expect(retirement.snapshot.bytes >= scheduled * 32_768)
        #expect(!retirement.snapshot.actuallySettled)
        #expect(events.value.contains { if case .stopped = $0 { return true }; return false })
        completions.open()
        #expect(await retirement.wait().succeeded)
        #expect(retirement.snapshot.jobs == 0 && retirement.snapshot.bytes == 0)
        #expect(events.value.filter { if case .completed = $0 { return true }; return false }.count == scheduled)
        #expect(await player.beginNativeRetirement()?.wait().succeeded == true)
    }

    @Test(arguments: [false, true]) func queuedVTAndActualPlayoutRetirement(hevc: Bool) async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
        let events = try NativeFixtures.videoEvents(fixture)
        for holdBeforeDecode in [true, false] {
            let decode = DispatchQueue(label: "native-retirement.decode")
            let playout = DispatchQueue(label: "native-retirement.playout")
            let queued = NativeFixtureCount(); let delivered = NativeFixtureCount(); let errors = NativeFixtureCount()
            let attempt = NativeMediaAttempt()
            let decoder = VideoToolboxDecoder(queue: decode, playoutQueue: playout, nativeAttempt: attempt,
                ownedFrameHandler: { _ in delivered.increment() }, nativeOutputQueued: queued.increment,
                frameHandler: { _, _, _ in Issue.record("owned branch must be exclusive") },
                failureHandler: { _ in errors.increment() })
            let playoutHold = NativeFixtureSuspension(playout)
            let decodeHold = holdBeforeDecode ? NativeFixtureSuspension(decode) : nil
            defer { decodeHold?.resume(); playoutHold.resume() }
            events.forEach { decoder.consume($0) }
            if !holdBeforeDecode { try await NativeFixtures.until { queued.value > 0 } }
            let retirement = try #require(decoder.beginNativeRetirement())
            decodeHold?.resume()
            // Do not release playout: settlement must release its actual payload
            // cells without requiring an inert scheduled wake to execute.
            let outcome = await retirement.wait()
            playoutHold.resume()
            #expect(outcome.succeeded)
            #expect(delivered.value == 0 && errors.value == 0)
            #expect(retirement.snapshot.bytes == 0 && retirement.snapshot.decoded == 0)
        }
    }

    @Test(arguments: [false, true]) @MainActor func genuineOwnerPixelsPTSAndPrimaryBinding(hevc: Bool) async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: hevc)
        let events = try NativeFixtures.videoEvents(fixture)
        let session = try NativeFixtures.session()
        let frames = NativeFixtureBox<[NativeDecodedFrame]>([])
        let surface = VideoSurfaceModel(); let aspects = NativeFixtureCount(); let records = NativeFixtureCount()
        session.ownedDecodedFrameHandler = { frame in
            AppModel.receiveEnhancedNativeFrame(frame, surface: surface, admitted: true,
                updateAspect: { _ in aspects.increment() }, record: records.increment)
            frames.update { $0.append(frame) }
        }
        let owner = try session.beginNativeAttempt()
        events.prefix(4).forEach { session.handleVideo($0) }
        try await NativeFixtures.until { frames.value.count == 1 }
        #expect(surface.hasFrame && aspects.value == 1 && records.value == 1)
        #expect(frames.value[0].context.attempt.id == owner.attempt.id)
        #expect(frames.value[0].presentationTime == CMTime(value: Int64(fixture.packets[0].pts), timescale: 1_000_000))
        #expect(abs(Int(NativeFixtures.marker(frames.value[0].pixelBuffer)) - Int(fixture.packets[0].marker)) <= 4)
        let previous = frames.value[0].context.binding
        session.ownedDecodedFrameHandler = { _ in Issue.record("old frame must not be relabeled") }
        #expect(previous?.isAdmitted == false)
        // Invoke the actual final body with the already decoded old envelope.
        AppModel.receiveEnhancedNativeFrame(frames.value[0], surface: surface, admitted: true,
            updateAspect: { _ in aspects.increment() }, record: records.increment)
        #expect(aspects.value == 1 && records.value == 1)
        frames.update { $0.removeAll() }
        await session.stopAndWaitForCleanup()
        #expect(session.nativeRetirementOutcome?.succeeded == true)
        // Surface retention is deliberately outside the native byte settlement.
        #expect(surface.hasFrame)
    }

    @Test @MainActor func publicCloseJoinsNativeQueueAndFreshBundle() async throws {
        let session = try NativeFixtures.session()
        let audio = DispatchQueue(label: "native-retirement.session-audio")
        let a = try session.beginNativeAttempt(audioQueue: audio)
        let suspension = NativeFixtureSuspension(audio)
        defer { suspension.resume() }
        let completed = NativeFixtureCount()
        let first = Task { await session.stopAndWaitForCleanup(); completed.increment() }
        let second = Task { await session.stopAndWaitForCleanup(); completed.increment() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(completed.value == 0)
        #expect(session.nativeOwner == nil)
        #expect(throws: NativeMediaFailure.cleanupIncomplete) { try session.beginNativeAttempt() }
        suspension.resume()
        await first.value; await second.value
        #expect(completed.value == 2 && session.nativeRetirementOutcome?.succeeded == true)
        let b = try session.beginNativeAttempt()
        #expect(a !== b && a.audio !== b.audio && a.video !== b.video)
        #expect(a.videoClock !== b.videoClock && a.audioClock !== b.audioClock)
        #expect(a.videoClock !== a.audioClock && b.videoClock !== b.audioClock)
        #expect(a.attempt.id.sessionID == b.attempt.id.sessionID && a.attempt.id != b.attempt.id)
        await session.stopAndWaitForCleanup()
        #expect(session.nativeRetirementOutcome?.attemptID == b.attempt.id)
    }

    @Test @MainActor func watchdogDoesNotRenewOrGrantSuccessorBeforeActualSettlement() async throws {
        let session = try NativeFixtures.session()
        let audio = DispatchQueue(label: "native-retirement.watchdog")
        let owner = try session.beginNativeAttempt(audioQueue: audio)
        let suspension = NativeFixtureSuspension(audio)
        defer { suspension.resume() }
        let began = ProcessInfo.processInfo.systemUptime
        session.stop()
        let retirement = owner.retire()
        let canceled = Task { await retirement.wait() }
        canceled.cancel()
        try await Task.sleep(for: .milliseconds(40))
        let duplicate = owner.retire()
        await session.stopAndWaitForCleanup()
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        #expect(elapsed >= 4.9 && elapsed < 6.0)
        #expect(session.nativeRetirementOutcome?.failure == .cleanupIncomplete)
        #expect(!retirement.snapshot.actuallySettled && retirement.snapshot.fences > 0)
        #expect(throws: NativeMediaFailure.cleanupIncomplete) { try session.beginNativeAttempt() }
        #expect(await canceled.value.failure == .cleanupIncomplete)
        suspension.resume()
        try await NativeFixtures.until { retirement.snapshot.actuallySettled }
        #expect(await duplicate.wait().failure == .cleanupIncomplete)
        #expect(session.nativeRetirementOutcome?.succeeded == false)
        try session.beginNativeAttempt()
        await session.stopAndWaitForCleanup()
    }

    @Test func countAndAggregateByteCapsRetainFinalReferences() async throws {
        let failures = NativeFixtureCount()
        let attempt = NativeMediaAttempt { _ in failures.increment() }
        var jobs = (0..<64).compactMap { _ in attempt.admit(.codec(.h264), audio: false, binding: nil, trace: nil) }
        #expect(jobs.count == 64 && attempt.snapshot.jobs == 64)
        #expect(attempt.admit(.codec(.aac), audio: true, binding: nil, trace: nil) == nil)
        #expect(failures.value == 1 && !attempt.isAdmitted)
        var last: NativeMediaWork? = jobs.last
        jobs.removeAll()
        #expect(attempt.snapshot.jobs == 1)
        withExtendedLifetime(last) {}
        last = nil
        #expect(await attempt.retire().wait().failure == .capacity)
        let bytes = NativeMediaAttempt()
        var work = bytes.admit(.codec(.aac), audio: true, binding: nil, trace: nil)
        var allocation = work?.reserve(NativeMediaAttempt.maximumBytes - 4)
        #expect(bytes.snapshot.bytes == NativeMediaAttempt.maximumBytes)
        #expect(work?.reserve(1) == nil)
        work = nil
        #expect(bytes.snapshot.jobs == 1 && bytes.snapshot.bytes > 0)
        withExtendedLifetime(allocation) {}
        allocation = nil
        #expect(await bytes.retire().wait().failure == .capacity)
        #expect(bytes.snapshot.actuallySettled)
    }

    @Test @MainActor func actualApplicationReceiverCloseAndPositive() async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: false)
        let events = try NativeFixtures.videoEvents(fixture)
        for closeBeforeDelivery in [true, false] {
            let application = try ApplicationWindowSession(
                application: .init(packageName: "com.example.synthetic", componentName: nil, label: "Synthetic", iconPNG: nil, isSystem: false),
                serial: "native-fixture-no-launch", adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
                companionTextHandler: { _ in false }, companionKeyHandler: { _, _, _, _ in false },
                companionClipboardHandler: { _ in false }, clipboardEventHandler: { _ in })
            let playout = DispatchQueue(label: "native-retirement.application-playout")
            let suspension = closeBeforeDelivery ? NativeFixtureSuspension(playout) : nil
            defer { suspension?.resume() }
            let owner = try application.nativeSession.beginNativeAttempt(playoutQueue: playout)
            events.prefix(4).forEach { application.nativeSession.handleVideo($0) }
            if closeBeforeDelivery {
                try await NativeFixtures.until { owner.attempt.snapshot.decoded == 1 }
                application.close()
                await application.closeAndWaitForCleanup()
                suspension?.resume()
                #expect(!application.surface.hasFrame && application.aspectRatio == 16.0 / 9.0)
            } else {
                try await NativeFixtures.until { application.surface.hasFrame }
                #expect(application.aspectRatio == 1)
                await application.closeAndWaitForCleanup()
            }
            #expect(application.nativeSession.nativeRetirementOutcome?.succeeded == true)
        }
    }

    @Test @MainActor func applicationSetupEvidenceRequiresFreshOwnedDisplayAndSurvivesNoRetirement() async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: false)
        let events = try NativeFixtures.videoEvents(fixture)
        for ending in ["presented", "closed", "retired", "display-replaced"] {
            let requests = NativeFixtureCount(), accepted = NativeFixtureCount()
            let application = try ApplicationWindowSession(
                application: .init(packageName: "com.example.synthetic", componentName: nil, label: "Synthetic", iconPNG: nil, isSystem: false),
                serial: "native-fixture-no-launch", adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
                companionTextHandler: { _ in false }, companionKeyHandler: { _, _, _, _ in false },
                companionClipboardHandler: { _ in false }, clipboardEventHandler: { _ in },
                freshFramePresentationReceipt: {
                    requests.increment()
                    return { accepted.increment() }
                })
            #expect(application.surface.freshFramePresentationReceipt?() == nil)
            try application.nativeSession.beginNativeAttempt()
            #expect(application.surface.freshFramePresentationReceipt?() == nil,
                    "a decoder without an owned application-display identity cannot verify Apps")
            let target = try ScrcpyApplicationTarget(packageName: "com.example.synthetic")
            let observer = try #require(try application.nativeSession.beginApplicationDisplayObservation(for: target))
            observer.receive(Data("[server] INFO: New display: 64x64/420 (id=51)\n".utf8))
            try await NativeFixtures.until { application.nativeSession.applicationDisplayIdentity?.displayID == 51 }
            #expect(requests.value == 0, "display allocation or catalog metadata alone cannot request evidence")
            events.prefix(4).forEach { application.nativeSession.handleVideo($0) }
            try await NativeFixtures.until { application.surface.hasFrame }
            #expect(requests.value == 1 && accepted.value == 0,
                    "actual VT frame admission captures evidence but cannot pretend Metal showed it")

            // Controlled successful presentation of a captured fresh-frame
            // receipt. Actual drawable/GPU gating is tested by the surface suite.
            let completion = try #require(application.surface.freshFramePresentationReceipt?())
            switch ending {
            case "closed": application.close()
            case "retired": application.nativeSession.stop()
            case "display-replaced":
                let replacement = try #require(try application.nativeSession.beginApplicationDisplayObservation(for: target))
                replacement.receive(Data("[server] INFO: New display: 64x64/420 (id=52)\n".utf8))
                try await NativeFixtures.until { application.nativeSession.applicationDisplayIdentity?.displayID == 52 }
            default: break
            }
            completion()
            #expect(accepted.value == (ending == "presented" ? 1 : 0),
                    "closed, retired or replaced displays must reject an in-flight presentation result")
            await application.closeAndWaitForCleanup()
            #expect(application.surface.freshFramePresentationReceipt == nil)
        }
    }

    @Test func actualVTLifetimeThroughQueuedCleanup() async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: false)
        let queue = DispatchQueue(label: "native-retirement.lifetime")
        let outputs = NativeFixtureCount()
        let attempt = NativeMediaAttempt()
        var decoder: VideoToolboxDecoder? = VideoToolboxDecoder(queue: queue, nativeAttempt: attempt,
            ownedFrameHandler: { _ in outputs.increment() }, frameHandler: { _, _, _ in }, failureHandler: { _ in })
        weak let weakDecoder = decoder
        try NativeFixtures.videoEvents(fixture).prefix(4).forEach { decoder?.consume($0) }
        try await NativeFixtures.until { outputs.value == 1 }
        let suspension = NativeFixtureSuspension(queue)
        defer { suspension.resume() }
        let retirement = try #require(decoder?.beginNativeRetirement())
        decoder = nil
        #expect(weakDecoder != nil && !retirement.snapshot.actuallySettled)
        suspension.resume()
        #expect(await retirement.wait().succeeded)
        try await NativeFixtures.until { weakDecoder == nil }
    }

    @Test @MainActor func actualDecodedActorHoldMigrationAndRetirement() async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: false)
        let events = try NativeFixtures.videoEvents(fixture)
        let session = try NativeFixtures.session()
        let deliveries = NativeFixtureActorDeliveries()
        defer { deliveries.release() }
        let a = NativeFixtureCount(); let b = NativeFixtureCount()
        session.ownedDecodedFrameHandler = { _ in a.increment() }
        let owner = try session.beginNativeAttempt(frameDelivery: deliveries.receive)
        events.prefix(4).forEach { session.handleVideo($0) }
        try await NativeFixtures.until { deliveries.count == 1 }
        session.ownedDecodedFrameHandler = { _ in b.increment() }
        deliveries.release()
        #expect(a.value == 0 && b.value == 0)
        // Fresh binding accepts real output of the same attempt, not relabeled A.
        events.prefix(4).forEach { session.handleVideo($0) }
        try await NativeFixtures.until { deliveries.count == 1 }
        deliveries.release()
        #expect(a.value == 0 && b.value == 1)
        events.prefix(4).forEach { session.handleVideo($0) }
        try await NativeFixtures.until { deliveries.count == 1 }
        session.stop()
        #expect(!owner.attempt.snapshot.actuallySettled && owner.attempt.snapshot.decoded == 1)
        deliveries.release()
        await session.stopAndWaitForCleanup()
        #expect(b.value == 1 && session.nativeRetirementOutcome?.succeeded == true)
    }

    @Test @MainActor func actualMalformedVTSubmissionRecoversWithoutRetiringControlOwner() async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: false)
        let session = try ScrcpySession(serial: "quic-video-recovery-fixture",
            adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false,
            quicSelection: .init(targetToken: 9))
        let frames = NativeFixtureCount()
        session.ownedDecodedFrameHandler = { _ in frames.increment() }
        let owner = try session.beginNativeAttempt()
        try NativeFixtures.videoEvents(fixture).prefix(3).forEach { session.handleVideo($0) }
        session.handleVideo(.packet(.init(isConfiguration: false, isKeyFrame: true,
            presentationTimeUs: 1_000_000, payload: Data([0, 0, 0, 1, 0x65, 0x88]))))
        try await NativeFixtures.until { owner.video.recoveredFrameErrorCount > 0 }
        #expect(owner.attempt.isAdmitted && frames.value == 0)
        let recovered = NativeFixtures.packet(fixture.packets[4])
        session.handleVideo(recovered)
        try await NativeFixtures.until { frames.value == 1 }
        #expect(owner.attempt.isAdmitted && session.nativeOwner === owner)
        await session.stopAndWaitForCleanup()
        #expect(frames.value == 1)
        #expect(session.nativeRetirementOutcome?.succeeded == true)
        #expect(session.nativeRetirementOutcome?.snapshot.actuallySettled == true)
    }

    @Test @MainActor func wirelessPreparationFailureDoesNotMasqueradeAsEncoderIncompatibility() async throws {
        let owners = NativeFixtureBox<[ScrcpyNativeMediaOwner]>([])
        let session = try ScrcpySession(serial: "192.0.2.1:5555",
            adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false,
            nativePreparationBoundary: { owner, _ in
                owners.update { $0.append(owner) }
                throw ADBClientError.commandFailed(code: 1, message: "fixture: device offline")
            })
        session.start(preferredCodec: .h264)
        try await NativeFixtures.until {
            if case .failed = session.state { return true }
            return false
        }
        await session.stopAndWaitForCleanup()
        #expect(owners.value.count == 1)
        #expect(owners.value.allSatisfy { $0.attempt.snapshot.actuallySettled })
    }

    @Test @MainActor func publicStartFallbackJoinsRealDecodedPredecessorAndRestart() async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: true)
        let events = try NativeFixtures.videoEvents(fixture)
        let owners = NativeFixtureBox<[ScrcpyNativeMediaOwner]>([])
        let codecs = NativeFixtureBox<[ScrcpyCodec]>([])
        let held = NativeFixtureBox<[NativeDecodedFrame]>([])
        let session = try ScrcpySession(serial: "native-public-start-no-ADB",
            adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false,
            nativePreparationBoundary: { owner, codec in
                owners.update { $0.append(owner) }; codecs.update { $0.append(codec) }
                if codecs.value.count == 1 {
                    for event in events.prefix(4) {
                        let work = try #require(owner.admit(event))
                        owner.video.consume(event, nativeWork: work)
                    }
                    try await NativeFixtures.until { held.value.count == 1 }
                    // Existing prepare-error classification triggers real h265
                    // fallback. No ADB call or native result is forged.
                    throw QuicFixtureError.unsupported
                }
                return false
            })
        session.ownedDecodedFrameHandler = { frame in held.update { $0.append(frame) } }
        session.start(preferredCodec: .h265)
        try await NativeFixtures.until { owners.value.first?.attempt.snapshot.retired == true }
        #expect(owners.value.count == 1 && session.nativeOwner == nil)
        #expect(owners.value[0].attempt.snapshot.decoded == 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(owners.value.count == 1)
        held.update { $0.removeAll() }
        try await NativeFixtures.until { owners.value.count == 2 }
        #expect(codecs.value == [.h265, .h264])
        #expect(owners.value[0].attempt.snapshot.actuallySettled)
        #expect(owners.value[0].attempt.id != owners.value[1].attempt.id)
        #expect(owners.value[0].videoClock !== owners.value[1].videoClock)
        #expect(owners.value[0].audioClock !== owners.value[1].audioClock)
        #expect(owners.value[0].videoClock !== owners.value[0].audioClock)
        #expect(owners.value[1].videoClock !== owners.value[1].audioClock)
        session.restart(captureTarget: .display(id: 0))
        try await NativeFixtures.until { owners.value.count == 3 }
        #expect(owners.value[1].attempt.snapshot.actuallySettled)
        await session.stopAndWaitForCleanup()
        #expect(session.nativeRetirementOutcome?.succeeded == true)
    }

    @Test @MainActor func ownedCodecFailureRetiresExactlyOnceWithoutFallbackAllocation() async throws {
        let session = try NativeFixtures.session()
        let owner = try session.beginNativeAttempt()
        session.handleVideo(.codec(.aac))
        try await NativeFixtures.until { !owner.attempt.isAdmitted && session.nativeOwner == nil }
        await session.stopAndWaitForCleanup()
        #expect(session.nativeRetirementOutcome?.succeeded == false)
        #expect(session.nativeRetirementOutcome?.snapshot.actuallySettled == true)
        #expect(session.nativeOwner == nil)
        let next = try session.beginNativeAttempt()
        #expect(next.attempt.id != owner.attempt.id)
        await session.stopAndWaitForCleanup()
    }

    @Test @MainActor func legacyDiagnosticAndPlainBranchesAreExclusive() async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: false)
        for diagnostic in [false, true] {
            let session = try NativeFixtures.session()
            let plainCount = NativeFixtureCount(); let diagnosticCount = NativeFixtureCount()
            session.decodedFrameHandler = { _, _, _ in plainCount.increment() }
            if diagnostic { session.diagnosticDecodedFrameHandler = { _, _, _, _ in diagnosticCount.increment() } }
            try session.beginNativeAttempt()
            try NativeFixtures.videoEvents(fixture).prefix(4).forEach { session.handleVideo($0) }
            try await NativeFixtures.until { plainCount.value + diagnosticCount.value == 1 }
            #expect(plainCount.value == (diagnostic ? 0 : 1))
            #expect(diagnosticCount.value == (diagnostic ? 1 : 0))
            await session.stopAndWaitForCleanup()
            #expect(session.nativeRetirementOutcome?.succeeded == true)
        }
    }

    @Test func payloadAndOutputLimits() async throws {
        for (audio, configuration, count) in [(false, false, 4 * 1024 * 1024), (true, false, 64 * 1024), (false, true, 64 * 1024)] {
            let attempt = NativeMediaAttempt()
            var work = attempt.admit(.packet(.init(isConfiguration: configuration, isKeyFrame: true,
                presentationTimeUs: 1, payload: Data(count: count))), audio: audio, binding: nil, trace: nil)
            #expect(work != nil)
            work = nil
            #expect(attempt.admit(.packet(.init(isConfiguration: configuration, isKeyFrame: true,
                presentationTimeUs: 1, payload: Data(count: count + 1))), audio: audio, binding: nil, trace: nil) == nil)
            #expect(await attempt.retire().wait().failure == .invalidSize)
        }
        for kind: NativeMediaAttempt.AllocationKind in [.decoded, .pcm] {
            let attempt = NativeMediaAttempt()
            var work = attempt.admit(.codec(.aac), audio: true, binding: nil, trace: nil)
            var outputs = (0..<16).compactMap { _ in work?.reserve(32_768, kind: kind) }
            #expect(outputs.count == 16)
            #expect(work?.reserve(32_768, kind: kind) == nil)
            work = nil; outputs.removeAll()
            #expect(await attempt.retire().wait().failure == .capacity)
            let oversized = NativeMediaAttempt()
            var other = oversized.admit(.codec(.aac), audio: true, binding: nil, trace: nil)
            let cap = kind == .decoded ? NativeMediaAttempt.maximumDecoded : NativeMediaAttempt.maximumPCM
            #expect(other?.reserve(cap + 1, kind: kind) == nil)
            other = nil
            #expect(await oversized.retire().wait().failure == .invalidSize)
        }
        // Injected status accounting only: this does not forge a VT result.
        let statusOwner = NativeMediaAttempt()
        var operation = statusOwner.operation()
        let statusRetirement = statusOwner.retire()
        statusOwner.fail(.nativeCleanup(-12900))
        withExtendedLifetime(operation) {}
        operation = nil
        let statusOutcome = await statusRetirement.wait()
        #expect(statusOutcome.failure == .nativeCleanup(-12900))
        #expect(statusOutcome.sourceFailure == .nativeCleanup(-12900) && !statusOutcome.succeeded)
    }
}
