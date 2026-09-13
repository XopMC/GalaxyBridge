import GalaxyBridgeBuildPins
import Foundation
import GalaxyBridgeCore

/// Enhanced-only scrcpy server launch contract.
///
/// Keep this in its own SwiftPM/Xcode product so the Mac App Store target can
/// omit the implementation physically instead of relying only on dead-code
/// stripping or a caller-side compilation condition.
public struct ScrcpyLaunchConfiguration: Equatable, Sendable {
    public static let serverVersion = "4.1"
    public static let serverSHA256Hex = GalaxyBridgeBuildPins.scrcpySHA
    public static let remoteServerPath = "/data/local/tmp/scrcpy-server.jar"

    public let scid: UInt32
    public let videoCodec: ScrcpyCodec
    public let maxSize: UInt16
    public let maxFPS: UInt16
    public let videoBitRate: UInt32
    public let videoKeyFrameIntervalSeconds: UInt16?
    public let videoCodecRealtimePriority: Bool
    public let videoCodecZeroFrameLatency: Bool
    public let videoCodecOperatingRate: UInt16?
    public let videoCodecRepeatPreviousFrameAfterMicroseconds: UInt32?
    public let videoCodecConstantBitRate: Bool
    public let videoCodecFastestComplexity: Bool
    public let videoCodecBaselineProfile: Bool
    public let videoEnabled: Bool
    public let audioBitRate: UInt32
    public let audioEnabled: Bool
    public let sendDeviceMeta: Bool
    public let keepActive: Bool
    public let hideDeviceIME: Bool
    public let uhidKeyboardEnabled: Bool
    public let tunnelForward: Bool
    public let captureTarget: ScrcpyCaptureTarget
    public let applicationTarget: ScrcpyApplicationTarget?
    public let cleanup: Bool

    public init(
        scid: UInt32,
        videoCodec: ScrcpyCodec = .h265,
        maxSize: UInt16 = 2_560,
        maxFPS: UInt16 = 60,
        videoBitRate: UInt32 = 20_000_000,
        videoKeyFrameIntervalSeconds: UInt16? = nil,
        videoCodecRealtimePriority: Bool = false,
        videoCodecZeroFrameLatency: Bool = false,
        videoCodecOperatingRate: UInt16? = nil,
        videoCodecRepeatPreviousFrameAfterMicroseconds: UInt32? = nil,
        videoCodecConstantBitRate: Bool = false,
        videoCodecFastestComplexity: Bool = false,
        videoCodecBaselineProfile: Bool = false,
        videoEnabled: Bool = true,
        audioBitRate: UInt32 = 128_000,
        audioEnabled: Bool? = nil,
        sendDeviceMeta: Bool = true,
        keepActive: Bool = true,
        hideDeviceIME: Bool = true,
        uhidKeyboardEnabled: Bool = true,
        tunnelForward: Bool = true,
        captureTarget: ScrcpyCaptureTarget = .display(id: 0),
        applicationTarget: ScrcpyApplicationTarget? = nil,
        cleanup: Bool = true
    ) {
        precondition(scid <= 0x7FFF_FFFF)
        precondition(videoCodec == .h264 || videoCodec == .h265)
        self.scid = scid
        self.videoCodec = videoCodec
        self.maxSize = maxSize
        self.maxFPS = maxFPS
        self.videoBitRate = videoBitRate
        self.videoKeyFrameIntervalSeconds = videoKeyFrameIntervalSeconds
        self.videoCodecRealtimePriority = videoCodecRealtimePriority
        self.videoCodecZeroFrameLatency = videoCodecZeroFrameLatency
        self.videoCodecOperatingRate = videoCodecOperatingRate
        self.videoCodecRepeatPreviousFrameAfterMicroseconds = videoCodecRepeatPreviousFrameAfterMicroseconds
        self.videoCodecConstantBitRate = videoCodecConstantBitRate
        self.videoCodecFastestComplexity = videoCodecFastestComplexity
        self.videoCodecBaselineProfile = videoCodecBaselineProfile
        self.videoEnabled = videoEnabled
        self.audioBitRate = audioBitRate
        self.audioEnabled = audioEnabled ?? (applicationTarget == nil)
        self.sendDeviceMeta = sendDeviceMeta
        self.keepActive = keepActive
        self.hideDeviceIME = hideDeviceIME
        self.uhidKeyboardEnabled = uhidKeyboardEnabled
        self.tunnelForward = tunnelForward
        self.captureTarget = captureTarget
        self.applicationTarget = applicationTarget
        self.cleanup = cleanup
    }

    public var socketName: String { String(format: "scrcpy_%08x", scid) }

    /// Messages which must be delivered only after the control socket is
    /// connected. In scrcpy 4.1 app launch is a type-16 control message, not a
    /// server option; the server then waits for the new virtual display id.
    public var initialControlMessages: [Data] {
        var messages = uhidKeyboardEnabled ? [ScrcpyUHIDKeyboard.createMessage] : []
        if let applicationTarget {
            messages.append(ScrcpyControlMessage.startApp(applicationTarget.packageName))
        }
        return messages
    }

