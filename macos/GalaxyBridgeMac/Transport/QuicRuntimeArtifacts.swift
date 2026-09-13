#if !GALAXYBRIDGE_APP_STORE
import CryptoKit
import Foundation
import GalaxyBridgeBuildPins
import OSLog
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore

struct QuicWirelessSelection: Sendable {
    let targetToken: UInt64
}

enum QuicRuntimeArtifacts {
    static let xorParityFeature: UInt8 = 1 << 3
    enum PrimaryRateExperimentError: Error, LocalizedError {
        case ineligibleCapture
        case ineligibleMediaPacing
        var errorDescription: String? { String(localized: "ERROR_INTERNAL_EXPERIMENT") }
    }
    static let producerSHA = GalaxyBridgeBuildPins.producerSHA
    static let androidSHA = GalaxyBridgeBuildPins.quicAndroidSHA
    private static let primaryMediaMaxPacingBytesPerSecond = 2_000_000
    // Internal transport choice survives an ordinary Dock/Finder relaunch.
    // This is not a public-release promotion or a persisted QA quality override.
    static var runtimeArguments: [String] {
        effectiveProcessArguments(processArguments: ProcessInfo.processInfo.arguments,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            preferQuic: UserDefaults.standard.bool(forKey: "GBPreferQuicWireless"))
    }
    static func effectiveProcessArguments(processArguments: [String], bundleIdentifier: String?,
                                          preferQuic: Bool) -> [String] {
        guard preferQuic, bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
              !processArguments.contains("--experimental-quic-wireless") else { return processArguments }
        return processArguments + ["--experimental-quic-wireless"]
    }
    static var explicitlyEnabled: Bool {
        isExplicitlyEnabled(
            processArguments: runtimeArguments,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
    static func isExplicitlyEnabled(processArguments: [String], bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && processArguments.contains("--experimental-quic-wireless")
    }
    static func checked(_ name: String, sha: String, bundle: Bundle = .main) throws -> URL {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Resources/quic/\(name)")
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, count <= 32 * 1024 * 1024 else {
            throw QuicBackendError(status: 105)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 32 * 1024 * 1024,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha else {
            throw QuicBackendError(status: 105)
        }
        return url
    }
    static func launch(adb: ADBClient, serial: String, configuration c: ScrcpyLaunchConfiguration,
                       selection: QuicWirelessSelection, generation: UInt64) throws -> QuicBackendBridge.Launch {
        let profile = try producerArguments(configuration: c)
        let helper = try checked("gb-quic-backend-android-arm64", sha: androidSHA)
        let producer = try checked("scrcpy-server-4.1-gb-sync.1", sha: producerSHA)
        let prefix = "/data/local/tmp/gb-quic-\(String(c.scid, radix: 16))-\(generation)"
        let remoteHelper = prefix + "-backend", remoteProducer = prefix + "-producer.jar"
        // Exact selected trusted ADB is used solely for artifact staging and
        // the private stdio lifetime/bootstrap. No stock socket forward exists.
        try adb.push(serial: serial, localURL: helper, remotePath: remoteHelper)
        try adb.push(serial: serial, localURL: producer, remotePath: remoteProducer)
        try adb.prepareQuicExecutable(serial: serial, remotePath: remoteHelper)
        let peerIP = try adb.wifiIPv4Address(serial: serial)
        let peerTransport = try peerTransportArguments(configuration: c)
        let arguments = ["-s", serial, "shell", "-T", remoteHelper, "--stdio-peer"]
            + peerTransport + ["--producer", remoteProducer] + profile
        let display: UInt32, kind: UInt8
        switch c.captureTarget {
        case let .display(id): display = id; kind = 0
        case .virtualDisplay: display = UInt32.max; kind = 1
        }
        let sha = stride(from: 0, to: androidSHA.count, by: 2).map { index -> UInt8 in
            let start = androidSHA.index(androidSHA.startIndex, offsetBy: index)
            return UInt8(androidSHA[start..<androidSHA.index(start, offsetBy: 2)], radix: 16)!
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-quic-primary-8mbps") {
            // One fixed scalar per successfully constructed owned launch, not
            // an achieved bitrate, output cap, or dump of sensitive arguments.
            Logger(subsystem: "com.xopmc.GalaxyBridge", category: "scrcpy")
                .notice("qa-quic-primary-requested-video-bit-rate=8000000")
        }
        // Bit3 is an authenticated, exact-helper capability. Only the matched
        // experimental QUIC pair sees kind15 parity; stock USB/Wireless ADB
        // scrcpy and an older peer never receive the new datagram record.
        let enabled = enabledMediaFeatures(audioEnabled: c.audioEnabled)
        return .init(program: adb.executableURL.path, arguments: arguments, peerIP: peerIP,
            sidecarSHA: sha, generation: generation, targetToken: selection.targetToken,
            scid: c.scid, displayID: display, captureKind: kind, enabled: enabled)
    }
    static func enabledMediaFeatures(audioEnabled: Bool) -> UInt8 {
        UInt8(audioEnabled ? 7 : 5) | xorParityFeature
    }
    static func peerTransportArguments(
        configuration c: ScrcpyLaunchConfiguration,
        processArguments: [String] = runtimeArguments,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> [String] {
        let requested = processArguments.contains("--qa-quic-media-pacing-2mbps")
        let experimentalInternal = bundleIdentifier == "com.xopmc.GalaxyBridge.internal"
            && processArguments.contains("--experimental-quic-wireless")
        guard experimentalInternal else {
            if requested { throw PrimaryRateExperimentError.ineligibleMediaPacing }
            return []
        }
        guard c.captureTarget == .display(id: 0), c.applicationTarget == nil else {
            if requested { throw PrimaryRateExperimentError.ineligibleMediaPacing }
            return []
        }
        // MediaCodec emits short bursts even in constant-bit-rate mode. With
        // no sender ceiling those bursts fill QUIC's generated-datagram queue,
        // and fresh access units expire precisely when the screen moves. This
        // intended ceiling is above the 6 Mbps AVC profile (including audio
        // and framing overhead). The native adapter converts byte/s to the
        // pinned library's Mbps units; the ceiling alone is not a P0 pass.
        guard primaryMediaMaxPacingBytesPerSecond >= 1_000_000 else {
            throw PrimaryRateExperimentError.ineligibleMediaPacing
        }
        return [
            "--media-max-pacing-bytes-per-second",
            String(primaryMediaMaxPacingBytesPerSecond),
        ]
    }
    // Shared by the actual owned launch and pure vector tests, before staging.
    static func producerArguments(configuration c: ScrcpyLaunchConfiguration,
                                  processArguments: [String] = runtimeArguments,
                                  bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> [String] {
        let videoBitRate: UInt32
        if processArguments.contains("--qa-quic-primary-8mbps") {
            guard bundleIdentifier == "com.xopmc.GalaxyBridge.internal",
                  processArguments.contains("--experimental-quic-wireless"),
                  c.captureTarget == .display(id: 0), c.applicationTarget == nil else {
                throw PrimaryRateExperimentError.ineligibleCapture
            }
            videoBitRate = 8_000_000
        } else {
            videoBitRate = c.videoBitRate
        }
        var arguments = ["--video-codec", c.videoCodec == .h265 ? "h265" : "h264", "--max-size", String(c.maxSize),
                         "--max-fps", String(c.maxFPS), "--video-bit-rate", String(videoBitRate),
                         "--audio-bit-rate", String(c.audioBitRate)]
        if let seconds = c.videoKeyFrameIntervalSeconds {
            arguments += ["--video-key-frame-interval-seconds", String(seconds)]
        }
        switch c.captureTarget {
        case .display:
            arguments += ["--launch-policy", "primary"]
        case let .virtualDisplay(width, height, dpi):
            arguments += ["--new-display", "\(width)x\(height)", "--launch-policy", c.applicationTarget == nil ? "virtual-desktop" : "application"]
            if let dpi { arguments += ["--density", String(dpi)] }
        }
        arguments += ["--cleanup", c.cleanup ? "true" : "false"]
        return arguments
    }
}
#endif
