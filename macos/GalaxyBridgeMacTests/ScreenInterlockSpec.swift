import Foundation

private enum SpecFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message): message
        }
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw SpecFailure.message("\(message): expected \(expected), got \(actual)")
    }
}

@main
private enum ScreenInterlockSpec {
    static func main() throws {
        try interactiveBlackoutWakesAnAlreadySleepingSamsung()
        try interactiveBlackoutHonorsPhysicalPowerButtonTransitions()
        try autoOffWaitsForBothControlAndFirstDecodedFrame()
        try initialPowerOffFailureUsesOneShellFallback()
        try physicalWakeBlocksAndRelockResumesWithoutAnotherPowerCommand()
        try stoppingEndsMonitoringAndResetsPresentation()
        try physicalDisplayProbePrefersTheBuiltInDisplay()
        try physicalWakeUsesAnExplicitTopLevelPlaceholder()
        try mediaUnavailablePreservesSafetyPrecedence()
        try transientMediaRecoveryKeepsTheLastCompatibleFrame()
        print("PASS screen interlock state, power policy, and physical display probe")
    }

    private static func interactiveBlackoutWakesAnAlreadySleepingSamsung() throws {
        var interlock = InteractiveDisplayBlackoutStateMachine()

        try expectEqual(interlock.handle(.firstFrame), [], "a frame alone must not change phone power")
        try expectEqual(
            interlock.handle(.controlReady),
            [.applyInteractiveBlackout, .startPhysicalDisplayMonitoring],
            "the production interlock must use the interactive blackout path"
        )
        try expectEqual(interlock.presentation, .mirroring, "interactive blackout keeps the stream visible")
        try expectEqual(interlock.handle(.controlReady), [], "interactive blackout starts only once")
    }

    private static func interactiveBlackoutHonorsPhysicalPowerButtonTransitions() throws {
        var interlock = InteractiveDisplayBlackoutStateMachine()
        _ = interlock.handle(.controlReady)
        _ = interlock.handle(.firstFrame)

        try expectEqual(
            interlock.handle(.physicalDisplayChanged(.off)),
            [.revealPhysicalDisplay],
            "a physical power press while blacked out reveals the phone"
        )
        try expectEqual(
            interlock.presentation,
            .physicalDeviceActive,
            "the Mac blocks mirrored input while the physical phone is active"
        )
        try expectEqual(interlock.handle(.physicalDisplayChanged(.on)), [], "the reveal acknowledgement is quiet")
        try expectEqual(
            interlock.handle(.physicalDisplayChanged(.off)),
            [.applyInteractiveBlackout],
            "locking the phone again resumes an interactive blackout"
        )
        try expectEqual(interlock.presentation, .mirroring, "relocking resumes the existing stream")

        try expectEqual(
            interlock.handle(.stopped),
            [.restorePhysicalDisplay, .stopPhysicalDisplayMonitoring],
            "stopping restores brightness and ends display polling"
        )
    }

    private static func initialPowerOffFailureUsesOneShellFallback() throws {
        var interlock = ScreenInterlockStateMachine()
        _ = interlock.handle(.controlReady)
        _ = interlock.handle(.firstFrame)

        try expectEqual(
            interlock.handle(.physicalDisplayChanged(.on)),
            [.forcePhysicalDisplayPowerOff],
            "an OEM which ignores scrcpy power control gets one Android 15 display-command fallback"
        )
        try expectEqual(
            interlock.handle(.physicalDisplayChanged(.on)),
            [],
            "polling an initially awake display must not create a command loop"
        )
        try expectEqual(interlock.handle(.physicalDisplayChanged(.off)), [], "confirmed off ends initial fallback")
        try expectEqual(
            interlock.handle(.physicalDisplayChanged(.on)),
            [],
            "a later physical power-button wake remains blocked until the user turns the phone off"
        )
    }

    private static func autoOffWaitsForBothControlAndFirstDecodedFrame() throws {
        var interlock = ScreenInterlockStateMachine()

        try expectEqual(interlock.handle(.firstFrame), [], "first frame alone must not send power control")
        try expectEqual(interlock.presentation, .mirroring, "first decoded frame is immediately presentable")
        try expectEqual(
            interlock.handle(.controlReady),
            [.setPhysicalDisplayPowerOff, .startPhysicalDisplayMonitoring],
            "control readiness after the first frame starts privacy mode exactly once"
        )
        try expectEqual(interlock.handle(.controlReady), [], "duplicate readiness must not repeat power control")
        try expectEqual(interlock.handle(.firstFrame), [], "later decoded frames must not repeat power control")

        var reverseOrder = ScreenInterlockStateMachine()
        try expectEqual(reverseOrder.handle(.controlReady), [], "control alone must wait for a decoded frame")
        try expectEqual(
            reverseOrder.handle(.firstFrame),
            [.setPhysicalDisplayPowerOff, .startPhysicalDisplayMonitoring],
            "the readiness order must not matter"
        )
    }

    private static func physicalWakeBlocksAndRelockResumesWithoutAnotherPowerCommand() throws {
        var interlock = ScreenInterlockStateMachine()
        _ = interlock.handle(.controlReady)
        _ = interlock.handle(.firstFrame)

        try expectEqual(interlock.handle(.physicalDisplayChanged(.off)), [], "confirmed screen-off has no new command")
        try expectEqual(interlock.presentation, .mirroring, "screen-off keeps the mirror visible")
        try expectEqual(interlock.handle(.physicalDisplayChanged(.on)), [], "physical wake never simulates an unlock")
        try expectEqual(
            interlock.presentation,
            .physicalDeviceActive,
            "physical wake must replace the mirror with the lock instruction"
        )
        try expectEqual(interlock.handle(.physicalDisplayChanged(.off)), [], "relocking needs no second power command")
        try expectEqual(interlock.presentation, .mirroring, "relocking resumes the existing mirror")
    }

