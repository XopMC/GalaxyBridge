import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore
import OSLog

@MainActor
final class CompanionVideoSession {
    private(set) var displayEpoch: UInt32 = 0
    var decodedFrameHandler: (@Sendable (CVPixelBuffer, CMTime, UInt32) -> Void)?
    var failureHandler: (@Sendable (Error) -> Void)?
    private let playoutClock: MediaPlayoutClock
    private let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "companion-video")
    private var sourceEpoch: UInt32?
    private var loggedFrameEpoch: UInt32?
    private var loggedPacketEpoch: UInt32?
    private var sampleStartedAt = ProcessInfo.processInfo.systemUptime
    private var receivedCount = 0
    private var presentedCount = 0
    private var receivedAt: [UInt64: TimeInterval] = [:]
    private var processingDelays: [TimeInterval] = []
    private lazy var decoder = VideoToolboxDecoder(
        playoutClock: playoutClock,
        frameHandler: { [weak self] pixelBuffer, presentationTime, epoch in
            let frame = CompanionPixelBuffer(pixelBuffer)
            Task { @MainActor in
                guard let self else { return }
                self.presentedCount += 1
                if presentationTime.isNumeric, presentationTime.value >= 0 {
                    let pts = UInt64(CMTimeConvertScale(presentationTime, timescale: 1_000_000, method: .default).value)
                    if let start = self.receivedAt.removeValue(forKey: pts) {
                        self.processingDelays.append(ProcessInfo.processInfo.systemUptime - start)
                    }
                }
                if self.loggedFrameEpoch != epoch {
                    self.loggedFrameEpoch = epoch
                    self.logger.info(
                        "first decoded frame epoch=\(epoch, privacy: .public) size=\(CVPixelBufferGetWidth(frame.value), privacy: .public)x\(CVPixelBufferGetHeight(frame.value), privacy: .public)"
                    )
                }
                self.decodedFrameHandler?(frame.value, presentationTime, epoch)
            }
        },
        failureHandler: { [weak self] error in
            Task { @MainActor in
                self?.logger.error("decoder failure: \(error.localizedDescription, privacy: .public)")
                self?.failureHandler?(error)
            }
        }
    )

    init(playoutClock: MediaPlayoutClock = MediaPlayoutClock()) {
        self.playoutClock = playoutClock
    }

    func consume(_ packet: MediaPacket) {
        let now = ProcessInfo.processInfo.systemUptime
        if !packet.flags.contains(.configuration) {
            receivedCount += 1
            if receivedAt.count >= 128 { receivedAt.removeAll(keepingCapacity: true) }
            receivedAt[packet.presentationTimeUs] = now
        }
        if now - sampleStartedAt >= 5 {
            let duration = now - sampleStartedAt
            let receivedFPS = Double(receivedCount) / duration
            let presentedFPS = Double(presentedCount) / duration
            let sorted = processingDelays.sorted()
            let p95MS = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1_000
            logger.debug("LAN video receivedFPS=\(receivedFPS, privacy: .public) presentedFPS=\(presentedFPS, privacy: .public) decodePlayoutP95ms=\(p95MS, privacy: .public)")
            sampleStartedAt = now
            receivedCount = 0
            presentedCount = 0
            processingDelays.removeAll(keepingCapacity: true)
        }
        if sourceEpoch != packet.epoch {
            sourceEpoch = packet.epoch
            displayEpoch = packet.epoch
            decoder.consume(.codec(.h264))
            decoder.consume(
                .videoSession(.init(width: 1, height: 1, clientResized: true)),
                epoch: packet.epoch
            )
            logger.info("new media epoch=\(packet.epoch, privacy: .public)")
        }
        if packet.flags.contains(.configuration) {
            logger.info(
                "codec configuration epoch=\(packet.epoch, privacy: .public) bytes=\(packet.payload.count, privacy: .public)"
            )
        } else if loggedPacketEpoch != packet.epoch {
            loggedPacketEpoch = packet.epoch
            logger.info(
                "first encoded frame epoch=\(packet.epoch, privacy: .public) key=\(packet.flags.contains(.keyFrame), privacy: .public) bytes=\(packet.payload.count, privacy: .public)"
            )
        }
        decoder.consume(
            .packet(
                .init(
                    isConfiguration: packet.flags.contains(.configuration),
                    isKeyFrame: packet.flags.contains(.keyFrame),
                    presentationTimeUs: packet.flags.contains(.configuration) ? nil : packet.presentationTimeUs,
                    payload: packet.payload
                )
            ),
            epoch: packet.epoch
        )
    }

    func invalidate() {
        decoder.invalidate()
    }
}

private struct CompanionPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}
