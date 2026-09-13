import Foundation
import GalaxyBridgeCore

/// Release launch limits for stock scrcpy 4.1 sessions.
///
/// Wireless ADB uses one deliberately bounded, model-independent profile. USB
/// keeps the existing high-quality defaults.
public struct ScrcpyLaunchProfile: Equatable, Sendable {
    public let maxSize: UInt16
    public let maxFPS: UInt16
    public let videoBitRate: UInt32
    public let videoKeyFrameIntervalSeconds: UInt16?
    public let videoCodecRealtimePriority: Bool
    public let videoCodecZeroFrameLatency: Bool
    public let videoCodecConstantBitRate: Bool
    public let videoCodecFastestComplexity: Bool
    public let immediateVideoDelivery: Bool

    public init(
        maxSize: UInt16,
        maxFPS: UInt16,
        videoBitRate: UInt32,
        videoKeyFrameIntervalSeconds: UInt16?,
        videoCodecRealtimePriority: Bool = false,
        videoCodecZeroFrameLatency: Bool = false,
        videoCodecConstantBitRate: Bool = false,
        videoCodecFastestComplexity: Bool = false,
        immediateVideoDelivery: Bool = false
    ) {
        self.maxSize = maxSize
        self.maxFPS = maxFPS
        self.videoBitRate = videoBitRate
        self.videoKeyFrameIntervalSeconds = videoKeyFrameIntervalSeconds
        self.videoCodecRealtimePriority = videoCodecRealtimePriority
        self.videoCodecZeroFrameLatency = videoCodecZeroFrameLatency
        self.videoCodecConstantBitRate = videoCodecConstantBitRate
        self.videoCodecFastestComplexity = videoCodecFastestComplexity
        self.immediateVideoDelivery = immediateVideoDelivery
    }

    public static let usb = ScrcpyLaunchProfile(
        maxSize: 2_560,
        maxFPS: 60,
        videoBitRate: 20_000_000,
        videoKeyFrameIntervalSeconds: nil
    )

    public static func wirelessADB(codec: ScrcpyCodec) -> ScrcpyLaunchProfile {
        ScrcpyLaunchProfile(
            maxSize: 1_920,
            maxFPS: 60,
            // Shared initial limits, not a certification of every encoder.
            // Wi-Fi motion/p95 and capability negotiation remain release gates.
            videoBitRate: codec == .h265 ? 12_000_000 : 6_000_000,
            videoKeyFrameIntervalSeconds: 1,
            // Standard MediaFormat hints, never selected by model name.
            videoCodecRealtimePriority: true,
            videoCodecZeroFrameLatency: true,
            // Constant-rate AVC reduced encoder-to-socket bursts in the
            // instrumented comparisons.
            videoCodecConstantBitRate: codec == .h264,
            // Release behavior must never depend on a marketing/model string.
            // Optional encoder complexity remains an explicit Internal-only
            // experiment; the client profile uses the portable codec default.
            videoCodecFastestComplexity: false,
            // scrcpy is an interactive mirror, not buffered playback. Once a
            // current-generation frame has decoded, an additional PTS buffer
            // only adds latency and can amplify congestion on Wireless ADB.
            immediateVideoDelivery: true
        )
    }

    /// The current Wi-Fi candidate is shared by all devices. USB retains the
    /// higher-efficiency HEVC default and its existing fallback behavior.
    public static func selectedCodec(requested: ScrcpyCodec, isWirelessADB: Bool) -> ScrcpyCodec {
        isWirelessADB ? .h264 : requested
    }
}
