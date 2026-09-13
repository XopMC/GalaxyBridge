import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@main
enum DeviceInputMappingSpec {
    @MainActor
    static func main() throws {
        try inputSurfaceFillsMirrorWindow()
        try inputSurfacePreservesLowPositiveAspectRatio()

        var horizontalRight = TrackpadMotionFilter()
        try expectEqual(
            horizontalRight.consume(deltaX: 1, deltaY: 0.2, renderedSize: CGSize(width: 400, height: 800)),
            .zero,
            "trackpad dead zone"
        )
        let rightwardMove = horizontalRight.consume(
            deltaX: 12,
            deltaY: 3,
            renderedSize: CGSize(width: 400, height: 800)
        )
        try expect(rightwardMove.x < 0, "rightward physical swipe must move Android content left")
        try expectEqual(rightwardMove.y, 0, "horizontal lock must discard vertical jitter")

        var horizontalLeft = TrackpadMotionFilter()
        let leftwardMove = horizontalLeft.consume(
            deltaX: -12,
            deltaY: -2,
            renderedSize: CGSize(width: 400, height: 800)
        )
        try expect(leftwardMove.x > 0, "leftward physical swipe must move Android content right")
        try expectEqual(leftwardMove.y, 0, "horizontal lock must discard vertical jitter")

        var vertical = TrackpadMotionFilter()
        try expectEqual(
            vertical.consume(deltaX: 0.2, deltaY: 1, renderedSize: CGSize(width: 400, height: 800)),
            .zero,
            "vertical dead zone"
        )
        let verticalMove = vertical.consume(
            deltaX: 2,
            deltaY: 18,
            renderedSize: CGSize(width: 400, height: 800)
        )
        try expectEqual(verticalMove.x, 0, "vertical lock must discard horizontal jitter")
        try expect(verticalMove.y < 0, "upward physical motion must reduce flipped Android Y")
        try expect(abs(verticalMove.y) < 0.02, "motion must scale by rendered height instead of a fixed multiplier")

        vertical.reset()
        try expectEqual(
            vertical.consume(deltaX: -14, deltaY: 1, renderedSize: CGSize(width: 400, height: 800)).y,
            0,
            "reset must permit a new dominant axis"
        )

        print("PASS DeviceInput trackpad mapping uses dead zone, dominant axis, and rendered-size scaling")
    }

    @MainActor
    private static func inputSurfacePreservesLowPositiveAspectRatio() throws {
        let root = DeviceInputSurface(
            aspectRatio: 0.05,
            contentInset: 0,
            videoContentMode: .fit,
            preciseScrollUsesTouch: true,
            onTouch: { _, _, _ in },
            onTrackpadTouch: { _, _, _ in },
            onScroll: { _, _, _, _ in },
            onPinch: { _, _, _, _ in },
            onKey: { _, _, _, _ in },
            onText: { _ in },
            onNavigation: { _ in }
        )
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        hostingView.layoutSubtreeIfNeeded()

        guard let inputView = descendants(of: hostingView).compactMap({ $0 as? DeviceInputNSView }).first else {
            throw SpecFailure(message: "fit composition did not create DeviceInputNSView")
        }
        try expectEqual(
            inputView.videoAspectRatio,
            0.05,
            "input mapping must preserve every finite positive video aspect ratio"
        )
    }

    @MainActor
    private static func inputSurfaceFillsMirrorWindow() throws {
        let root = ZStack {
            Color.black
            DeviceInputSurface(
                aspectRatio: 9 / 19.5,
                contentInset: 0,
                videoContentMode: .fill,
                preciseScrollUsesTouch: true,
                onTouch: { _, _, _ in },
                onTrackpadTouch: { _, _, _ in },
                onScroll: { _, _, _, _ in },
                onPinch: { _, _, _, _ in },
                onKey: { _, _, _, _ in },
                onText: { _ in },
                onNavigation: { _ in }
            )
        }
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 430, height: 930)
        hostingView.layoutSubtreeIfNeeded()

        guard let inputView = descendants(of: hostingView).compactMap({ $0 as? DeviceInputNSView }).first else {
            throw SpecFailure(message: "mirror composition did not create DeviceInputNSView")
        }
        try expect(
            inputView.frame.width >= 429 && inputView.frame.height >= 929,
            "DeviceInputNSView must cover the full visible phone; got \(inputView.frame)"
        )
        let center = NSPoint(x: inputView.bounds.midX, y: inputView.bounds.midY)
        try expect(
            inputView.hitTest(center) === inputView,
            "the visible phone center must be owned by DeviceInputNSView"
        )
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message: message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else {
            throw SpecFailure(message: "\(message): expected \(expected), got \(actual)")
        }
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
