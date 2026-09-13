import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore
import Testing
import VideoToolbox
@testable import GalaxyBridgeMac

@Suite(.serialized)
struct VideoFrameRecoveryTests {
    @Test func rememberedQuicChoiceIsInternalOnlyAndDoesNotPersistQAOverrides() throws {
        let remembered = QuicRuntimeArtifacts.effectiveProcessArguments(processArguments: [],
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal", preferQuic: true)
        #expect(remembered == ["--experimental-quic-wireless"])
        #expect(QuicRuntimeArtifacts.isExplicitlyEnabled(processArguments: remembered,
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal"))
        for identifier in ["com.xopmc.GalaxyBridge", "com.xopmc.GalaxyBridge.store"] {
            #expect(QuicRuntimeArtifacts.effectiveProcessArguments(processArguments: [],
                bundleIdentifier: identifier, preferQuic: true).isEmpty)
        }
        #expect(QuicRuntimeArtifacts.effectiveProcessArguments(processArguments: [],
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal", preferQuic: false).isEmpty)
        #expect(QuicRuntimeArtifacts.effectiveProcessArguments(processArguments: remembered,
            bundleIdentifier: "com.xopmc.GalaxyBridge.internal", preferQuic: true) == remembered)
    }
    @Test(arguments: [kVTVideoDecoderBadDataErr, kVTVideoDecoderReferenceMissingErr])
    func corruptedFrameKeepsOwnerAndResumesOnRealIDR(status: OSStatus) async throws {
        let fixture = try QuicCodecFixtureFactory.video(hevc: false)
        let events = try NativeFixtures.videoEvents(fixture)
        let attempt = NativeMediaAttempt()
        let errors = NativeFixtureCount()
        let shown = NativeFixtureBox<[Int64]>([])
        let queue = DispatchQueue(label: "frame-recovery.decode")
        let playout = DispatchQueue(label: "frame-recovery.playout")
        let decoder = VideoToolboxDecoder(immediateVideoPlayout: true, recoverCorruptFrames: true,
            queue: queue, playoutQueue: playout, nativeAttempt: attempt,
            ownedFrameHandler: { frame in shown.update { $0.append(frame.presentationTime.value) } },
            frameHandler: { _, _, _ in }, failureHandler: { _ in errors.increment(); attempt.fail(.codec("fixture")) })
        events.prefix(4).forEach { decoder.consume($0) }
        try await NativeFixtures.until { shown.value.count == 1 }
        // Inject the actual OS-status boundary, not a fake successful decoder.
        // The replacement below still traverses native VideoToolbox decoding.
        decoder.handleDecodeFailure(status)
        #expect(attempt.isAdmitted && errors.value == 0)
        decoder.consume(events[4]) // Dependent frame cannot repair a broken chain.
        decoder.consume(events[7]) // Fixture's second independent frame.
        queue.sync {}; playout.sync {}
        #expect(shown.value == [Int64(fixture.packets[0].pts), Int64(fixture.packets[4].pts)])
        #expect(errors.value == 0 && attempt.isAdmitted)
        #expect(await attempt.retire().wait().succeeded)
        withExtendedLifetime(decoder) {}
    }

    @Test func strictConsumersAndOtherErrorsRemainFatal() {
        for (enabled, status) in [(false, kVTVideoDecoderBadDataErr),
                                  (true, kVTAllocationFailedErr),
                                  (true, kVTVideoDecoderMalfunctionErr)] {
            let errors = NativeFixtureCount()
            let decoder = VideoToolboxDecoder(recoverCorruptFrames: enabled,
                frameHandler: { _, _, _ in }, failureHandler: { _ in errors.increment() })
            decoder.handleDecodeFailure(status)
            #expect(errors.value == 1)
        }
    }

    @Test func lateDeltaErrorCannotInvalidateSuccessfulIDR() {
        let errors = NativeFixtureCount()
        let decoder = VideoToolboxDecoder(recoverCorruptFrames: true,
            frameHandler: { _, _, _ in }, failureHandler: { _ in errors.increment() })
        // Callback ordering while a newer IDR is being drained.
        decoder.handleDecodeFailure(kVTVideoDecoderBadDataErr, generation: 0, sequence: 2)
        #expect(decoder.hasPendingFrameRecovery)
        decoder.decodedKeyFrame(sequence: 3, generation: 0)
        #expect(!decoder.hasPendingFrameRecovery)
        decoder.handleDecodeFailure(kVTVideoDecoderBadDataErr, generation: 0, sequence: 2)
        #expect(!decoder.hasPendingFrameRecovery)
        // Never hide an error of the IDR itself or of its successor.
        decoder.handleDecodeFailure(kVTVideoDecoderBadDataErr, generation: 0, sequence: 3)
        decoder.decodedKeyFrame(sequence: 3, generation: 0)
        #expect(decoder.hasPendingFrameRecovery)
        decoder.decodedKeyFrame(sequence: 4, generation: 0)
        #expect(!decoder.hasPendingFrameRecovery)
        decoder.handleDecodeFailure(kVTVideoDecoderReferenceMissingErr, generation: 0, sequence: 5)
        decoder.decodedKeyFrame(sequence: 4, generation: 0)
        #expect(decoder.hasPendingFrameRecovery && errors.value == 0)
        // Obsolete decoder generations cannot repair or invalidate this one.
        decoder.decodedKeyFrame(sequence: 6, generation: 99)
        #expect(decoder.hasPendingFrameRecovery)
    }
}
