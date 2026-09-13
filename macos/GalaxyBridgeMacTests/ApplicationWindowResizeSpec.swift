import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@main
private enum ApplicationWindowResizeSpec {
    @MainActor
    static func main() throws {
        try intendedDefaultSurvivesHostingAttachment()
        try initialGeometrySamplesLaidOutHostingContent()
        try geometryDerivesEvenCodecSafePixels()
        try geometryRejectsInvalidValues()
        try videoPlacementFitsWithoutDistortion()
        try deliveryWaitsForQuietAndBothChannels()
        try burstsRetainOnlyTheLatestRequest()
        try reconnectReplaysCurrentGeometry()
        try cancellationAndWindowIsolationAreStrict()
        print("PASS app-window geometry, aspect-fit placement, bounded coalescing, readiness, reconnect and cancellation")
    }

    @MainActor
    private static func intendedDefaultSurvivesHostingAttachment() throws {
        let intendedSize = ApplicationWindowResizeGeometry.initialContentSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: intendedSize),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = ApplicationWindowResizeGeometry.minimumContentSize
        window.contentViewController = NSHostingController(
            rootView: Color.black.frame(width: 320, height: 240).fixedSize()
        )

        ApplicationWindowGeometrySampler.restoreContentSize(intendedSize, on: window)

