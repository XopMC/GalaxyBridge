import Foundation

@main
private enum MediaTransportArbitrationSpec {
    static func main() throws {
        try companionFeedsMediaUntilEnhancedActuallyStreams()
        try enhancedStreamingExclusivelyOwnsScreenAndAudio()
        try companionImmediatelyResumesAfterEnhancedFailure()
        try screenLifecycleKeepsADBRouteAvailable()
        try independentScrcpyOwnersNeverRequestGlobalCleanup()
        try rejectedCompanionPacketsNeverReachTheMainActor()
        try fallbackRequestsReferenceChainExactlyOnce()
        print("PASS media transport arbitration prevents competing ADB and LAN decoders")
    }

    private static func companionFeedsMediaUntilEnhancedActuallyStreams() throws {
        for state: ScrcpySessionState? in [nil, .idle, .preparing, .connecting] {
            try expect(
                MediaTransportArbitrationPolicy.preferredSource(enhancedState: state) == .companion,
                "LAN must remain presentable before enhanced has a decoded video session"
            )
            try expect(
                MediaTransportArbitrationPolicy.shouldAccept(.companion, enhancedState: state),
                "LAN packets must keep fallback visible while enhanced connects"
            )
        }
    }

    private static func enhancedStreamingExclusivelyOwnsScreenAndAudio() throws {
        let state = ScrcpySessionState.streaming("Galaxy")
        try expect(
            MediaTransportArbitrationPolicy.preferredSource(enhancedState: state) == .enhanced,
            "USB or Wireless ADB must win once scrcpy is streaming"
        )
        try expect(
            MediaTransportArbitrationPolicy.shouldAccept(.enhanced, enhancedState: state),
            "the preferred enhanced stream must be accepted"
        )
        try expect(
            !MediaTransportArbitrationPolicy.shouldAccept(.companion, enhancedState: state),
            "LAN video and audio must not race the enhanced stream on the shared surface"
        )
    }

    private static func companionImmediatelyResumesAfterEnhancedFailure() throws {
        for state in [ScrcpySessionState.failed("reset"), .stopped] {
            try expect(
                MediaTransportArbitrationPolicy.preferredSource(enhancedState: state) == .companion,
                "LAN must become primary as soon as enhanced fails or stops"
            )
            try expect(
                MediaTransportArbitrationPolicy.shouldAccept(.companion, enhancedState: state),
                "fallback packets must be accepted without restarting the Android projection"
            )
        }
    }

    private static func screenLifecycleKeepsADBRouteAvailable() throws {
        for state: ScrcpySessionState? in [
            nil,
            .idle,
            .preparing,
            .connecting,
            .streaming("Galaxy"),
            .failed("transport reset"),
            .stopped,
        ] {
            try expect(
                !EnhancedADBRouteAvailabilityPolicy.blocksRoute(for: state),
                "screen lifecycle must not change the availability of an independently connected ADB route"
            )
        }
    }

    private static func independentScrcpyOwnersNeverRequestGlobalCleanup() throws {
        try expect(
            !ScrcpySharedResourceOwnershipPolicy.serverCleanupEnabled,
            "retiring one screen owner must not clean up the capture-free clipboard owner"
        )
    }

    private static func fallbackRequestsReferenceChainExactlyOnce() throws {
        let gate = MediaTransportDispatchGate(enhancedState: nil)
        try expect(!gate.update(enhancedState: .connecting), "initial LAN session already has its bootstrap")
        try expect(!gate.update(enhancedState: .streaming("Galaxy")), "enhanced takeover does not restart LAN")
        try expect(gate.update(enhancedState: .failed("offline")), "discarded LAN reference frames require a fresh bootstrap")
        try expect(!gate.update(enhancedState: .preparing), "fallback retries must not repeatedly reconnect LAN")
        try expect(!gate.update(enhancedState: .failed("offline")), "only an actual enhanced-to-LAN transition triggers recovery")
    }

    private static func rejectedCompanionPacketsNeverReachTheMainActor() throws {
        let gate = MediaTransportDispatchGate(enhancedState: .streaming("Galaxy"))
        var scheduledPackets = 0
        for _ in 0 ..< 10_000 {
            if gate.shouldDispatch(.companion, isConfiguration: false) {
                scheduledPackets += 1
            }
        }
        try expect(
            scheduledPackets == 0,
            "discarded LAN packets must be rejected before creating MainActor tasks"
        )
        try expect(
            gate.shouldDispatch(.companion, isConfiguration: true),
            "the sparse codec configuration must remain warm while enhanced owns presentation"
        )

        gate.update(enhancedState: .failed("reset"))
        try expect(
            gate.shouldDispatch(.companion, isConfiguration: false),
            "the same bounded gate must reopen synchronously when enhanced fails"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message) }
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