    private static func stoppingEndsMonitoringAndResetsPresentation() throws {
        var interlock = ScreenInterlockStateMachine()
        _ = interlock.handle(.controlReady)
        _ = interlock.handle(.firstFrame)
        _ = interlock.handle(.physicalDisplayChanged(.on))

        try expectEqual(interlock.handle(.stopped), [.stopPhysicalDisplayMonitoring], "stop must end polling")
        try expectEqual(interlock.presentation, .waitingForFirstFrame, "stopped session resets its presentation")
        try expectEqual(interlock.handle(.stopped), [], "repeated stop is idempotent")
    }

    private static func physicalDisplayProbePrefersTheBuiltInDisplay() throws {
        let physicalOffWithVirtualOn = """
            DisplayDeviceInfo{"Galaxy Virtual Display": 1920 x 1080, type VIRTUAL, state ON}
            DisplayDeviceInfo{"Built-in Screen": 1440 x 3120, type INTERNAL, state OFF, FLAG_ALLOWED_TO_BE_DEFAULT_DISPLAY}
            """
        try expectEqual(
            PhysicalDisplayProbeParser.parse(physicalOffWithVirtualOn),
            .off,
            "a virtual display must not make an off phone appear awake"
        )
        try expectEqual(
            PhysicalDisplayProbeParser.parse("Display Power: state=ON\nmScreenState=ON"),
            .on,
            "power-controller fallback should detect an illuminated display"
        )
        try expectEqual(
            PhysicalDisplayProbeParser.parse("mScreenState=DOZE"),
            .on,
            "ambient/doze is still physically visible and must interlock"
        )
        try expectEqual(
            PhysicalDisplayProbeParser.parse("DisplayDeviceInfo{type EXTERNAL, state ON}"),
            .unknown,
            "external-only output cannot establish phone display state"
        )
        try expectEqual(
            PhysicalDisplayProbeParser.parse("  mWakefulness=Awake"),
            .on,
            "the bounded power probe must recognize an interactive phone"
        )
        try expectEqual(
            PhysicalDisplayProbeParser.parse("  mWakefulness=Dozing"),
            .off,
            "the bounded power probe must recognize a sleeping phone"
        )
    }

    private static func physicalWakeUsesAnExplicitTopLevelPlaceholder() throws {
        try expectEqual(
            ScreenStreamPlaceholderResolver.resolve(
                deviceReady: true,
                hasFrame: true,
                screenCapabilityUnavailableReason: nil,
                physicalDeviceActive: true
            ),
            .physicalDeviceActive,
            "physical wake must replace a valid frame with the lock instruction"
        )
        try expectEqual(
            ScreenStreamPlaceholderResolver.resolve(
                deviceReady: true,
                hasFrame: true,
                screenCapabilityUnavailableReason: nil,
                physicalDeviceActive: false
            ),
            nil,
            "screen-off must reveal the existing mirror again"
        )
    }
    private static func mediaUnavailablePreservesSafetyPrecedence() throws {
        func resolve(_ ready:Bool=true,_ physical:Bool=false,_ capability:String?=nil,_ protected:Bool=false,_ media:Bool=true)->ScreenStreamPlaceholder? {
            ScreenStreamPlaceholderResolver.resolve(deviceReady:ready,hasFrame:true,screenCapabilityUnavailableReason:capability,
                protectedContentSuspected:protected,physicalDeviceActive:physical,mediaUnavailable:media)
        }
        try expectEqual(resolve(),.mediaUnavailable,"stale pixels must be explicitly unavailable")
        try expectEqual(resolve(false),.deviceUnavailable,"device readiness wins")
        try expectEqual(resolve(true,true),.physicalDeviceActive,"physical interlock wins")
        try expectEqual(resolve(true,false,"media_projection_consent_required"),.mediaProjectionConsentRequired,"permission wins")
        try expectEqual(resolve(true,false,nil,true),.protectedContent,"protected content wins")
        try expectEqual(resolve(true,false,nil,false,false),nil,"default-off media override preserves existing frame")
    }

    private static func transientMediaRecoveryKeepsTheLastCompatibleFrame() throws {
        func unavailable(
            _ state: UInt32,
            _ reason: UInt32 = 0,
            frameEpoch: UInt32? = 7,
            frameConfiguration: UInt32? = 3
        ) -> Bool {
            ScreenStreamMediaAvailabilityPolicy.isUnavailable(
                healthState: state,
                healthReason: reason,
                healthEpoch: 7,
                healthConfiguration: 3,
                frameEpoch: frameEpoch,
                frameConfiguration: frameConfiguration
            )
        }

        try expectEqual(unavailable(1), false, "healthy media keeps the current frame")
        try expectEqual(unavailable(2), false, "bounded recovery keeps the last compatible frame")
        try expectEqual(unavailable(3, 3), false, "temporary output pressure keeps the last compatible frame")
        try expectEqual(
            unavailable(3, 5),
            false,
            "exhausted recovery keeps the last compatible frame on a static Android display"
        )
        try expectEqual(unavailable(4), true, "a disabled stream is unavailable")
        try expectEqual(unavailable(2, frameEpoch: 6), true, "an old display epoch is unavailable")
        try expectEqual(unavailable(2, frameConfiguration: nil), true, "absence of a decoded frame is unavailable")
    }
}
