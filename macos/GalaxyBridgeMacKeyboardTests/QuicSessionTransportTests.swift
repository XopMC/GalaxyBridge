#if !GALAXYBRIDGE_APP_STORE && GB_QUIC_BACKEND_QA
import CoreMedia
import AVFoundation
import Foundation
import Darwin
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import Testing
@testable import GalaxyBridgeMac

@_silgen_name("gb_backend_retire")
private func diagnosticTestRetire(_ owner: UInt64) -> UInt32

@Suite(.serialized)
struct QuicSessionTransportTests {
    @Test func videoSequenceGapRequiresDecoderReferenceReset() {
        var continuity = QuicVideoSequenceContinuity()

        let first = continuity.observe(1)
        let contiguous = continuity.observe(2)
        let gap = continuity.observe(5)
        let successor = continuity.observe(6)
        #expect(!first)
        #expect(!contiguous)
        #expect(gap, "a missing AU must invalidate VideoToolbox reference state")
        #expect(!successor)

        continuity.reset()
        let fresh = continuity.observe(101)
        let secondGap = continuity.observe(103)
        #expect(!fresh, "a new configuration starts a fresh sequence observation")
        #expect(secondGap)
    }

    @Test func getClipboardUsesPriorityControlWhileSetClipboardStaysBulk() throws {
        var encoder = QuicControlEncoder(generation: 41)

        let get = try encoder.encode(Data([8, 1]))
        #expect(get.kind == 1)
        #expect(get.bytes.prefix(4) == Data("GQM1".utf8))
        #expect(get.bytes[4] == 8)
        #expect(get.bytes.count == 102)
        #expect(get.bytes[64] == 9)
        #expect(get.bytes.suffix(2) == Data([8, 1]))

        let set = try encoder.encode(Data([9, 0, 0, 0, 0, 0, 0, 0, 1]))
        #expect(set.kind == 3)
        #expect(set.bytes == Data([9, 0, 0, 0, 0, 0, 0, 0, 1]))
    }

    @Test func exhaustedMediaRecoveryRetriesEachNativeBoundedEpisode() {
        var gate = BoundedMediaRecoveryRetryGate()

        #expect(gate.retryEpisode(state: 2, reason: 0, attempt: 2, episode: 7) == nil)
        #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 7) == 7)
        #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 7) == nil)
        #expect(gate.retryEpisode(state: 2, reason: 0, attempt: 1, episode: 8) == nil)
        #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 8) == 8)
        for _ in 0..<1000 {
            #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 8) == nil)
        }

        #expect(gate.retryEpisode(state: 1, reason: 0, attempt: 0, episode: 0) == nil)
        #expect(gate.retryEpisode(state: 3, reason: 3, attempt: 3, episode: 9) == nil)
        // Native timeout is authoritative even if congestion prevented the
        // owner from publishing its final request in the 1500–1750ms window.
        #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 2, episode: 9) == 9)
        #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 9) == nil)
        #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 7) == nil)
        #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 0) == nil)
        #expect(gate.retryEpisode(state: 4, reason: 5, attempt: 3, episode: 10) == nil)
        #expect(gate.retryEpisode(state: 3, reason: 5, attempt: 3, episode: 10) == 10)
    }