        try expectEqual(
            window.contentView?.bounds.size,
            intendedSize,
            "hosting attachment must not collapse the intended 960x540 default to the resize minimum"
        )
        try expectEqual(
            window.contentMinSize,
            CGSize(width: 320, height: 240),
            "restoring the default must preserve the independent user-resize minimum"
        )
    }

    @MainActor
    private static func initialGeometrySamplesLaidOutHostingContent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(
            rootView: Color.black.frame(width: 816, height: 609).fixedSize()
        )
        window.contentViewController = hostingController
        let constructionSize = window.contentView?.bounds.size

        let sample = ApplicationWindowGeometrySampler.sampleAfterPresentationAndLayout(from: window) {
            window.setContentSize(hostingController.view.fittingSize)
        }
        let finalHostedSize = window.contentView?.bounds.size

        try expectEqual(
            sample.contentSize,
            finalHostedSize,
            "initial geometry samples the final hosted content instead of the construction rect"
        )
        try expect(
            sample.contentSize != constructionSize,
            "the hosting seam fixture must replace the construction-time geometry"
        )
        try expectEqual(
            sample.backingScale,
            window.backingScaleFactor,
            "initial geometry samples the window's final backing scale"
        )
    }

    private static func geometryDerivesEvenCodecSafePixels() throws {
        try expectEqual(
            ApplicationWindowResizeGeometry.minimumContentSize,
            CGSize(width: 320, height: 240),
            "an independent application window keeps a usable content minimum"
        )
        try expectEqual(
            ApplicationWindowResizeGeometry.initialContentSize,
            CGSize(width: 960, height: 540),
            "an independent application window starts at the intended usable content size"
        )
        try expectEqual(
            ApplicationWindowResizeDeliveryState.quietPeriodMilliseconds,
            150,
            "resize delivery waits for the required 150ms quiet period"
        )
        try expectEqual(
            ApplicationWindowPixelSize(contentSize: CGSize(width: 960, height: 540), backingScale: 2),
            ApplicationWindowPixelSize(width: 1_920, height: 1_080),
            "landscape content uses backing pixels"
        )
        try expectEqual(
            ApplicationWindowPixelSize(contentSize: CGSize(width: 540, height: 960), backingScale: 2),
            ApplicationWindowPixelSize(width: 1_080, height: 1_920),
            "portrait content uses backing pixels"
        )
        try expectEqual(
            ApplicationWindowPixelSize(contentSize: CGSize(width: 640, height: 640), backingScale: 2),
            ApplicationWindowPixelSize(width: 1_280, height: 1_280),
            "square content stays square"
        )
        try expectEqual(
            ApplicationWindowPixelSize(contentSize: CGSize(width: 2_000, height: 1_200), backingScale: 2),
            ApplicationWindowPixelSize(width: 2_560, height: 1_536),
            "maximum edge scales both dimensions proportionally"
        )
        try expectEqual(
            ApplicationWindowPixelSize(contentSize: CGSize(width: 333, height: 241), backingScale: 1),
            ApplicationWindowPixelSize(width: 334, height: 242),
            "odd backing pixels align to positive even dimensions"
        )
    }

    private static func geometryRejectsInvalidValues() throws {
        let valid = CGSize(width: 960, height: 540)
        try expect(ApplicationWindowPixelSize(contentSize: .zero, backingScale: 2) == nil, "zero geometry is ignored")
        try expect(
            ApplicationWindowPixelSize(contentSize: CGSize(width: CGFloat.nan, height: 540), backingScale: 2) == nil,
            "non-finite width is ignored"
        )
        try expect(
            ApplicationWindowPixelSize(contentSize: CGSize(width: 960, height: CGFloat.infinity), backingScale: 2) == nil,
            "non-finite height is ignored"
        )
        try expect(ApplicationWindowPixelSize(contentSize: valid, backingScale: 0) == nil, "zero backing scale is ignored")
        try expect(
            ApplicationWindowPixelSize(contentSize: valid, backingScale: .nan) == nil,
            "non-finite backing scale is ignored"
        )
    }

    private static func videoPlacementFitsWithoutDistortion() throws {
        try expectEqual(
            ApplicationWindowVideoGeometry.aspectRatio(pixelWidth: 1_080, pixelHeight: 1_920),
            0.5625,
            "visible geometry follows delivered frame dimensions"
        )
        try expect(
            ApplicationWindowVideoGeometry.aspectRatio(pixelWidth: 0, pixelHeight: 1_920) == nil,
            "invalid delivered frames cannot replace the visible geometry"
        )
        try expectEqual(
            ApplicationWindowVideoGeometry.aspectFit(
                aspectRatio: 9 / 16,
                destinationSize: CGSize(width: 1_000, height: 500)
            ),
            CGRect(x: 359.375, y: 0, width: 281.25, height: 500),
            "portrait video is centered inside a landscape app window"
        )
        try expectEqual(
            ApplicationWindowVideoGeometry.aspectFit(
                aspectRatio: 16 / 9,
                destinationSize: CGSize(width: 500, height: 1_000)
            ),
            CGRect(x: 0, y: 359.375, width: 500, height: 281.25),
            "landscape video is centered inside a portrait app window"
        )
        try expectEqual(
            ApplicationWindowVideoGeometry.aspectFit(
                aspectRatio: 1,
                destinationSize: CGSize(width: 700, height: 700)
            ),
            CGRect(x: 0, y: 0, width: 700, height: 700),
            "square video fills square content without cropping"
        )
        try expect(
            ApplicationWindowVideoGeometry.aspectFit(aspectRatio: .nan, destinationSize: validDestination) == nil,
            "invalid video aspect is ignored"
        )
    }

    private static func deliveryWaitsForQuietAndBothChannels() throws {
        var state = ApplicationWindowResizeDeliveryState()
        let size = ApplicationWindowPixelSize(width: 1_920, height: 1_080)
        let revision = try require(state.observe(size), "initial geometry revision")
        try expectEqual(
            state.launchSize(fallback: ApplicationWindowPixelSize(width: 1_280, height: 720)),
            size,
            "initial display launch uses the latest content geometry"
        )
        state.beginConnection()
        try expectEqual(state.quietPeriodElapsed(revision: revision), nil, "quiet geometry still waits for channels")
        try expectEqual(state.controlBecameReady(), nil, "control alone is insufficient")
        try expectEqual(state.videoBecameReady(), size, "both control and video release the settled geometry")
        try expectEqual(state.videoBecameReady(), nil, "unchanged geometry is sent once per connection")
        try expectEqual(state.observe(size), nil, "unchanged observations do not schedule more work")
    }

    private static func burstsRetainOnlyTheLatestRequest() throws {
        var state = ApplicationWindowResizeDeliveryState()
        state.beginConnection()
        try expectEqual(state.controlBecameReady(), nil, "empty ready state emits nothing")
        try expectEqual(state.videoBecameReady(), nil, "empty video state emits nothing")
        let landscape = ApplicationWindowPixelSize(width: 1_920, height: 1_080)
        let portrait = ApplicationWindowPixelSize(width: 1_080, height: 1_920)
        let oldRevision = try require(state.observe(landscape), "landscape revision")
        let latestRevision = try require(state.observe(portrait), "portrait revision")
        try expectEqual(state.quietPeriodElapsed(revision: oldRevision), nil, "a superseded debounce cannot emit")
        try expectEqual(
            state.quietPeriodElapsed(revision: latestRevision),
            portrait,
            "the latest request is emitted after the 150ms quiet-period ticket"
        )
        try expectEqual(state.currentSize, portrait, "only current geometry is retained")
    }

    private static func reconnectReplaysCurrentGeometry() throws {
        var state = ApplicationWindowResizeDeliveryState()
        let square = ApplicationWindowPixelSize(width: 1_280, height: 1_280)
        let revision = try require(state.observe(square), "square revision")
        state.beginConnection()
        _ = state.controlBecameReady()
        _ = state.videoBecameReady()
        try expectEqual(state.quietPeriodElapsed(revision: revision), square, "first connection sends current geometry")

        state.beginConnection()
        try expectEqual(state.videoBecameReady(), nil, "reconnect still waits for control")
        try expectEqual(state.controlBecameReady(), square, "reconnect replays settled current geometry")
    }

    private static func cancellationAndWindowIsolationAreStrict() throws {
        var first = ApplicationWindowResizeDeliveryState()
        var second = ApplicationWindowResizeDeliveryState()
        let firstSize = ApplicationWindowPixelSize(width: 800, height: 600)
        let secondSize = ApplicationWindowPixelSize(width: 1_200, height: 800)
        let firstRevision = try require(first.observe(firstSize), "first-window revision")
        let secondRevision = try require(second.observe(secondSize), "second-window revision")
        first.beginConnection()
        second.beginConnection()
        _ = first.controlBecameReady()
        _ = first.videoBecameReady()
        _ = second.controlBecameReady()
        _ = second.videoBecameReady()

        first.close()
        try expectEqual(first.quietPeriodElapsed(revision: firstRevision), nil, "closed window cancels pending delivery")
        try expectEqual(first.observe(secondSize), nil, "closed window ignores later geometry")
        try expectEqual(
            second.quietPeriodElapsed(revision: secondRevision),
            secondSize,
            "closing one state cannot affect another window"
        )
    }

    private static let validDestination = CGSize(width: 1_000, height: 500)

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message: message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else {
            throw SpecFailure(message: "\(message): expected \(expected), got \(actual)")
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SpecFailure(message: "missing \(message)") }
        return value
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
