import AppKit
import CoreGraphics
import Foundation

enum ApplicationWindowResizeGeometry {
    static let initialContentSize = CGSize(width: 960, height: 540)
    static let minimumContentSize = CGSize(width: 320, height: 240)
}

struct ApplicationWindowGeometrySample: Equatable {
    let contentSize: CGSize
    let backingScale: CGFloat
}

@MainActor
enum ApplicationWindowGeometrySampler {
    static func restoreContentSize(_ contentSize: CGSize, on window: NSWindow) {
        window.setContentSize(contentSize)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    static func sampleAfterPresentationAndLayout(
        from window: NSWindow,
        present: () -> Void
    ) -> ApplicationWindowGeometrySample {
        present()
        return sampleAfterLayout(from: window)
    }

    static func sampleAfterLayout(from window: NSWindow) -> ApplicationWindowGeometrySample {
        window.contentView?.layoutSubtreeIfNeeded()
        return ApplicationWindowGeometrySample(
            contentSize: window.contentView?.bounds.size ?? window.contentLayoutRect.size,
            backingScale: window.backingScaleFactor
        )
    }
}

struct ApplicationWindowPixelSize: Equatable, Sendable {
    let width: UInt16
    let height: UInt16
}

extension ApplicationWindowPixelSize {
    static let maximumEdge: CGFloat = 2_560

    init?(contentSize: CGSize, backingScale: CGFloat) {
        guard contentSize.width.isFinite,
              contentSize.height.isFinite,
              backingScale.isFinite,
              contentSize.width > 0,
              contentSize.height > 0,
              backingScale > 0
        else { return nil }

        let pixelWidth = contentSize.width * backingScale
        let pixelHeight = contentSize.height * backingScale
        guard pixelWidth.isFinite, pixelHeight.isFinite else { return nil }
        let scale = min(1, Self.maximumEdge / max(pixelWidth, pixelHeight))
        let alignedWidth = Self.positiveEven(pixelWidth * scale)
        let alignedHeight = Self.positiveEven(pixelHeight * scale)
        self.init(width: UInt16(alignedWidth), height: UInt16(alignedHeight))
    }

    private static func positiveEven(_ value: CGFloat) -> Int {
        let roundedPairCount = Int((value / 2).rounded())
        return min(Int(maximumEdge), max(2, roundedPairCount * 2))
    }
}

enum ApplicationWindowVideoGeometry {
    static func aspectRatio(pixelWidth: Int, pixelHeight: Int) -> CGFloat? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    static func aspectFit(aspectRatio: CGFloat, destinationSize: CGSize) -> CGRect? {
        guard aspectRatio.isFinite,
              destinationSize.width.isFinite,
              destinationSize.height.isFinite,
              aspectRatio > 0,
              destinationSize.width > 0,
              destinationSize.height > 0
        else { return nil }

        let destinationAspect = destinationSize.width / destinationSize.height
        let renderedSize: CGSize
        if destinationAspect > aspectRatio {
            renderedSize = CGSize(
                width: destinationSize.height * aspectRatio,
                height: destinationSize.height
            )
        } else {
            renderedSize = CGSize(
                width: destinationSize.width,
                height: destinationSize.width / aspectRatio
            )
        }
        return CGRect(
            x: (destinationSize.width - renderedSize.width) / 2,
            y: (destinationSize.height - renderedSize.height) / 2,
            width: renderedSize.width,
            height: renderedSize.height
        )
    }
}

struct ApplicationWindowResizeDeliveryState: Sendable {
    static let quietPeriodMilliseconds = 150

    private(set) var currentSize: ApplicationWindowPixelSize?
    private var currentRevision: UInt64 = 0
    private var settledRevision: UInt64?
    private var controlReady = false
    private var videoReady = false
    private var lastDeliveredSize: ApplicationWindowPixelSize?
    private var closed = false

    mutating func observe(_ size: ApplicationWindowPixelSize) -> UInt64? {
        guard !closed, currentSize != size else { return nil }
        currentRevision &+= 1
        currentSize = size
        settledRevision = nil
        return currentRevision
    }

    mutating func beginConnection() {
        guard !closed else { return }
        controlReady = false
        videoReady = false
        lastDeliveredSize = nil
    }

    func launchSize(fallback: ApplicationWindowPixelSize) -> ApplicationWindowPixelSize {
        currentSize ?? fallback
    }

    mutating func quietPeriodElapsed(revision: UInt64) -> ApplicationWindowPixelSize? {
        guard !closed, revision == currentRevision else { return nil }
        settledRevision = revision
        return nextDeliveryIfReady()
    }

    mutating func controlBecameReady() -> ApplicationWindowPixelSize? {
        guard !closed else { return nil }
        controlReady = true
        return nextDeliveryIfReady()
    }

    mutating func videoBecameReady() -> ApplicationWindowPixelSize? {
        guard !closed else { return nil }
        videoReady = true
        return nextDeliveryIfReady()
    }

    mutating func close() {
        closed = true
        currentSize = nil
        settledRevision = nil
        controlReady = false
        videoReady = false
        lastDeliveredSize = nil
    }

    private mutating func nextDeliveryIfReady() -> ApplicationWindowPixelSize? {
        guard controlReady,
              videoReady,
              settledRevision == currentRevision,
              let currentSize,
              currentSize != lastDeliveredSize
        else { return nil }
        lastDeliveredSize = currentSize
        return currentSize
    }
}