    @Test func qaPrimaryEightMbpsEligibilityAndDefaultParity() throws {
        #expect(QuicRuntimeArtifacts.enabledMediaFeatures(audioEnabled: true) == 15)
        #expect(QuicRuntimeArtifacts.enabledMediaFeatures(audioEnabled: false) == 13)
        let flags = ["--experimental-quic-wireless", "--qa-quic-primary-8mbps"]
        let primary = ScrcpyLaunchConfiguration(scid: 7)
        for bundle in [nil, "com.xopmc.GalaxyBridge", "com.xopmc.GalaxyBridge.internal.other"] as [String?] {
            #expect(throws: QuicRuntimeArtifacts.PrimaryRateExperimentError.self) {
                try QuicRuntimeArtifacts.producerArguments(configuration: primary, processArguments: flags, bundleIdentifier: bundle)
            }
        }
        #expect(throws: QuicRuntimeArtifacts.PrimaryRateExperimentError.self) {
            try QuicRuntimeArtifacts.producerArguments(configuration: primary,
                processArguments: ["--qa-quic-primary-8mbps"], bundleIdentifier: "com.xopmc.GalaxyBridge.internal")
        }
        let app = try ScrcpyApplicationTarget(packageName: "com.example.fixture")
        let captures = [ScrcpyLaunchConfiguration(scid: 7, captureTarget: .display(id: 1)),
            ScrcpyLaunchConfiguration(scid: 7, captureTarget: .virtualDisplay(width: 800, height: 600, dpi: 200)),
            ScrcpyLaunchConfiguration(scid: 7, applicationTarget: app),
            ScrcpyLaunchConfiguration(scid: 7, captureTarget: .virtualDisplay(width: 800, height: 600, dpi: 200), applicationTarget: app)]
        for c in captures {
            #expect(throws: QuicRuntimeArtifacts.PrimaryRateExperimentError.self) {
                try QuicRuntimeArtifacts.producerArguments(configuration: c, processArguments: flags,
                    bundleIdentifier: "com.xopmc.GalaxyBridge.internal")
            }
        }
        for c in [primary] + captures {
            let original = try QuicRuntimeArtifacts.producerArguments(configuration: c,
                processArguments: [], bundleIdentifier: nil)
            let internalOriginal = try QuicRuntimeArtifacts.producerArguments(configuration: c,
                processArguments: ["--experimental-quic-wireless"], bundleIdentifier: "com.xopmc.GalaxyBridge.internal")
            #expect(original == internalOriginal)
            #expect(original[7] == "20000000")
        }
        let custom = ScrcpyLaunchConfiguration(scid: 7, videoCodec: .h264, maxSize: 1280, maxFPS: 30,
            videoBitRate: 12_345_678, audioBitRate: 64_000,
            captureTarget: .virtualDisplay(width: 800, height: 600, dpi: 200), applicationTarget: app, cleanup: false)
        #expect(try QuicRuntimeArtifacts.producerArguments(configuration: custom, processArguments: [], bundleIdentifier: nil)
            == ["--video-codec", "h264", "--max-size", "1280", "--max-fps", "30", "--video-bit-rate", "12345678",
                "--audio-bit-rate", "64000", "--new-display", "800x600", "--launch-policy", "application", "--density", "200", "--cleanup", "false"])
    }

    @Test func quicCannotBeEnabledByAnyClientBundleOrWithoutExplicitInternalFlag() {
        let flag = ["--experimental-quic-wireless"]
        #expect(QuicRuntimeArtifacts.isExplicitlyEnabled(
            processArguments: flag,
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal"
        ))
        for bundle in [nil, "com.xopmc.GalaxyBridge", "com.xopmc.GalaxyBridge.internal.other"] as [String?] {
            #expect(!QuicRuntimeArtifacts.isExplicitlyEnabled(
                processArguments: flag,
                bundleIdentifier: bundle
            ))
        }
        #expect(!QuicRuntimeArtifacts.isExplicitlyEnabled(
            processArguments: [],
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal"
        ))
    }

    @Test func qaPrimaryEightMbpsActualVector() throws {
        for codec in [ScrcpyCodec.h264, .h265] {
            let c = ScrcpyLaunchConfiguration(scid: 7, videoCodec: codec)
            let baseline = try QuicRuntimeArtifacts.producerArguments(configuration: c,
                processArguments: ["--experimental-quic-wireless"], bundleIdentifier: "com.xopmc.GalaxyBridge.internal")
            let experiment = try QuicRuntimeArtifacts.producerArguments(configuration: c,
                processArguments: ["--experimental-quic-wireless", "--qa-quic-primary-8mbps"], bundleIdentifier: "com.xopmc.GalaxyBridge.internal")
            let expected = ["--video-codec", codec == .h265 ? "h265" : "h264", "--max-size", "2560",
                "--max-fps", "60", "--video-bit-rate", "20000000", "--audio-bit-rate", "128000", "--launch-policy", "primary", "--cleanup", "true"]
            #expect(baseline == expected)
            var eight = expected; eight[7] = "8000000"
            #expect(experiment == eight, "the actual owned producer profile must change only the video target")
            #expect(c.videoBitRate == 20_000_000 && c.serverArguments.contains("video_bit_rate=20000000"))
        }
    }

    @Test func qaMediaPacingIsInternalPrimaryOnlyAndDoesNotAlterProducerProfile() throws {
        let flags = ["--experimental-quic-wireless", "--qa-quic-media-pacing-2mbps"]
        let primary = ScrcpyLaunchConfiguration(scid: 7)
        #expect(try QuicRuntimeArtifacts.peerTransportArguments(
            configuration: primary,
            processArguments: flags,
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal"
        ) == ["--media-max-pacing-bytes-per-second", "2000000"])
        #expect(try QuicRuntimeArtifacts.peerTransportArguments(
            configuration: primary,
            processArguments: ["--experimental-quic-wireless"],
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal"
        ) == ["--media-max-pacing-bytes-per-second", "2000000"])
        for bundle in [nil, "com.xopmc.GalaxyBridge"] as [String?] {
            #expect(throws: QuicRuntimeArtifacts.PrimaryRateExperimentError.self) {
                try QuicRuntimeArtifacts.peerTransportArguments(
                    configuration: primary,
                    processArguments: flags,
                    bundleIdentifier: bundle
                )
            }
        }
        let app = try ScrcpyApplicationTarget(packageName: "com.example.fixture")
        for capture in [
            ScrcpyLaunchConfiguration(scid: 7, captureTarget: .display(id: 1)),
            ScrcpyLaunchConfiguration(scid: 7, applicationTarget: app),
            ScrcpyLaunchConfiguration(
                scid: 7,
                captureTarget: .virtualDisplay(width: 800, height: 600, dpi: 200)
            )
        ] {
            #expect(throws: QuicRuntimeArtifacts.PrimaryRateExperimentError.self) {
                try QuicRuntimeArtifacts.peerTransportArguments(
                    configuration: capture,
                    processArguments: flags,
                    bundleIdentifier: "com.xopmc.GalaxyBridge.internal"
                )
            }
        }
        #expect(try QuicRuntimeArtifacts.producerArguments(
            configuration: primary,
            processArguments: flags,
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal"
        )[7] == "20000000")
    }

    @Test func wirelessProducerPreservesPeriodicKeyFrameInterval() throws {
        let wireless = ScrcpyLaunchConfiguration(
            scid: 7,
            videoCodec: .h264,
            maxSize: 1_920,
            maxFPS: 60,
            videoBitRate: 12_000_000,
            videoKeyFrameIntervalSeconds: 1
        )

        let arguments = try QuicRuntimeArtifacts.producerArguments(
            configuration: wireless,
            processArguments: ["--experimental-quic-wireless"],
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal"
        )

        let intervalIndex = arguments.firstIndex(of: "--video-key-frame-interval-seconds")
        #expect(intervalIndex.map { arguments[$0 + 1] == "1" } == true)
    }

    @Test(arguments:[false,true]) @MainActor func fragmentedStaticIndependentActualPresentation(hevc:Bool) async throws {
        let file=try QuicBackendConsumerFixture.preparedStaticRecovery(hevc:hevc)
        let frames=NativeFixtureBox<[Int64]>([]),ingress=NativeFixtureBox<[UInt64]>([])
        let audio=NativeFixtureBox<[NativeAudioOutputEvent]>([]),failures=NativeFixtureBox<[NativeMediaFailure]>([])
        let owner=ScrcpyNativeMediaOwner(id:.init(),binding:NativeFrameBinding {frame in frames.update {$0.append(frame.presentationTime.value)}},failureHandler:{_,failure in failures.update {$0.append(failure)}})
        owner.audio.observeNativeOutput {event in audio.update {$0.append(event)}}
        try await QuicBackendConsumerFixture.run(file:file,native:owner,seconds:1.5) {admitted in
            if case let .packet(packet)=admitted.work.event,!packet.isConfiguration,admitted.identity.track==1 {ingress.update {$0.append(packet.presentationTimeUs!)}}
        }
        #expect(await owner.retire().wait().succeeded)
        let expected:[UInt64]=[1_000_000,1_400_000,1_416_667,1_433_334,1_450_001]
        #expect(ingress.value==expected)
        #expect(frames.value==expected.map(Int64.init),"sole fresh late independent image must not wait for another video frame to trigger clock rebase")
        #expect(audio.value.contains {if case let .converted(count)=$0{return count>0};return false})
        #expect(audio.value.contains {if case .scheduled=$0{return true};return false})
        #expect(failures.value.isEmpty)
        print("qa-static-result hevc=\(hevc) ingress=\(ingress.value) presented=\(frames.value) audioEvents=\(audio.value.count) settled=\(owner.attempt.snapshot.jobs)")
    }
    @Test(arguments:[false,true]) @MainActor func mediaPolicyDelayedQueuedLossAfterIndependentOutput(hevc:Bool) async throws {
        let (file,pts)=try QuicBackendConsumerFixture.preparedDelayedLoss(hevc:hevc)
        let frames=NativeFixtureBox<[Int64]>([]),admitted=NativeFixtureBox<[UInt64]>([]),dropped=NativeFixtureCount()
        let failures=NativeFixtureBox<[NativeMediaFailure]>([])
        let native=ScrcpyNativeMediaOwner(id:.init(),binding:NativeFrameBinding {frame in frames.update {$0.append(frame.presentationTime.value)}},failureHandler:{_,failure in failures.update {$0.append(failure)}})
        native.video.queuedInputDecision={identity in if identity.sequence==2 {dropped.increment();return .drop};return .consume}
        try await QuicBackendConsumerFixture.run(file:file,native:native,seconds:1,checkCommittedBorrowReleased:true,
            checkDelayedNativeLoss:true,recoveredOutput:{frames.value.contains(Int64(pts[4]))}) {item in
                if case let .packet(packet)=item.work.event,!packet.isConfiguration {admitted.update {$0.append(item.identity.sequence)}}
            }
        #expect(dropped.value==1 && admitted.value == [1,2,3,4,5,6])
        #expect(frames.value == [pts[0],pts[4],pts[5]].map(Int64.init))
        #expect(await native.retire().wait().succeeded)
        #expect(failures.value.isEmpty && native.attempt.snapshot.actuallySettled)
        print("qa-delayed-native-complete hevc=\(hevc) admitted=\(admitted.value) outputPTS=\(frames.value) settled=1")
    }
    @Test(arguments:[false,true]) @MainActor func mediaPolicyCommittedQueuedInputLoss(hevc:Bool) async throws {
        let file=try QuicBackendConsumerFixture.prepared(hevc:hevc)
        let frames=NativeFixtureBox<[Int64]>([]),dropped=NativeFixtureBox<[NativeMediaSourceIdentity]>([])
        let admitted=NativeFixtureBox<[UInt64]>([])
        let session=try ScrcpySession(serial:"post-admitted-loss",adb:ADBClient(testingExecutableURL:URL(fileURLWithPath:"/unexercised-adb")),
            physicalDisplayPolicy:.leaveUnchanged,automaticDisplayManagement:false,quicSelection:.init(targetToken:9),
            quicPreparedLaunch:{config,generation in Self.fixtureLaunch(file:file,generation:generation,scid:config.scid)},
            nativePreparationBoundary:{owner,_ in
                owner.video.queuedInputDecision={identity in
                    if identity.sequence==2 {dropped.update {$0.append(identity)};return .drop}
                    return .consume
                };return true
            })
        session.ownedDecodedFrameHandler={frame in frames.update {$0.append(frame.presentationTime.value)}}
        session.videoEventHandler={event in if case let .packet(packet)=event,!packet.isConfiguration,let pts=packet.presentationTimeUs {admitted.update {$0.append(pts)}}}
        session.start(preferredCodec:hevc ? .h265:.h264)
        let end=QuicReceiptClock.now+2_000_000_000
        while frames.value.last != 1_066_668 && session.quicRetirementOutcome==nil && QuicReceiptClock.now<end {try await Task.sleep(for:.milliseconds(1))}
        #expect(dropped.value.count==1 && dropped.value[0].sequence==2)
        #expect(admitted.value.contains(1_016_667),"committed input callback is preserved despite later queued decode loss")
        #expect(frames.value==[1_000_000,1_066_668])
        #expect(session.mediaHealth[1]?.admittedInputDropped==1)
        #expect(session.mediaHealth[1]?.episode==0 && session.quicRetirementOutcome==nil)
        print("qa-post-admitted-input hevc=\(hevc) lost=1 committedPTS=\(admitted.value) decodedPTS=\(frames.value)")
        await session.stopAndWaitForCleanup()
        #expect(session.quicRetirementOutcome?.failed==false && session.nativeRetirementOutcome?.succeeded==true)
    }
    @Test func mediaPolicyNumericLogGateIsOptInAndRateBounded() {
        for enabled in [false,true] {
            var gate=QuicMediaHealthLogGate(),counts=[0,0,0]
            for now in stride(from:UInt64(0),to:1_000_000_000,by:1_000_000) {
                for track in 1...2 {if gate.take(track:track,changed:true,now:now,enabled:enabled,final:false) {counts[track]+=1}}
            }
            #expect(counts == (enabled ? [0,4,4]:[0,0,0]))
            for track in 1...2 {
                let final=gate.take(track:track,changed:false,now:999_000_000,enabled:enabled,final:true)
                let repeated=gate.take(track:track,changed:true,now:2_000_000_000,enabled:enabled,final:true)
                #expect(final==enabled)
                #expect(!repeated)
            }
        }
    }
    @Test(arguments: [false,true]) @MainActor func mediaPolicyPublicSixSecondMotionPressureRecovery(hevc:Bool) async throws {
        let fixture=try QuicBackendConsumerFixture.preparedMotion(hevc:hevc)
        #expect(fixture.video.packets.count==360)
        #expect(fixture.video.packets.filter(\.key).map(\.pts)==[1_000_000,2_000_000,3_000_000,4_000_000,5_000_000,6_000_000])
        #expect(fixture.video.packets.filter(\.key).allSatisfy {$0.bytes.count>960})
        let held=NativeFixtureBox<[ScrcpyStreamEvent]>([]), retaining=NativeFixtureBox(false)
        let frames=NativeFixtureBox<[Int64]>([]), pcm=NativeFixtureCount()
        let admitted=NativeFixtureBox<[UInt8:Int]>([:]), effects=NativeFixtureBox<[[UInt64]]>([]),acks=NativeFixtureBox<[UInt64]>([])
        let session=try ScrcpySession(serial:"media-policy-fixture",adb:ADBClient(testingExecutableURL:URL(fileURLWithPath:"/unexercised-adb")),
            physicalDisplayPolicy:.leaveUnchanged,automaticDisplayManagement:false,quicSelection:.init(targetToken:9),
            quicPreparedLaunch:{ config,generation in Self.fixtureLaunch(file:fixture.file,generation:generation,scid:config.scid,duration:9000) },
            nativePreparationBoundary:{owner,_ in owner.audio.observeNativeOutput {if case .scheduled=$0 {pcm.increment()}};return true})
        let observe:@Sendable(UInt8,ScrcpyStreamEvent)->Void={track,event in
            guard case let .packet(packet)=event,!packet.isConfiguration else{return}
            admitted.update {$0[track,default:0]+=1}
            if retaining.value {held.update {$0.append(event)}}
        }
        session.videoEventHandler={observe(1,$0)};session.audioEventHandler={observe(2,$0)}
        session.ownedDecodedFrameHandler={frame in frames.update {$0.append(frame.presentationTime.value)}}
        session.quicStockObservation={value in effects.update {$0.append(value)}}
        session.quicDeviceObservation={if case let .clipboardAcknowledgement(sequence)=$0 {acks.update {$0.append(sequence)}}}
        session.start(preferredCodec:hevc ? .h265:.h264)
        // Establish a genuinely visible frame before manufacturing retained
        // consumer pressure. Otherwise scheduling jitter can exhaust the
        // bounded recovery attempts before the decoder has received its first
        // VCL packet, which tests cold-start starvation instead of the promised
        // "keep the last good frame" recovery behavior.
        // Allow the next periodic IDR to establish the first visible frame if
        // VideoToolbox defers the cold-start HEVC callback. Recovery after the
        // manufactured gap is still independently bounded by the one-second
        // IDR cadence and asserted below without replacing the live session.
        let firstFrameEnd=QuicReceiptClock.now+3_000_000_000
        while (frames.value.isEmpty || session.screenInterlockPresentation != .mirroring)
                && session.quicRetirementOutcome==nil && QuicReceiptClock.now<firstFrameEnd {
            try await Task.sleep(for:.milliseconds(1))
        }
        #expect(!frames.value.isEmpty)
        #expect(session.screenInterlockPresentation == .mirroring)
        retaining.update {$0=true}
        let end=QuicReceiptClock.now+8_000_000_000
        while !(session.mediaHealth[1]?.state == 2
                && session.mediaHealth[1]?.attempt == 3
                && !frames.value.isEmpty
                && session.screenInterlockPresentation == .mirroring)
                && session.quicRetirementOutcome==nil && QuicReceiptClock.now<end {
            try await Task.sleep(for:.milliseconds(1))
        }
        let degraded=session.mediaHealth[1]
        #expect(degraded?.state==2 && degraded?.attempt==3)
        #expect(!frames.value.isEmpty)
        // A compatible last frame remains visible while bounded recovery is
        // active; manufacturing a black placeholder would turn a recoverable
        // motion gap into a user-visible outage.
        #expect(session.screenInterlockPresentation == .mirroring)
        let sameAttempt=session.nativeOwner?.attempt.id
        #expect(held.value.count>=48)
        // Actual retained encoded observer references caused admission pressure.
        // Retire none of them early: finish their real use, then drop ownership.
        retaining.update {$0=false};held.update {$0.removeAll()}
        var gesture:[Data]=[]
        for action in [ScrcpyMotionAction.down,.move,.up] {
            let bytes=ScrcpyControlMessage.virtualFingerTouch(action:action,x:100,y:100,screenWidth:640,screenHeight:360,pressure:action == .up ? 0:1)
            gesture.append(bytes);session.sendControl(bytes)
            try await NativeFixtures.until {effects.value.contains {QuicBackendConsumerFixture.stockMatches($0,bytes)}}
        }
        session.sendText("x")
        while (frames.value.last != Int64(fixture.video.packets.last!.pts) || acks.value.isEmpty) && session.quicRetirementOutcome==nil && QuicReceiptClock.now<end {try await Task.sleep(for:.milliseconds(1))}
        #expect(session.nativeOwner?.attempt.id==sameAttempt)
        #expect(session.quicRetirementOutcome==nil)
        #expect(session.mediaHealth[1]?.state==1)
        #expect(frames.value.last==Int64(fixture.video.packets.last!.pts))
        #expect(frames.value.count<360 && frames.value.contains(5_000_000))
        #expect(pcm.value>0 && acks.value == [0x8000_0000_0000_0000])
        let gestureOrder=try gesture.map {bytes in try #require(effects.value.first {QuicBackendConsumerFixture.stockMatches($0,bytes)})[0]}
        #expect(zip(gestureOrder,gestureOrder.dropFirst()).allSatisfy {$0<$1})
        print("qa-media-policy-public hevc=\(hevc) videoSource=360 audioSource=\(fixture.audio.packets.count) videoAdmitted=\(admitted.value[1,default:0]) audioAdmitted=\(admitted.value[2,default:0]) videoOutput=\(frames.value.count) pcm=\(pcm.value) declined=\(session.mediaHealth[1]?.declined ?? 0) skipped=\(session.mediaHealth[1]?.skipped ?? 0) recoveryAttempts=\(degraded?.attempt ?? 0) ownerUnchanged=\(session.nativeOwner?.attempt.id==sameAttempt)")
        await session.stopAndWaitForCleanup()
        #expect(session.quicRetirementOutcome?.failed==false)
        #expect(session.nativeRetirementOutcome?.succeeded==true)
    }
    @Test(arguments:[false,true]) @MainActor func mediaPolicyPermanentlyWithheldConsumerIsBounded(noInputUntilIdle:Bool) async throws {
        let fixture=try QuicBackendConsumerFixture.preparedMotion(hevc:false)
        let held=NativeFixtureBox<[ScrcpyStreamEvent]>([]),frames=NativeFixtureCount()
        let effects=NativeFixtureBox<[[UInt64]]>([]),acks=NativeFixtureBox<[UInt64]>([])
        let session=try ScrcpySession(serial:"media-policy-withheld",adb:ADBClient(testingExecutableURL:URL(fileURLWithPath:"/unexercised-adb")),
            physicalDisplayPolicy:.leaveUnchanged,automaticDisplayManagement:false,quicSelection:.init(targetToken:9),
            quicPreparedLaunch:{config,generation in Self.fixtureLaunch(file:fixture.file,generation:generation,scid:config.scid,duration:9000)})
        let retain:@Sendable(ScrcpyStreamEvent)->Void={event in
            if case let .packet(packet)=event,!packet.isConfiguration {held.update {$0.append(event)}}
        }
        session.videoEventHandler=retain;session.audioEventHandler=retain
        session.ownedDecodedFrameHandler={_ in frames.increment()}
        session.quicStockObservation={value in effects.update {$0.append(value)}}
        session.quicDeviceObservation={if case let .clipboardAcknowledgement(sequence)=$0 {acks.update {$0.append(sequence)}}}
        session.start(preferredCodec:.h264)
        let started=QuicReceiptClock.now,end=started+7_000_000_000
        while session.mediaHealth[1]?.state != 3 && session.quicRetirementOutcome==nil && QuicReceiptClock.now<end {try await Task.sleep(for:.milliseconds(1))}
        let health=try #require(session.mediaHealth[1]),native=try #require(session.nativeOwner)
        #expect(health.attempt==3 && health.nextDeadline==0 && health.episode != 0)
        let count=held.value.count,decoded=frames.value
        #expect(count>=48 && count<=64)
        // Separate finite control-progress and actual no-input idle cases.
        let following=ScrcpyControlMessage.uhidInput(id:ScrcpyUHIDKeyboard.id,report:Data([0,0,4,0,0,0,0,0]))
        if !noInputUntilIdle {
            session.sendText("held")
            session.sendKeyboardControl(following)
        }
        // Keep the same real encoded references through the scheduled fresh IDR
        // and the end of the six-second source. No test-only credit release.
        while QuicReceiptClock.now<started+6_600_000_000 && session.quicRetirementOutcome==nil {
            #expect(native.attempt.snapshot.jobs<=64 && native.attempt.snapshot.bytes<=128*1024*1024)
            #expect(session.mediaHealth[1]?.episode==health.episode && session.mediaHealth[1]?.nextDeadline==0)
            try await Task.sleep(for:.milliseconds(20))
        }
        #expect(session.quicRetirementOutcome==nil && session.nativeOwner?.attempt.id==native.attempt.id)
        #expect(held.value.count==count && frames.value==decoded)
        #expect(session.mediaHealth[1]?.state==3 && session.mediaHealth[1]?.attempt==3)
        if noInputUntilIdle {
            #expect(acks.value.isEmpty)
            print("qa-native-no-input-idle elapsedNs=\(QuicReceiptClock.now-started) sameAttempt=\(session.nativeOwner?.attempt.id==native.attempt.id) jobs=\(native.attempt.snapshot.jobs) retained=\(held.value.count) attempt=\(session.mediaHealth[1]?.attempt ?? 0)")
            session.sendText("held")
            session.sendKeyboardControl(following)
            try await NativeFixtures.until {effects.value.contains {QuicBackendConsumerFixture.stockMatches($0,following)}}
        }
        let sequence:UInt64=0x8000_0000_0000_0000
        #expect(acks.value == [sequence])
        let set=ScrcpyControlMessage.setClipboard(sequence:sequence,text:"held",paste:false)
        let ack=Data([1,128,0,0,0,0,0,0,0])
        let setEffect=try #require(effects.value.first {QuicBackendConsumerFixture.stockMatches($0,set)})
        let ackEffect=try #require(effects.value.first {QuicBackendConsumerFixture.stockMatches($0,ack,direction:2)})
        let followingEffect=try #require(effects.value.first {QuicBackendConsumerFixture.stockMatches($0,following)})
        let paste=try ScrcpyUHIDKeyboard.pasteMessages.map {bytes in try #require(effects.value.first {QuicBackendConsumerFixture.stockMatches($0,bytes)})}
        #expect(setEffect[0]<ackEffect[0] && ackEffect[0]<paste[0][0] && paste.last![0]<followingEffect[0])
        #expect(followingEffect[3]-ackEffect[3]>=240_000_000)
        print("qa-permanent-withhold retained=\(count) frames=\(decoded) jobs=\(native.attempt.snapshot.jobs) bytes=\(native.attempt.snapshot.bytes) attempt=3 recoveryDeadline=0")
        held.update {$0.removeAll()}
        await session.stopAndWaitForCleanup()
        #expect(session.quicRetirementOutcome?.failed==false && session.nativeRetirementOutcome?.succeeded==true)
        #expect(native.attempt.snapshot.actuallySettled)
    }
    @Test(arguments: [false, true]) @MainActor func actualCDecodedOutputAndIndependentInputLifetimes(hevc: Bool) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: hevc, audioEnabled: false)
        let frames = NativeFixtureBox<[NativeDecodedFrame]>([])
        let identities = NativeFixtureBox<[NativeMediaSourceIdentity]>([])
        let owner = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { frame in
            frames.update { $0.append(frame) }
        }, failureHandler: { _, error in Issue.record("native failure: \(error)") })
        try await QuicBackendConsumerFixture.run(file: file, native: owner, checkDecodedInputLifetime: true,
            until: { !frames.value.isEmpty }) { item in
                if case let .packet(packet) = item.work.event, !packet.isConfiguration { identities.update { $0.append(item.identity.native) } }
            }
        #expect(frames.value.count == 1 && identities.value.count == 1)
        #expect(frames.value.first?.context.sourceIdentity == identities.value.first)
        #expect(frames.value.first?.context.attempt.id == owner.attempt.id)
        #expect(frames.value.first?.presentationTime.value == 1_000_000)
        #expect(!owner.attempt.snapshot.actuallySettled && owner.attempt.snapshot.decoded == 1)
        frames.update { $0.removeAll() }
        #expect(await owner.retire().wait().succeeded)
    }

    @Test(arguments: [false, true]) @MainActor func publicSessionNativeTransferWithEncodedObserver(hevc: Bool) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: hevc, sustained: true)
        let fixture = try Data(contentsOf: file)
        var expected: [String: String] = [:]
        var offset = 12
        while offset < fixture.count {
            let track = fixture[offset + 8]
            let size = Int(fixture[offset+12..<offset+16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            let record = fixture.subdata(in: offset+16..<offset+16+size)
            if size >= 12 && record[0] & 0xc0 == 0 {
                let pts = record.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & ((1 << 61) - 1)
                expected["\(track):\(pts)"] = QuicBackendConsumerFixture.hash(record.subdata(in: 12..<record.count))
            }
            offset += 16 + size
        }
        let received = NativeFixtureBox<[String: String]>([:])
        let held = NativeFixtureBox((current: 0, peak: 0))
        let frames = NativeFixtureBox<[Int64]>([]), pcm = NativeFixtureCount()
        let effects = NativeFixtureBox<[[UInt64]]>([]), acks = NativeFixtureBox<[UInt64]>([])
        let session = try ScrcpySession(serial: "native-transfer-fixture", adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/unexercised-adb")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false, quicSelection: .init(targetToken: 9),
            quicPreparedLaunch: { config, generation in Self.fixtureLaunch(file: file, generation: generation, scid: config.scid) },
            nativePreparationBoundary: { owner, _ in
                owner.audio.observeNativeOutput { if case .scheduled = $0 { pcm.increment() } }; return true
            })
        let observer: @Sendable (UInt8, ScrcpyStreamEvent) -> Void = { track, event in
            guard case let .packet(packet) = event, !packet.isConfiguration, let pts = packet.presentationTimeUs else { return }
            held.update { $0.current += 1; $0.peak = max($0.peak, $0.current) }
            // Real independently owned encoded bytes cross the delay. Do not
            // manually release their native/C lease or substitute a digest.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                received.update { $0["\(track):\(pts)"] = QuicBackendConsumerFixture.hash(packet.payload) }
                held.update { $0.current -= 1 }
            }
        }
        session.videoEventHandler = { observer(1, $0) }
        session.audioEventHandler = { observer(2, $0) }
        session.ownedDecodedFrameHandler = { frame in
            frames.update { $0.append(frame.presentationTime.value) }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(90))
                withExtendedLifetime(frame) {}
            }
        }
        session.quicStockObservation = { value in effects.update { $0.append(value) } }
        session.quicDeviceObservation = { if case let .clipboardAcknowledgement(sequence) = $0 { acks.update { $0.append(sequence) } } }
        session.start(preferredCodec: hevc ? .h265 : .h264)
        let end = QuicReceiptClock.now + 3_500_000_000
        while frames.value.isEmpty && session.quicRetirementOutcome == nil && QuicReceiptClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        session.sendText("x")
        let following = ScrcpyControlMessage.uhidInput(id: ScrcpyUHIDKeyboard.id, report: Data([0, 0, 4, 0, 0, 0, 0, 0]))
        session.sendKeyboardControl(following)
        while (received.value.count < expected.count || held.value.current > 0) && session.quicRetirementOutcome == nil && QuicReceiptClock.now < end {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(received.value == expected)
        #expect(held.value.peak > 8)
        let expectedPTS: [Int64] = (0..<120).map { 1_000_000 + Int64($0) * 1_000_000 / 60 }
        #expect(frames.value == expectedPTS)
        #expect(pcm.value > 80)
        let sequence: UInt64 = 0x8000_0000_0000_0000
        #expect(acks.value == [sequence])
        let ack = effects.value.first { QuicBackendConsumerFixture.stockMatches($0, Data([1,128,0,0,0,0,0,0,0]), direction: 2) }
        let input = effects.value.first { QuicBackendConsumerFixture.stockMatches($0, following) }
        #expect(ack != nil && input != nil)
        if let ack, let input { #expect(ack[0] < input[0] && input[3] - ack[3] >= 240_000_000) }
        print("qa-public-transfer hevc=\(hevc) encoded=\(received.value.count)/\(expected.count) heldPeak=\(held.value.peak) video=\(frames.value.count) pcm=\(pcm.value) status=\(session.quicRetirementOutcome?.status ?? 0)")
        // Only content hashes survive the actual90ms byte-consumer lifetime.
        received.update { $0.removeAll() }
        await session.stopAndWaitForCleanup()
        #expect(session.quicRetirementOutcome?.failed == false)
        #expect(session.nativeRetirementOutcome?.succeeded == true)
    }

    private static func diagnosticWait(_ semaphore: DispatchSemaphore, milliseconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: semaphore.wait(timeout: .now() + .milliseconds(milliseconds)) == .success) }
        }
    }
    @Test @MainActor func firstDiagnosticClaimPrecedesHeldEmissionAndRealOwnerError() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let native = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in }, failureHandler: { _, _ in })
        let ready = NativeFixtureBox(false), pollHeld = NativeFixtureBox(false), emissionHeld = NativeFixtureBox(false)
        let errors = NativeFixtureBox<[UInt32]>([]), records = NativeFixtureBox<[String]>([])
        let pollGate = DispatchSemaphore(value: 0), emissionGate = DispatchSemaphore(value: 0), sendDone = DispatchSemaphore(value: 0)
        let service = QuicScrcpySessionTransport(launch: Self.fixtureLaunch(file: file, generation: 910, scid: 1), native: native,
            callbacks: .init(ready: { ready.update { $0 = true } }, media: { _ in }, device: { _, _ in }, display: { _ in },
                failure: { error in errors.update { $0.append(error.status) } }))
        service.firstErrorEnabled = true
        service.firstErrorObservation = { line in records.update { $0.append(line) } }
        service.beforeOwnerPoll = { owner in
            if ready.value && !pollHeld.value {
                pollHeld.update { $0 = true }
                if pollGate.wait(timeout: .now() + 3) == .success { _ = diagnosticTestRetire(owner) }
            }
        }
        service.beforeFirstErrorEmission = { status in
            if status == 102 { emissionHeld.update { $0 = true }; _ = emissionGate.wait(timeout: .now() + 3) }
        }
        defer { pollGate.signal(); emissionGate.signal(); service.retire() }
        service.start()
        try await NativeFixtures.until { pollHeld.value }
        for _ in 0..<64 { service.send(ScrcpyControlMessage.getClipboard(), received: QuicReceiptClock.now, trace: nil) }
        Thread.detachNewThread {
            service.send(ScrcpyControlMessage.getClipboard(), received: QuicReceiptClock.now, trace: nil); sendDone.signal()
        }
        try await NativeFixtures.until { emissionHeld.value }
        pollGate.signal()
        try await NativeFixtures.until { errors.value.contains(107) }
        emissionGate.signal()
        #expect(await Self.diagnosticWait(sendDone, milliseconds: 2000))
        _ = await service.waitForCleanup()
        try await NativeFixtures.until { service.physicallySettled }
        let line = try #require(records.value.first)
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        #expect(records.value.count == 1)
        #expect(fields[5] == "1" && fields[7] == "102" && fields[8] == "64", "earlier actual ingress decision must win over later real owner-thread Retired")
        #expect(errors.value.contains(102) && errors.value.contains(107))
    }

    @Test @MainActor func fullDiagnosticSinkCannotDelayFailureOrNativeRetirement() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let sinkEntered = DispatchSemaphore(value: 0), sinkRelease = DispatchSemaphore(value: 0)
        let emitter = QuicFirstErrorEmitter { _ in
            sinkEntered.signal()
            _ = sinkRelease.wait(timeout: .now() + 3)
        }
        let native = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in }, failureHandler: { _, _ in })
        native.audio.consume(.codec(.aac))
        let errors = NativeFixtureBox<[UInt32]>([]), done = DispatchSemaphore(value: 0)
        let service = QuicScrcpySessionTransport(launch: Self.fixtureLaunch(file: file, generation: 911, scid: 1), native: native,
            callbacks: .init(ready: {}, media: { _ in }, device: { _, _ in }, display: { _ in }, failure: { e in errors.update { $0.append(e.status) } }))
        service.firstErrorEnabled = true
        service.firstErrorEmitter = emitter
        for _ in 0..<64 { service.send(ScrcpyControlMessage.getClipboard(), received: 0, trace: nil) }
        Thread.detachNewThread { service.send(ScrcpyControlMessage.getClipboard(), received: 0, trace: nil); done.signal() }
        let returnedBeforeDrain = await Self.diagnosticWait(done, milliseconds: 250)
        let retiredBeforeDrain = native.attempt.snapshot.retired
        let failureBeforeDrain = errors.value
        #expect(await Self.diagnosticWait(sinkEntered, milliseconds: 2000))
        let busyDropped = !emitter.offer(Data("bounded-extra\n".utf8))
        let oversizedDropped = !emitter.offer(Data(repeating: 0, count: 1025))
        // Always release the genuinely blocked sink and join exact test work,
        // including on the predecessor failure, before asserting the oracle.
        sinkRelease.signal()
        if !returnedBeforeDrain { #expect(await Self.diagnosticWait(done, milliseconds: 2000)) }
        #expect(emitter.waitUntilIdle(timeout: .now() + 2))
        let result = await native.retire().wait()
        service.start()
        _ = await service.waitForCleanup()
        try await NativeFixtures.until { service.physicallySettled }
        #expect(returnedBeforeDrain && retiredBeforeDrain && failureBeforeDrain == [102], "blocked diagnostic sink must not hold original send return, failure callback or native revoke")
        #expect(result.succeeded)
        #expect(busyDropped && oversizedDropped)
    }
    @Test @MainActor func actualFreshCBackedSuccessorWaitsForJointA() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let owners = NativeFixtureBox<[ScrcpyNativeMediaOwner]>([])
        let retained = NativeFixtureBox<NativeMediaWork?>(nil)
        let frames = NativeFixtureBox<[NativeMediaAttemptID]>([]), audio = NativeFixtureBox<Int>(0)
        let session = try ScrcpySession(serial: "successor-fixture", adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/unexercised-adb")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false, quicSelection: .init(targetToken: 9),
            quicPreparedLaunch: { config, generation in
                if owners.value.count == 1 {
                    return .init(program: "/not-launched", arguments: [], peerIP: "invalid-ip", sidecarSHA: Array(repeating: 4, count: 32),
                        generation: generation, targetToken: 9, scid: config.scid, displayID: 0, captureKind: 0, enabled: 7)
                }
                return Self.fixtureLaunch(file: file, generation: generation, scid: config.scid)
            }, nativePreparationBoundary: { owner, _ in
                owners.update { $0.append(owner) }
                if owners.value.count == 1 {
                    let work = try #require(owner.admit(.codec(.aac), audio: true))
                    retained.update { $0 = work }
                    owner.audio.consume(work.event, nativeWork: work)
                } else {
                    owner.audio.observeNativeOutput { event in if case .scheduled = event { audio.update { $0 += 1 } } }
                }
                return true
            })
        defer { retained.update { $0 = nil }; session.stop() }
        session.ownedDecodedFrameHandler = { frame in frames.update { $0.append(frame.context.attempt.id) } }
        session.start(preferredCodec: .h264)
        try await NativeFixtures.until { if case .failed = session.state { return true }; return false }
        let a = try #require(owners.value.first)
        #expect(!a.attempt.snapshot.actuallySettled)
        session.start(preferredCodec: .h264)
        try await Task.sleep(for: .milliseconds(30))
        #expect(owners.value.count == 1 && frames.value.isEmpty)
        retained.update { $0 = nil }
        do {
            try await NativeFixtures.until { frames.value.count == 5 && audio.value > 0 }
        } catch {
            print("qa-successor-stage=output owners=\(owners.value.count) frames=\(frames.value.count) audio=\(audio.value) aSettled=\(a.attempt.snapshot.actuallySettled) state=\(session.state) quic=\(String(describing: session.quicRetirementOutcome))")
            throw error
        }
        let b = try #require(owners.value.last)
        #expect(owners.value.count == 2 && a !== b && a.attempt.id != b.attempt.id)
        #expect(a.attempt.snapshot.actuallySettled)
        #expect(frames.value.allSatisfy { $0 == b.attempt.id })
        #expect(b.attempt.isAdmitted)
        await session.stopAndWaitForCleanup()
        #expect(session.quicRetirementOutcome?.failed == false && session.quicRetirementOutcome?.physicallySettled == true)
        #expect(session.nativeRetirementOutcome?.attemptID == b.attempt.id && session.nativeRetirementOutcome?.succeeded == true)
    }
    @Test(arguments: [false, true]) @MainActor func ingressCreditIncludesHeldService(bytesLimit: Bool) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let native = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in }, failureHandler: { _, _ in })
        let failures = NativeFixtureBox<[UInt32]>([]), entered = NativeFixtureBox<Bool>(false)
        let observations = NativeFixtureBox<[String]>([])
        let gate = DispatchSemaphore(value: 0)
        let service = QuicScrcpySessionTransport(launch: Self.fixtureLaunch(file: file, generation: 1, scid: 1), native: native,
            callbacks: .init(ready: {}, media: { _ in }, device: { _, _ in }, display: { _ in }, failure: { error in failures.update { $0.append(error.status) } }))
        service.beforeCommandService = { if !entered.value { entered.update { $0 = true }; _ = gate.wait(timeout: .now() + 2) } }
        service.firstErrorObservation = { line in observations.update { $0.append(line) } }
        defer { gate.signal(); service.retire() }
        let count = bytesLimit ? 2 : 64
        let data = bytesLimit ? Data(repeating: 0, count: 262144) : ScrcpyControlMessage.getClipboard()
        for _ in 0..<count { service.send(data, received: QuicReceiptClock.now, trace: nil) }
        service.start()
        try await NativeFixtures.until { entered.value }
        #expect(service.ingressUsage.commands == count)
        #expect(service.ingressUsage.bytes == count * data.count)
        service.send(ScrcpyControlMessage.getClipboard(), received: QuicReceiptClock.now, trace: nil)
        #expect(failures.value == [102])
        if ProcessInfo.processInfo.environment["GB_QUIC_FIRST_ERROR_DIAGNOSTICS"] == "1" {
            let lines = observations.value
            #expect(lines.count == 1)
            let fields = try #require(lines.first).split(whereSeparator: { $0.isWhitespace })
            #expect(fields.count == 17 && fields[0] == "GBQF1" && fields[1] == "S")
            #expect(fields[5] == "1" && fields[7] == "102")
            #expect(fields[8] == String(count) && fields[9] == "64")
            #expect(fields[11] == String(count * data.count) && fields[12] == "524288")
            #expect(lines[0].utf8.count <= 1024)
            #expect(fields.dropFirst(2).allSatisfy { UInt64($0) != nil })
        } else { #expect(observations.value.isEmpty) }
        gate.signal(); service.retire()
        _ = await service.waitForCleanup()
        try await NativeFixtures.until { service.physicallySettled }
        #expect(service.ingressUsage.commands == 0 && service.ingressUsage.bytes == 0)
        #expect(observations.value.count <= 1)
    }
    @Test @MainActor func failedConstructionStillJoinsRealNativeFence() async throws {
        let queue = DispatchQueue(label: "quic.failed-construction.aac")
        let suspension = NativeFixtureSuspension(queue)
        let native = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in }, audioQueue: queue, failureHandler: { _, _ in })
        native.audio.consume(.codec(.aac))
        let reached = NativeFixtureBox<Bool>(false)
        let launch = QuicBackendBridge.Launch(program: "/not-launched", arguments: [], peerIP: "invalid-ip",
            sidecarSHA: Array(repeating: 4, count: 32), generation: 1, targetToken: 9, scid: 1, displayID: 0, captureKind: 0, enabled: 7)
        let service = QuicScrcpySessionTransport(launch: launch, native: native, callbacks: .init(ready: {}, media: { _ in },
            device: { _, _ in }, display: { _ in }, failure: { _ in reached.update { $0 = true } }))
        defer { suspension.resume(); service.retire() }
        service.start()
        try await NativeFixtures.until { reached.value }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!native.attempt.snapshot.actuallySettled)
        #expect(!service.physicallySettled)
        suspension.resume()
        let result = await service.waitForCleanup()
        try await NativeFixtures.until { service.physicallySettled }
        #expect(result.failed)
        #expect(native.attempt.snapshot.actuallySettled)
    }
    @Test @MainActor func originalNativeFailureSurvivesLateJointCleanup() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let queue = DispatchQueue(label: "quic.original-cutoff.aac")
        let suspension = NativeFixtureSuspension(queue)
        let native = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in }, audioQueue: queue, failureHandler: { _, _ in })
        native.audio.consume(.codec(.aac))
        let selected = NativeFixtureBox<QuicScrcpySessionTransport?>(nil)
        let entered = NativeFixtureBox<Bool>(false)
        let gate = DispatchSemaphore(value: 0)
        let service = QuicScrcpySessionTransport(launch: Self.fixtureLaunch(file: file, generation: 1, scid: 1), native: native,
            callbacks: .init(ready: { selected.value?.retire() }, media: { _ in }, device: { _, _ in }, display: { _ in }, failure: { _ in }))
        selected.update { $0 = service }
        service.beforeCleanup = { entered.update { $0 = true }; _ = gate.wait(timeout: .now() + 7) }
        defer { suspension.resume(); gate.signal(); service.retire() }
        service.start()
        try await NativeFixtures.until { entered.value }
        let original = await native.retire().wait()
        #expect(original.failure == .cleanupIncomplete && !original.snapshot.actuallySettled)
        suspension.resume()
        try await NativeFixtures.until { native.attempt.snapshot.actuallySettled }
        gate.signal()
        let joint = await service.waitForCleanup()
        #expect(joint.failed && joint.status == 111)
        try await NativeFixtures.until { service.physicallySettled }
        selected.update { $0 = nil }
    }
    @Test @MainActor func actualPublicGestureContinuesThroughMove() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let frames = NativeFixtureBox<Int>(0)
        let effects = NativeFixtureBox<[[UInt64]]>([])
        let session = try ScrcpySession(serial: "gesture-fixture", adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/unexercised-adb")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false, quicSelection: .init(targetToken: 9),
            quicPreparedLaunch: { config, generation in Self.fixtureLaunch(file: file, generation: generation, scid: config.scid) })
        session.ownedDecodedFrameHandler = { _ in frames.update { $0 += 1 } }
        session.quicStockObservation = { effect in effects.update { $0.append(effect) } }
        session.start(preferredCodec: .h264)
        let end = QuicReceiptClock.now + 2_000_000_000
        while frames.value < 1, QuicReceiptClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        #expect(frames.value > 0)
        var expected: [Data] = []
        for points in [[Int32(12), 24, 24], [Int32(40), 28, 28]] {
            for (index, action) in [ScrcpyMotionAction.down, .move, .up].enumerated() {
                let bytes = ScrcpyControlMessage.virtualFingerTouch(action: action, x: points[index], y: 12,
                    screenWidth: 64, screenHeight: 64, pressure: action == .up ? 0 : 1)
                expected.append(bytes); session.sendControl(bytes)
                // Advance only after this actual stock effect, never a local send return.
                try await NativeFixtures.until { effects.value.contains { QuicBackendConsumerFixture.stockMatches($0, bytes) } }
            }
        }
        for direction in [-0.5, 0.5] {
            let bytes = ScrcpyControlMessage.scroll(x: 12, y: 12, screenWidth: 64, screenHeight: 64, horizontal: direction, vertical: -direction)
            expected.append(bytes); session.sendControl(bytes)
            try await NativeFixtures.until { effects.value.contains { QuicBackendConsumerFixture.stockMatches($0, bytes) } }
        }
        let ordinals = try expected.map { bytes in try #require(effects.value.first { QuicBackendConsumerFixture.stockMatches($0, bytes) })[0] }
        #expect(zip(ordinals, ordinals.dropFirst()).allSatisfy { $0 < $1 })
        while frames.value < 5, session.quicRetirementOutcome == nil, QuicReceiptClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        #expect(frames.value == 5)
        #expect(session.state == .streaming("Samsung Galaxy"))
        await session.stopAndWaitForCleanup()
        #expect(session.quicRetirementOutcome?.failed == false)
    }
    @Test @MainActor func burstMoveReplacementIsNotATransportFailure() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let frames = NativeFixtureBox<Int>(0)
        let effects = NativeFixtureBox<[[UInt64]]>([])
        let session = try ScrcpySession(serial: "gesture-burst-fixture",
            adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/unexercised-adb")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false,
            quicSelection: .init(targetToken: 9),
            quicPreparedLaunch: { config, generation in
                Self.fixtureLaunch(file: file, generation: generation, scid: config.scid)
            })
        session.ownedDecodedFrameHandler = { _ in frames.update { $0 += 1 } }
        session.quicStockObservation = { effect in effects.update { $0.append(effect) } }
        session.start(preferredCodec: .h264)
        try await NativeFixtures.until { frames.value > 0 }

        let down = ScrcpyControlMessage.virtualFingerTouch(action: .down, x: 12, y: 12,
            screenWidth: 64, screenHeight: 64, pressure: 1)
        session.sendControl(down)
        var lastMove = Data()
        for point in 13...44 {
            lastMove = ScrcpyControlMessage.virtualFingerTouch(action: .move, x: Int32(point), y: 12,
                screenWidth: 64, screenHeight: 64, pressure: 1)
            session.sendControl(lastMove)
        }
        let up = ScrcpyControlMessage.virtualFingerTouch(action: .up, x: 44, y: 12,
            screenWidth: 64, screenHeight: 64, pressure: 0)
        session.sendControl(up)

        try await NativeFixtures.until {
            effects.value.contains { QuicBackendConsumerFixture.stockMatches($0, up) }
        }
        #expect(effects.value.contains { QuicBackendConsumerFixture.stockMatches($0, down) })
        // A same-turn reliable UP is allowed to seal a MOVE datagram which was
        // still locally backpressured.  The release itself carries the exact
        // terminal coordinates, so requiring the redundant final MOVE made
        // this test race the documented source policy instead of checking the
        // user-visible gesture result.  Earlier accepted MOVE observations may
        // be coalesced; the reliable terminal position may not be.
        #expect(up[10..<18].elementsEqual(lastMove[10..<18]))
        #expect(session.quicRetirementOutcome == nil,
            "queued/replaced/stale/expired move admission is policy data, not a backend error")
        #expect(session.state == .streaming("Samsung Galaxy"))
        await session.stopAndWaitForCleanup()
        #expect(session.quicRetirementOutcome?.failed == false)
    }
    @Test @MainActor func committedBorrowReleasesWhileQueuedNativeCopyRemainsOwned() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let queue = DispatchQueue(label: "quic.commit-held-video")
        let suspension = NativeFixtureSuspension(queue)
        let seen = NativeFixtureBox<Bool>(false)
        let owner = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in }, videoQueue: queue,
            failureHandler: { _, _ in })
        defer { suspension.resume(); owner.retire() }
        try await QuicBackendConsumerFixture.run(file: file, native: owner, seconds: 2,
            checkCommittedBorrowReleased: true, until: { seen.value }) { admitted in
                if admitted.identity.track == 1, admitted.identity.sequence == 1,
                   case let .packet(packet) = admitted.work.event, !packet.isConfiguration { seen.update { $0 = true } }
            }
        #expect(seen.value)
        #expect(owner.attempt.snapshot.jobs > 0 && owner.attempt.snapshot.bytes > 0)
        #expect(!owner.attempt.snapshot.actuallySettled)
        suspension.resume()
        #expect(await owner.retire().wait().succeeded)
    }
    @Test(arguments: ["assigned", "conflict", "ended", "duplicate"]) @MainActor
    func actualCStatusReachesPublicApplicationGeneration(scenario: String) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false, audioEnabled: false)
        let deliveries = NativeFixtureBox<[@MainActor @Sendable () -> Void]>([])
        let frames = NativeFixtureBox<Int>(0)
        let session = try ScrcpySession(serial: "display-fixture", adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/unexercised-adb")),
            physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false, quicSelection: .init(targetToken: 10),
            quicPreparedLaunch: { config, generation in
                Self.fixtureLaunch(file: file, generation: generation, scid: config.scid, application: true, displayScenario: scenario)
            }, applicationDisplayEventDelivery: { action in deliveries.update { $0.append(action) } })
        session.ownedDecodedFrameHandler = { _ in frames.update { $0 += 1 } }
        session.start(preferredCodec: .h264, captureTarget: .virtualDisplay(width: 64, height: 64, dpi: 160),
            applicationTarget: try .init(packageName: "com.example.fixture"))
        let end = QuicReceiptClock.now + 2_000_000_000
        if scenario == "duplicate" {
            while session.quicRetirementOutcome == nil, QuicReceiptClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
            #expect(session.quicRetirementOutcome?.status == 101)
        } else {
            let expected = scenario == "assigned" ? 1 : 2
            while (deliveries.value.count < expected || frames.value < 5), QuicReceiptClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
            #expect(frames.value == 5) // Startup is independent of assignment delivery.
            #expect(deliveries.value.count == expected)
            if deliveries.value.count >= expected {
                var first: (@MainActor @Sendable () -> Void)?
                deliveries.update { first = $0.removeFirst() }; first?(); first = nil
                #expect(session.applicationDisplayIdentity?.displayID == 7)
                if expected == 2 {
                    deliveries.update { first = $0.removeFirst() }; first?(); first = nil
                    #expect(session.applicationDisplayIdentity == nil)
                }
            }
        }
        await session.stopAndWaitForCleanup()
        for action in deliveries.value { action() } // Old generation cannot resurrect assignment.
        deliveries.update { $0.removeAll() }
        #expect(session.applicationDisplayIdentity == nil)
        #expect(session.nativeRetirementOutcome?.snapshot.actuallySettled == true)
    }
    @Test(arguments: [false, true]) @MainActor func actualPublicPrimaryAndApplicationRoutes(hevc: Bool) async throws {
        let primaryFile = try QuicBackendConsumerFixture.prepared(hevc: hevc)
        let appFile = try QuicBackendConsumerFixture.prepared(hevc: hevc, audioEnabled: false)
        let primaryFrames = NativeFixtureBox<Int>(0), appFrames = NativeFixtureBox<Int>(0)
        let audio = NativeFixtureBox<Int>(0)
        let primaryEffects = NativeFixtureBox<[[UInt64]]>([]), appEffects = NativeFixtureBox<[[UInt64]]>([])
        let ackReceived = NativeFixtureBox<[UInt64]>([])
        let clipboardReceived = NativeFixtureBox<[Data]>([])
        let configurations = NativeFixtureBox<[ScrcpyLaunchConfiguration]>([])
        let adb = try ADBClient(testingExecutableURL: URL(fileURLWithPath: "/unexercised-adb"))
        let primary = ScrcpySession(serial: "primary-fixture", adb: adb, physicalDisplayPolicy: .leaveUnchanged,
            automaticDisplayManagement: false, quicSelection: .init(targetToken: 9),
            quicPreparedLaunch: { config, generation in
                configurations.update { $0.append(config) }
                return Self.fixtureLaunch(file: primaryFile, generation: generation, scid: config.scid)
            }, nativePreparationBoundary: { owner, _ in
                owner.audio.observeNativeOutput { event in if case .scheduled = event { audio.update { $0 += 1 } } }
                return true
            })
        let app = ScrcpySession(serial: "application-fixture", adb: adb, physicalDisplayPolicy: .leaveUnchanged,
            automaticDisplayManagement: false, quicSelection: .init(targetToken: 10),
            quicPreparedLaunch: { config, generation in
                configurations.update { $0.append(config) }
                return Self.fixtureLaunch(file: appFile, generation: generation, scid: config.scid, application: true)
            })
        primary.ownedDecodedFrameHandler = { _ in primaryFrames.update { $0 += 1 } }
        app.ownedDecodedFrameHandler = { _ in appFrames.update { $0 += 1 } }
        primary.quicStockObservation = { effect in primaryEffects.update { $0.append(effect) } }
        app.quicStockObservation = { effect in appEffects.update { $0.append(effect) } }
        primary.quicDeviceObservation = { message in
            if case let .clipboardAcknowledgement(sequence) = message { ackReceived.update { $0.append(sequence) } }
            if case let .clipboard(value) = message { clipboardReceived.update { $0.append(value) } }
        }
        primary.start(preferredCodec: hevc ? .h265 : .h264)
        app.start(preferredCodec: hevc ? .h265 : .h264,
            captureTarget: .virtualDisplay(width: 64, height: 64, dpi: 160),
            applicationTarget: try .init(packageName: "com.example.fixture"))
        let readyEnd = QuicReceiptClock.now + 2_000_000_000
        while (primaryFrames.value < 5 || appFrames.value < 5), QuicReceiptClock.now < readyEnd {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(primaryFrames.value == 5 && appFrames.value == 5)
        #expect(audio.value > 0)
        #expect(configurations.value.count == 2)
        #expect(configurations.value.contains { $0.applicationTarget != nil && !$0.audioEnabled && $0.initialControlMessages.count == 2 })
        #expect(primary.nativeOwner?.attempt.id != app.nativeOwner?.attempt.id)
        // Real keyboard queue, original stock ACK and post-ACK settlement;
        // no keyboard emission sink or replacement native consumer is injected.
        let following = ScrcpyControlMessage.uhidInput(id: ScrcpyUHIDKeyboard.id, report: Data([0, 0, 4, 0, 0, 0, 0, 0]))
        primary.sendText("x")
        primary.sendKeyboardControl(following)
        app.sendVirtualDisplayText("fixture")
        let resize = ScrcpyControlMessage.resizeDisplay(width: 80, height: 64)
        app.sendControl(resize)
        app.sendKeyboardControl(following)
        let sequence: UInt64 = 0x8000_0000_0000_0000
        let set = ScrcpyControlMessage.setClipboard(sequence: sequence, text: "x", paste: false)
        let ack = Data([1, 128, 0, 0, 0, 0, 0, 0, 0])
        try await NativeFixtures.until { ackReceived.value == [sequence] }
        // The following public input must still be behind the original240ms barrier.
        try await Task.sleep(for: .milliseconds(100))
        #expect(!primaryEffects.value.contains { QuicBackendConsumerFixture.stockMatches($0, following) })
        try await NativeFixtures.until { primaryEffects.value.contains { QuicBackendConsumerFixture.stockMatches($0, following) } }
        let setEffect = try #require(primaryEffects.value.first { QuicBackendConsumerFixture.stockMatches($0, set) })
        let ackEffect = try #require(primaryEffects.value.first { QuicBackendConsumerFixture.stockMatches($0, ack, direction: 2) })
        let pasteEffects = try ScrcpyUHIDKeyboard.pasteMessages.map { bytes in try #require(primaryEffects.value.first { QuicBackendConsumerFixture.stockMatches($0, bytes) }) }
        let followingEffect = try #require(primaryEffects.value.first { QuicBackendConsumerFixture.stockMatches($0, following) })
        #expect(setEffect[0] < ackEffect[0] && ackEffect[0] < pasteEffects[0][0])
        #expect(zip(pasteEffects, pasteEffects.dropFirst()).allSatisfy { $0[0] < $1[0] })
        #expect(pasteEffects.last![0] < followingEffect[0])
        #expect(followingEffect[3] - ackEffect[3] >= 240_000_000)
        try await NativeFixtures.until { appEffects.value.contains { QuicBackendConsumerFixture.stockMatches($0, following) } }
        let appText = appEffects.value.first { QuicBackendConsumerFixture.stockMatches($0, ScrcpyControlMessage.text("fixture")) }
        #expect(appText != nil)
        let appResize = try #require(appEffects.value.first { QuicBackendConsumerFixture.stockMatches($0, resize) })
        let appInput = try #require(appEffects.value.first { QuicBackendConsumerFixture.stockMatches($0, following) })
        if let appText { #expect(appText[0] < appResize[0] && appResize[0] < appInput[0]) }
        let initial = try #require(configurations.value.first { $0.applicationTarget != nil })
        for bytes in initial.initialControlMessages {
            let created = try #require(appEffects.value.first { QuicBackendConsumerFixture.stockMatches($0, bytes) })
            #expect(created[0] < appInput[0])
        }
        #expect(!primaryEffects.value.contains { QuicBackendConsumerFixture.stockMatches($0, ScrcpyControlMessage.text("fixture")) })
        #expect(!appEffects.value.contains { QuicBackendConsumerFixture.stockMatches($0, set) })
        primary.requestClipboard(copyKey: .none)
        app.requestClipboard(copyKey: .none, afterExternalCopy: true)
        try await NativeFixtures.until { clipboardReceived.value.contains(Data("x".utf8)) }
        #expect(primary.state == .streaming("Samsung Galaxy") && app.state == .streaming("Samsung Galaxy"))
        await app.stopAndWaitForCleanup()
        #expect(app.quicRetirementOutcome?.physicallySettled == true && app.quicRetirementOutcome?.failed == false)
        #expect(primary.state == .streaming("Samsung Galaxy") && primary.nativeOwner?.attempt.isAdmitted == true)
        primary.sendText("second")
        let second = ScrcpyControlMessage.setClipboard(sequence: sequence + 1, text: "second", paste: false)
        try await NativeFixtures.until { primaryEffects.value.contains { QuicBackendConsumerFixture.stockMatches($0, second) } && ackReceived.value == [sequence, sequence + 1] }
        await primary.stopAndWaitForCleanup()
        #expect(primary.quicRetirementOutcome?.physicallySettled == true && primary.quicRetirementOutcome?.failed == false)
        #expect(primary.nativeRetirementOutcome?.succeeded == true && app.nativeRetirementOutcome?.succeeded == true)
    }
    @Test @MainActor func heldReverseDoesNotBlockRealNativeMedia() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let frames = NativeFixtureBox<Int>(0)
        let held = NativeFixtureBox<[QuicDeviceDelivery]>([])
        let failures = NativeFixtureBox<[UInt32]>([])
        let selected = NativeFixtureBox<QuicScrcpySessionTransport?>(nil)
        let diagnostics = PrimaryMediaDiagnostics(generation: 33, sink: { _ in })
        let tracedFrames = NativeFixtureBox<Int>(0)
        let native = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { frame in
            frames.update { $0 += 1 }
            if frame.trace?.collector === diagnostics { tracedFrames.update { $0 += 1 } }
        }, failureHandler: { _, _ in })
        let launch = Self.fixtureLaunch(file: file, generation: 1, scid: 1)
        let service = QuicScrcpySessionTransport(launch: launch, native: native, diagnostics: diagnostics, callbacks: .init(
            ready: {
                selected.value?.send(ScrcpyControlMessage.getClipboard(), received: QuicReceiptClock.now, trace: nil)
                selected.value?.send(ScrcpyControlMessage.getClipboard(), received: QuicReceiptClock.now, trace: nil)
            },
            media: { _ in }, device: { _, delivery in held.update { $0.append(delivery) } },
            display: { _ in }, failure: { error in failures.update { $0.append(error.status) } }))
        selected.update { $0 = service }; service.start()
        let end = QuicReceiptClock.now + 2_000_000_000
        while held.value.isEmpty, QuicReceiptClock.now < end, failures.value.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let heldEnd = min(held.value.first?.originalCutoff ?? end, QuicReceiptClock.now + 1_000_000_000)
        while frames.value < 5, QuicReceiptClock.now < heldEnd, failures.value.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(held.value.count == 1)
        #expect(frames.value == 5)
        #expect(tracedFrames.value == 5)
        #expect(failures.value.isEmpty)
        if let first = held.value.first { first.deliver { true } }
        let orderedEnd = QuicReceiptClock.now + 100_000_000
        while held.value.count < 2, QuicReceiptClock.now < orderedEnd { try await Task.sleep(for: .milliseconds(1)) }
        #expect(held.value.count == 2)
        if held.value.count == 2 { held.value[1].deliver { true } }
        service.retire(); held.update { $0.removeAll() }
        #expect(await service.waitForCleanup().physicallySettled)
        selected.update { $0 = nil }
    }
    @Test @MainActor func correlatedControlAccountsQuicQueueAndCompletion() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let failures = NativeFixtureBox<[UInt32]>([])
        let selected = NativeFixtureBox<QuicScrcpySessionTransport?>(nil)
        let diagnostics = PrimaryMediaDiagnostics(generation: 44, sink: { _ in })
        let trace = try #require(diagnostics.received(stream: .control, bytes: 0, pts: nil, epoch: nil))
        let native = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in }, failureHandler: { _, _ in })
        let service = QuicScrcpySessionTransport(
            launch: Self.fixtureLaunch(file: file, generation: 44, scid: 1),
            native: native,
            diagnostics: diagnostics,
            callbacks: .init(
                ready: {
                    selected.value?.send(
                        ScrcpyControlMessage.text("diagnostic-control"),
                        received: QuicReceiptClock.now,
                        trace: trace
                    )
                },
                media: { _ in },
                device: { _, delivery in Task { @MainActor in delivery.deliver { true } } },
                display: { _ in },
                failure: { error in failures.update { $0.append(error.status) } }
            )
        )
        selected.update { $0 = service }
        service.start()
        try await NativeFixtures.until {
            diagnostics.snapshot(now: ProcessInfo.processInfo.systemUptime).counters[.controlProcessed] == 1
                || !failures.value.isEmpty
        }
        let active = diagnostics.snapshot(now: ProcessInfo.processInfo.systemUptime)
        #expect(failures.value.isEmpty)
        #expect(active.pending[.control] == 0)
        #expect(active.counters[.controlProcessed] == 1)
        #expect(active.histograms[.inputToDispatch]?.sampleCount == 1)
        #expect(active.histograms[.dispatchToProcessed]?.sampleCount == 1)
        service.retire()
        #expect(await service.waitForCleanup().physicallySettled)
        selected.update { $0 = nil }
    }
    @Test @MainActor func publicSessionPreservesNativeFailure() async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let session = try ScrcpySession(serial: "fixture", adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/unexercised-adb")), physicalDisplayPolicy: .leaveUnchanged,
            automaticDisplayManagement: false, quicSelection: .init(targetToken: 9),
            quicPreparedLaunch: { config, generation in Self.fixtureLaunch(file: file, generation: generation, scid: config.scid) })
        session.start(preferredCodec: .h264)
        let end = QuicReceiptClock.now + 2_000_000_000
        while session.videoSize == .zero, QuicReceiptClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        #expect(session.videoSize != .zero)
        session.nativeOwner?.attempt.fail(.codec("bounded native failure oracle"))
        try await Task.sleep(for: .milliseconds(10))
        await session.stopAndWaitForCleanup()
        #expect(session.quicRetirementOutcome?.failed == true)
        #expect(session.quicRetirementOutcome?.status == 113)
        #expect(session.nativeRetirementOutcome?.sourceFailure == .codec("bounded native failure oracle"))
    }
    private static func fixtureLaunch(file: URL, generation: UInt64, scid: UInt32, application: Bool = false,
                                      displayScenario: String? = nil, duration: UInt32 = 5000) -> QuicBackendBridge.Launch {
        .init(program: QuicBackendConsumerFixture.frozen.appendingPathComponent("gb-quic-backend-macos-arm64-qa").path,
            arguments: ["--stdio-fixture", "--fixture", file.path, "--sha256", QuicBackendConsumerFixture.hash(try! Data(contentsOf: file)), "--duration-ms", String(duration)]
                + (displayScenario.map { ["--display-scenario", $0] } ?? []),
            peerIP: "127.0.0.1", sidecarSHA: Array(repeating: 4, count: 32), generation: generation,
            targetToken: application ? 10 : 9, scid: scid, displayID: application ? UInt32.max : 0,
            captureKind: application ? 1 : 0, enabled: application ? 5 : 7)
    }
    @Test(arguments: [false, true]) @MainActor func sustainedCNativeSixtyFPSAndAAC(hevc: Bool) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: hevc, sustained: true)
        let frames = NativeFixtureBox<[Int64]>([])
        let audio = NativeFixtureBox<Int>(0)
        let failures = NativeFixtureBox<[NativeMediaFailure]>([])
        let owner = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { frame in
            frames.update { $0.append(frame.presentationTime.value) }
        }, failureHandler: { _, failure in failures.update { $0.append(failure) } })
        owner.audio.observeNativeOutput { event in if case .scheduled = event { audio.update { $0 += 1 } } }
        let recent = NativeFixtureBox<[String]>([])
        do {
            try await QuicBackendConsumerFixture.run(file: file, native: owner, seconds: 3) { item in
                recent.update {
                    if $0.count == 16 { $0.removeFirst() }
                    $0.append("track=\(item.identity.track),seq=\(item.identity.sequence),epoch=\(item.identity.epoch),cfg=\(item.identity.configuration),flags=\(item.identity.flags)")
                }
            }
        } catch {
            print("qa-sustained-terminal hevc=\(hevc) nativeFailures=\(failures.value) frames=\(frames.value.count) audio=\(audio.value) recent=\(recent.value)")
            throw error
        }
        #expect(await owner.retire().wait().succeeded)
        #expect(failures.value.isEmpty)
        let expected: [Int64] = (0..<120).map { 1_000_000 + Int64($0) * 1_000_000 / 60 }
        #expect(frames.value == expected)
        #expect(audio.value > 80)
        print("qa-sustained-complete hevc=\(hevc) frames=\(frames.value.count) audioScheduled=\(audio.value) nativeFailures=\(failures.value.count) settled=\(owner.attempt.snapshot.actuallySettled)")
    }
    @Test(arguments: [1, 2]) @MainActor func rejectedCAdmissionReleasesBorrowAndCopy(mode: Int) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: false)
        let frames = NativeFixtureBox<Int>(0)
        let owner = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in frames.update { $0 += 1 } }, failureHandler: { _, _ in })
        try await QuicBackendConsumerFixture.run(file: file, native: owner, rejection: mode) { _ in }
        #expect(await owner.retire().wait().succeeded)
        #expect(frames.value == 0)
    }
    @Test(arguments: [false, true]) @MainActor func actualCNativeRepairedFragment(hevc: Bool) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: hevc)
        let frames = NativeFixtureBox<[Int64]>([])
        let owner = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { frame in frames.update { $0.append(frame.presentationTime.value) } }, failureHandler: { _, _ in })
        try await QuicBackendConsumerFixture.run(file: file, native: owner, impairment: 1) { _ in }
        #expect(await owner.retire().wait().succeeded)
        #expect(frames.value == [1_000_000, 1_016_667, 1_033_334, 1_050_001, 1_066_668])
    }
    @Test(arguments: [false, true]) @MainActor func actualCNativeLateSourcePTSDoesNotRetireTransport(hevc: Bool) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: hevc, lateIDR: true)
        let frames = NativeFixtureBox<[Int64]>([])
        let owner = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { frame in frames.update { $0.append(frame.presentationTime.value) } }, failureHandler: { _, _ in })
        try await QuicBackendConsumerFixture.run(file: file, native: owner, impairment: 2) { _ in }
        #expect(await owner.retire().wait().succeeded)
        #expect(frames.value == [1_000_000, 1_066_668])
    }
    @Test @MainActor func sameHostReceiptAndCutoffBracketsNeverRenew() throws {
        let clock = try QuicReceiptClock(hostBefore: 100, backend: 40, hostAfter: 110)
        #expect(try clock.map(110) == 40)
        #expect(try clock.map(100) == 30)
        #expect(try clock.cutoff(200) == 260)
        #expect(throws: QuicBackendError.self) { try clock.map(1) }
    }

    @Test(arguments: [0, 1, 2]) @MainActor func actualDeviceActorGate(mode: Int) async throws {
        let callbacks = NativeFixtureBox<[(ScrcpyDeviceMessage, QuicDeviceDelivery)]>([])
        let failures = NativeFixtureBox<[UInt32]>([])
        let selected = NativeFixtureBox<QuicScrcpySessionTransport?>(nil)
        let owner = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { _ in }, failureHandler: { _, _ in })
        let launch = QuicBackendBridge.Launch(program: QuicBackendConsumerFixture.frozen.appendingPathComponent("gb-quic-backend-macos-arm64-qa").path,
            arguments: ["--test-peer-delayed-ack"], peerIP: "127.0.0.1", sidecarSHA: Array(repeating: 4, count: 32),
            generation: 1, targetToken: 9, scid: 1, displayID: 0, captureKind: 0, enabled: 6)
        let service = QuicScrcpySessionTransport(launch: launch, native: owner, callbacks: .init(
            ready: {
                var bytes = Data([9]); var sequence = UInt64(91).bigEndian
                withUnsafeBytes(of: &sequence) { bytes.append(contentsOf: $0) }
                bytes.append(contentsOf: [0, 0, 0, 0, 1, 120])
                selected.value?.send(bytes, received: QuicReceiptClock.now, trace: nil)
            }, media: { _ in }, device: { message, delivery in callbacks.update { $0.append((message, delivery)) } },
            display: { _ in }, failure: { error in failures.update { $0.append(error.status) } }))
        selected.update { $0 = service }; service.start()
        let end = QuicReceiptClock.now + 4_000_000_000
        while callbacks.value.isEmpty && failures.value.isEmpty && QuicReceiptClock.now < end {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(callbacks.value.count == 1)
        if callbacks.value.count != 1 { service.retire(); _ = await service.waitForCleanup(); return }
        var effectCount = 0
        if mode == 0 {
            callbacks.value[0].1.deliver { effectCount += 1; return true }
            callbacks.value[0].1.deliver { effectCount += 100; return true }
            #expect(effectCount == 1)
            callbacks.update { $0.removeAll() }
            service.retire()
            #expect(await service.waitForCleanup().physicallySettled)
        } else {
            if mode == 1 {
                // Exact equality on the REAL exported original cutoff, before
                // dispatching the held callback through its production gate.
                let gate = callbacks.value[0].1
                #expect(gate.status(now: gate.originalCutoff).failure == 112)
            }
            let expiryEnd = QuicReceiptClock.now + 3_000_000_000
            while owner.attempt.isAdmitted && QuicReceiptClock.now < expiryEnd { try await Task.sleep(for: .milliseconds(1)) }
            #expect(!owner.attempt.isAdmitted)
            if owner.attempt.isAdmitted { service.retire() }
            let observed = NativeFixtureBox<ScrcpyTransportSettlement?>(nil)
            Task { let result = await service.waitForCleanup(); observed.update { $0 = result } }
            let publicationEnd = QuicReceiptClock.now + 5_500_000_000
            while observed.value == nil && QuicReceiptClock.now < publicationEnd { try await Task.sleep(for: .milliseconds(1)) }
            #expect(observed.value?.failed == true && observed.value?.physicallySettled == false && observed.value?.status == 112)
            #expect(owner.attempt.snapshot.actuallySettled)
            #expect(!service.physicallySettled)
            #expect(!owner.attempt.isAdmitted)
            callbacks.value[0].1.deliver { effectCount += 1; return true }
            #expect(effectCount == 0)
            callbacks.update { $0.removeAll() }
            let finalEnd = QuicReceiptClock.now + 2_000_000_000
            while !service.physicallySettled && QuicReceiptClock.now < finalEnd { try await Task.sleep(for: .milliseconds(1)) }
            #expect(service.physicallySettled)
        }
        selected.update { $0 = nil }
    }
    @Test(arguments: [false, true]) @MainActor func actualCNativeOutput(hevc: Bool) async throws {
        let file = try QuicBackendConsumerFixture.prepared(hevc: hevc)
        let movie = file.deletingPathExtension().appendingPathExtension("\(UUID().uuidString).mov")
        let recorderQueue = DispatchQueue(label: "quic.actual-c-recorder")
        let recorder = try ScreenRecorder(outputURL: movie, width: 64, height: 64, workQueue: recorderQueue)
        let finalReferences = NativeFixtureBox<[NativeDecodedFrame]>([])
        let frames = NativeFixtureBox<[Int64]>([])
        let audio = NativeFixtureBox<[NativeAudioOutputEvent]>([])
        let media = NativeFixtureBox<[(UInt32, UInt64, UInt64)]>([])
        let failures = NativeFixtureBox<[NativeMediaFailure]>([])
        let owner = ScrcpyNativeMediaOwner(id: .init(), binding: NativeFrameBinding { frame in
            frames.update { $0.append(frame.presentationTime.value) }
            finalReferences.update { $0.append(frame) }
            recorder.append(frame.pixelBuffer, presentationTime: frame.presentationTime)
        }, failureHandler: { _, failure in failures.update { $0.append(failure) } })
        defer {
            finalReferences.update { $0.removeAll() }
            recorder.finish { _ in }
            owner.retire()
        }
        owner.audio.observeNativeOutput { event in audio.update { $0.append(event) } }
        try await QuicBackendConsumerFixture.run(file: file, native: owner) { admitted in
            if case let .packet(packet) = admitted.work.event, !packet.isConfiguration {
                media.update { $0.append((admitted.identity.track, admitted.identity.sequence, packet.presentationTimeUs ?? 0)) }
            }
        }
        // Keep the real decoded output/job allocations until the actual recording
        // sink has finalized, rather than retiring them on append/queue pop.
        let recorded: Result<URL, Error> = await withCheckedContinuation { continuation in
            recorder.finish { continuation.resume(returning: $0) }
        }
        _ = try recorded.get()
        finalReferences.update { $0.removeAll() }
        #expect(await owner.retire().wait().succeeded)
        #expect(failures.value.isEmpty)
        #expect(frames.value == [1_000_000, 1_016_667, 1_033_334, 1_050_001, 1_066_668])
        #expect(media.value.filter { $0.0 == 1 }.map { $0.1 } == [1, 2, 3, 4, 5])
        #expect(media.value.filter { $0.0 == 1 }.map { $0.2 } == [1_000_000, 1_016_667, 1_033_334, 1_050_001, 1_066_668])
        #expect(audio.value.contains { if case let .converted(count) = $0 { return count > 0 }; return false })
        #expect(audio.value.contains { if case .scheduled = $0 { return true }; return false })
        let asset = AVURLAsset(url: movie)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let movieTimescale = try await track.load(.naturalTimeScale)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        #expect(reader.canAdd(output)); reader.add(output); #expect(reader.startReading())
        var moviePTS: [Int64] = []
        while let sample = output.copyNextSampleBuffer() {
            #expect(moviePTS.count < 5)
            moviePTS.append(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default).value)
        }
        #expect(reader.status == .completed)
        // AVAssetWriter selects the MOV track timebase. Compare exact rational
        // conversion into that timebase, not repeated rounding of frame deltas.
        #expect(moviePTS.count == 5 && movieTimescale > 0)
        let quantizedPTS = [Int64(0), 16_667, 33_334, 50_001, 66_668].map {
            CMTimeConvertScale(CMTimeConvertScale(CMTime(value: $0, timescale: 1_000_000), timescale: movieTimescale, method: .default), timescale: 1_000_000, method: .default).value
        }
        #expect(moviePTS == quantizedPTS)
        print("qa-c-native-movie codec=\(hevc ? "hevc" : "h264") frames=\(moviePTS.count) timebase=\(movieTimescale) pts=\(moviePTS) file=\(movie.lastPathComponent)")
    }
}
#endif