    public var serverArguments: [String] {
        var arguments = [
            "shell",
            "CLASSPATH=\(Self.remoteServerPath)",
            "app_process",
            "/",
            "com.genymobile.scrcpy.Server",
            Self.serverVersion,
            String(format: "scid=%08x", scid),
            "log_level=info",
            "tunnel_forward=\(tunnelForward ? "true" : "false")",
            "send_device_meta=\(sendDeviceMeta ? "true" : "false")",
            "send_stream_meta=true",
            "send_frame_meta=true",
            // One UI may omit clipboard-listener callbacks for apps hosted on
            // a virtual display. Explicit bounded polling keeps enhanced
            // Android→Mac clipboard sync deterministic instead.
            "clipboard_autosync=false",
            "cleanup=\(cleanup ? "true" : "false")",
            // Do not wake a locked phone while the server starts. Galaxy Bridge
            // switches only the physical display off after the first decoded
            // frame; scrcpy cleanup restores it when the session finishes.
            "power_on=false",
            // scrcpy 4.1 signals user activity on the action display every four
            // seconds. This prevents Android's inactivity timeout from locking
            // an otherwise interactive mirror without changing global timeout
            // settings or bypassing an already-present keyguard.
        ]
        if videoEnabled {
            arguments.append("video_bit_rate=\(videoBitRate)")
            arguments.append("video_codec=\(videoCodec == .h265 ? "h265" : "h264")")
            arguments.append("max_size=\(maxSize)")
            arguments.append("max_fps=\(maxFPS)")
            var videoCodecOptions: [String] = []
            if let videoKeyFrameIntervalSeconds {
                videoCodecOptions.append("i-frame-interval=\(videoKeyFrameIntervalSeconds)")
            }
            if videoCodecRealtimePriority {
                // Android MediaFormat priority 0 requests real-time resource
                // planning for interactive capture.
                videoCodecOptions.append("priority=0")
            }
            if videoCodecZeroFrameLatency {
                // MediaFormat latency is an optional video-encoder request in
                // frames. Supported Galaxy encoders accept zero without a
                // capture-session recreation.
                videoCodecOptions.append("latency=0")
            }
            if let videoCodecOperatingRate {
                // MediaFormat.KEY_OPERATING_RATE selects the codec operating
                // point used for resource planning. This is an Internal-only
                // experiment until the static-input hardware gate passes.
                videoCodecOptions.append("operating-rate=\(videoCodecOperatingRate)")
            }
            if let videoCodecRepeatPreviousFrameAfterMicroseconds {
                // scrcpy defaults this surface-input wake-up to 100 ms. The
                // explicit long type matches MediaFormat and lets Internal QA
                // test a shorter static-screen response interval safely.
                videoCodecOptions.append(
                    "repeat-previous-frame-after:long=\(videoCodecRepeatPreviousFrameAfterMicroseconds)"
                )
            }
            if videoCodecConstantBitRate {
                // MediaCodecInfo confirms the selected Galaxy H.264 hardware
                // encoder supports CBR. Keep the request explicitly gated
                // while its motion behavior is compared with the VBR default.
                videoCodecOptions.append("bitrate-mode=2")
            }
            if videoCodecFastestComplexity {
                // The selected hardware codec reports a 0...100 range and a
                // default of 100. The zero request trades encoder tools for
                // lower frame latency while the configured bitrate is kept.
                videoCodecOptions.append("complexity=0")
            }
            if videoCodecBaselineProfile {
                // AVC baseline is explicitly advertised by the active Galaxy
                // hardware encoder. It disables higher-complexity coding tools
                // while remaining natively decodable by VideoToolbox.
                videoCodecOptions.append("profile=1")
            }
            if !videoCodecOptions.isEmpty {
                arguments.append("video_codec_options=\(videoCodecOptions.joined(separator: ","))")
            }
        } else {
            arguments.append("video=false")
        }
        if audioEnabled {
            arguments.append("audio_bit_rate=\(audioBitRate)")
            arguments.append("audio_codec=aac")
        } else {
            arguments.append("audio=false")
        }
        arguments.append("keep_active=\(keepActive ? "true" : "false")")
        // The Mac already provides the physical keyboard and a complete
        // NSTextInputClient bridge. A capture-free clipboard helper deliberately
        // leaves the user's current IME policy untouched.
        if hideDeviceIME { arguments.append("display_ime_policy=hide") }
        switch captureTarget {
        case let .display(id):
            if id != 0 { arguments.append("display_id=\(id)") }
        case let .virtualDisplay(width, height, dpi):
            let density = dpi.map { "/\($0)" } ?? ""
            arguments.append("new_display=\(width)x\(height)\(density)")
            arguments.append("vd_destroy_content=true")
            // An app window owns its content. Starting a second Android
            // launcher/taskbar can cover the requested activity on One UI.
            // A general-purpose virtual desktop still needs those controls.
            arguments.append("vd_system_decorations=\(applicationTarget == nil ? "true" : "false")")
            if applicationTarget != nil {
                arguments.append("flex_display=true")
            }
        }
        return arguments
    }
}
