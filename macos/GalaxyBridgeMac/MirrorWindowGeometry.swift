import AppKit
import CoreGraphics
import Foundation

enum MirrorHeaderControlID: String, CaseIterable, Identifiable {
    case close
    case minimize
    case zoom
    case back
    case home
    case recents
    case pin
    case record
    case displayTarget
    case rotate
    case screenOff
    case screenOn

    var id: Self { self }

    static let windowControls: [Self] = [.close, .minimize, .zoom]

    static func primaryControls(enhanced: Bool) -> [Self] {
        var controls: [Self] = [.back, .home, .recents, .pin, .record]
        if enhanced {
            controls.append(contentsOf: [.displayTarget, .rotate, .screenOff, .screenOn])
        }
        return controls
    }
}

enum MirrorHeaderActionEffect: Equatable {
    case closeWindow
    case minimizeWindow
    case toggleWindowZoom
    case androidKeycode(UInt32)
    case togglePin
    case toggleRecording
    case presentDisplayMenu
    case rotateDevice
    case setDisplayPower(Bool)
}

enum MirrorHeaderActionRouting {
    static func effect(for control: MirrorHeaderControlID) -> MirrorHeaderActionEffect {
        switch control {
        case .close: .closeWindow
        case .minimize: .minimizeWindow
        case .zoom: .toggleWindowZoom
        case .back: .androidKeycode(4)
        case .home: .androidKeycode(3)
        case .recents: .androidKeycode(187)
        case .pin: .togglePin
        case .record: .toggleRecording
        case .displayTarget: .presentDisplayMenu
        case .rotate: .rotateDevice
        case .screenOff: .setDisplayPower(false)
        case .screenOn: .setDisplayPower(true)
        }
    }
}

enum MirrorHeaderLayout {
    static let controlDiameter: CGFloat = 24
    static let controlPitch: CGFloat = 32

    static func centeredControlCenters(count: Int, containerWidth: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let midpoint = max(0, containerWidth) / 2
        let first = midpoint - CGFloat(count - 1) * controlPitch / 2
        return (0 ..< count).map { first + CGFloat($0) * controlPitch }
    }

    static func controlGroupWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return controlDiameter + CGFloat(count - 1) * controlPitch
    }
}

struct MirrorWindowZoomState {
    private var restoreFrame: CGRect?

    mutating func toggledFrame(
        currentFrame: CGRect,
        visibleFrame: CGRect,
        headerClearance: CGFloat
    ) -> CGRect {
        if let restoreFrame {
            self.restoreFrame = nil
            return restoreFrame
        }

        restoreFrame = currentFrame
        let clearance = max(0, headerClearance)
        let availableHeight = max(1, visibleFrame.height - clearance)
        let ratio = MirrorWindowGeometry.normalizedAspectRatio(
            currentFrame.width / max(1, currentFrame.height)
        )
        let width = min(visibleFrame.width, availableHeight * ratio)
        let height = width / ratio
        return CGRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + (availableHeight - height) / 2,
            width: width,
            height: height
        )
    }
}

struct MirrorHeaderPlacement: Equatable {
    let panelFrame: CGRect
    let visibleHeaderFrame: CGRect
}

enum MirrorResizeAcquisitionPolicy {
    // Entirely outside the phone image. Keep the target close to the visible
    // contour: 24 points outward is comfortably larger than a native resize
    // affordance, while the 72-point arms make each corner easy to acquire
    // without occupying large parts of neighbouring desktop windows. Long
    // straight-edge centers remain true click-through gaps.
    static let externalHaloWidth: CGFloat = 24
    static let cornerArmLength: CGFloat = 72
    static let minimumStraightPassThrough: CGFloat = 72
    // Keep one real alpha quantum in the WindowServer surface. Values below
    // 1/255 may be quantized to fully transparent and stop receiving pointer
    // events even though AppKit still reports a non-empty child window.
    static let windowServerBackingAlpha: CGFloat = 1.0 / 255.0
}

struct MirrorCornerAcquisitionZone: Equatable {
    let frame: CGRect
    let edges: MirrorResizeEdges
}

struct MirrorResizeEdges: OptionSet, Equatable {
    let rawValue: UInt8

    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let top = Self(rawValue: 1 << 3)
}

enum MirrorResizeCursorKind: Equatable {
    case horizontal
    case vertical
    case topLeftBottomRight
    case bottomLeftTopRight
}

enum MirrorAspectUpdateDecision: Equatable {
    case unchanged
    case apply(CGFloat)
    case deferUntilResizeEnds(CGFloat)

    static func resolve(
        appliedAspectRatio: CGFloat?,
        requestedAspectRatio: CGFloat,
        isLiveResize: Bool,
        epsilon: CGFloat = 0.004
    ) -> Self {
        let ratio = MirrorWindowGeometry.normalizedAspectRatio(requestedAspectRatio)
        if let appliedAspectRatio, abs(appliedAspectRatio - ratio) <= epsilon {
            return .unchanged
        }
        return isLiveResize ? .deferUntilResizeEnds(ratio) : .apply(ratio)
    }
}

struct MirrorResizeActivity {
    private(set) var isManualResizeActive = false

    mutating func beginManualResize() {
        isManualResizeActive = true
    }

    mutating func endManualResize() {
        isManualResizeActive = false
    }

    func isActive(systemLiveResize: Bool) -> Bool {
        systemLiveResize || isManualResizeActive
    }
}

struct MirrorResizeAspectLock {
    private var lockedAspectRatio: CGFloat?

    mutating func begin(aspectRatio: CGFloat) {
        lockedAspectRatio = MirrorWindowGeometry.normalizedAspectRatio(aspectRatio)
    }

    mutating func end() {
        lockedAspectRatio = nil
    }

    func effectiveAspectRatio(current: CGFloat) -> CGFloat {
        lockedAspectRatio ?? MirrorWindowGeometry.normalizedAspectRatio(current)
    }
}

enum MirrorWindowGeometry {
    static func normalizedAspectRatio(_ aspectRatio: CGFloat) -> CGFloat {
        guard aspectRatio.isFinite else { return 9 / 19.5 }
        return min(max(aspectRatio, 0.25), 2.5)
    }

    static func minimumContentSize(aspectRatio: CGFloat, minimumShortEdge: CGFloat) -> CGSize {
        let ratio = normalizedAspectRatio(aspectRatio)
        let shortEdge = max(1, minimumShortEdge)
        if ratio <= 1 {
            return CGSize(width: shortEdge, height: shortEdge / ratio)
        }
        return CGSize(width: shortEdge * ratio, height: shortEdge)
    }

    static func frameReservingHeader(
        _ proposedFrame: CGRect,
        visibleFrame: CGRect,
        headerClearance: CGFloat
    ) -> CGRect {
        let clearance = max(0, headerClearance)
        let maximumHeight = max(1, visibleFrame.height - clearance)
        let scale = min(
            1,
            visibleFrame.width / max(1, proposedFrame.width),
            maximumHeight / max(1, proposedFrame.height)
        )
        let size = CGSize(
            width: max(1, proposedFrame.width * scale),
            height: max(1, proposedFrame.height * scale)
        )
        let maximumX = visibleFrame.maxX - size.width
        let maximumY = visibleFrame.maxY - clearance - size.height
        return CGRect(
            x: min(max(proposedFrame.minX, visibleFrame.minX), maximumX),
            y: min(max(proposedFrame.minY, visibleFrame.minY), maximumY),
            width: size.width,
            height: size.height
        )
    }

    static func fittedContentSize(
        preservingAreaOf currentSize: CGSize,
        aspectRatio: CGFloat,
        visibleFrame: CGRect,
        minimumShortEdge: CGFloat
    ) -> CGSize {
        let ratio = normalizedAspectRatio(aspectRatio)
        let minimum = minimumContentSize(aspectRatio: ratio, minimumShortEdge: minimumShortEdge)
        let availableWidth = max(1, visibleFrame.width * 0.94)
        let availableHeight = max(1, visibleFrame.height * 0.94)
        let maximumWidth = max(minimum.width, min(availableWidth, availableHeight * ratio))
        let area = max(1, currentSize.width * currentSize.height)
        let areaPreservingWidth = sqrt(area * ratio)
        let width = min(maximumWidth, max(minimum.width, areaPreservingWidth))
        return CGSize(width: width, height: width / ratio)
    }

    static func visiblePhoneFrame(inOuterFrame outerFrame: CGRect, haloWidth: CGFloat) -> CGRect {
        let halo = boundedHaloWidth(haloWidth, for: outerFrame.size)
        return outerFrame.insetBy(dx: halo, dy: halo)
    }

    static func outerFrame(aroundVisiblePhoneFrame phoneFrame: CGRect, haloWidth: CGFloat) -> CGRect {
        let halo = max(0, haloWidth)
        return phoneFrame.insetBy(dx: -halo, dy: -halo)
    }

    static func visiblePhoneSize(inOuterSize outerSize: CGSize, haloWidth: CGFloat) -> CGSize {
        let halo = boundedHaloWidth(haloWidth, for: outerSize)
        return CGSize(
            width: max(1, outerSize.width - halo * 2),
            height: max(1, outerSize.height - halo * 2)
        )
    }

    static func outerSize(aroundVisiblePhoneSize phoneSize: CGSize, haloWidth: CGFloat) -> CGSize {
        let halo = max(0, haloWidth)
        return CGSize(
            width: max(1, phoneSize.width) + halo * 2,
            height: max(1, phoneSize.height) + halo * 2
        )
    }

    static func externalCornerAcquisitionZones(
        around phoneFrame: CGRect,
        thickness: CGFloat,
        armLength: CGFloat
    ) -> [MirrorCornerAcquisitionZone] {
        let thickness = max(1, thickness)
        let straightGap = MirrorResizeAcquisitionPolicy.minimumStraightPassThrough
        let horizontalArm = min(
            max(thickness, armLength),
            max(1, (phoneFrame.width - straightGap) / 2)
        )
        let verticalArm = min(
            max(thickness, armLength),
            max(1, (phoneFrame.height - straightGap) / 2)
        )

        return [
            MirrorCornerAcquisitionZone(
                frame: CGRect(
                    x: phoneFrame.minX - thickness,
                    y: phoneFrame.minY - thickness,
                    width: thickness,
                    height: thickness + verticalArm
                ),
                edges: [.left, .bottom]
            ),
            MirrorCornerAcquisitionZone(
                frame: CGRect(
                    x: phoneFrame.minX - thickness,
                    y: phoneFrame.minY - thickness,
                    width: thickness + horizontalArm,
                    height: thickness
                ),
                edges: [.left, .bottom]
            ),
            MirrorCornerAcquisitionZone(
                frame: CGRect(
                    x: phoneFrame.maxX,
                    y: phoneFrame.minY - thickness,
                    width: thickness,
                    height: thickness + verticalArm
                ),
                edges: [.right, .bottom]
            ),
            MirrorCornerAcquisitionZone(
                frame: CGRect(
                    x: phoneFrame.maxX - horizontalArm,
                    y: phoneFrame.minY - thickness,
                    width: thickness + horizontalArm,
                    height: thickness
                ),
                edges: [.right, .bottom]
            ),
            MirrorCornerAcquisitionZone(
                frame: CGRect(
                    x: phoneFrame.minX - thickness,
                    y: phoneFrame.maxY - verticalArm,
                    width: thickness,
                    height: thickness + verticalArm
                ),
                edges: [.left, .top]
            ),
            MirrorCornerAcquisitionZone(
                frame: CGRect(
                    x: phoneFrame.minX - thickness,
                    y: phoneFrame.maxY,
                    width: thickness + horizontalArm,
                    height: thickness
                ),
                edges: [.left, .top]
            ),
            MirrorCornerAcquisitionZone(
                frame: CGRect(
                    x: phoneFrame.maxX,
                    y: phoneFrame.maxY - verticalArm,
                    width: thickness,
                    height: thickness + verticalArm
                ),
                edges: [.right, .top]
            ),
            MirrorCornerAcquisitionZone(
                frame: CGRect(
                    x: phoneFrame.maxX - horizontalArm,
                    y: phoneFrame.maxY,
                    width: thickness + horizontalArm,
                    height: thickness
                ),
                edges: [.right, .top]
            ),
        ]
    }

    static func headerPlacement(
        parentFrame: CGRect,
        panelHeight: CGFloat,
        transparentBridgeHeight: CGFloat,
        minimumPanelWidth: CGFloat = 0
    ) -> MirrorHeaderPlacement {
        let height = max(1, panelHeight)
        let bridge = min(max(0, transparentBridgeHeight), height)
        let width = max(parentFrame.width, minimumPanelWidth)
        let panel = CGRect(
            x: parentFrame.midX - width / 2,
            y: parentFrame.maxY - bridge,
            width: width,
            height: height
        )
        let visibleHeader = CGRect(
            x: panel.minX,
            y: panel.minY + bridge,
            width: panel.width,
            height: height - bridge
        )
        return MirrorHeaderPlacement(panelFrame: panel, visibleHeaderFrame: visibleHeader)
    }

    static func resizeEdges(
        at point: CGPoint,
        in bounds: CGRect,
        edgeHitWidth: CGFloat,
        cornerHitSize: CGFloat
    ) -> MirrorResizeEdges {
        guard point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else { return [] }
        let maximumHitSize = min(bounds.width, bounds.height) / 2
        let haloWidth = min(max(1, edgeHitWidth), maximumHitSize)
        let cornerExtent = min(max(haloWidth, cornerHitSize), maximumHitSize)
        let phoneBounds = bounds.insetBy(dx: haloWidth, dy: haloWidth)
        guard !phoneBounds.contains(point) else { return [] }

        var result: MirrorResizeEdges = []
        if point.x < phoneBounds.minX {
            result.insert(.left)
        } else if point.x > phoneBounds.maxX {
            result.insert(.right)
        }
        if point.y < phoneBounds.minY {
            result.insert(.bottom)
        } else if point.y > phoneBounds.maxY {
            result.insert(.top)
        }

        // Extend each corner along both arms of the outside halo. This makes a
        // corner easy to acquire without ever placing an event-catching view
        // over the phone's visible pixels.
        if result.contains(.left) || result.contains(.right) {
            if point.y <= phoneBounds.minY + cornerExtent {
                result.insert(.bottom)
            } else if point.y >= phoneBounds.maxY - cornerExtent {
                result.insert(.top)
            }
        }
        if result.contains(.bottom) || result.contains(.top) {
            if point.x <= phoneBounds.minX + cornerExtent {
                result.insert(.left)
            } else if point.x >= phoneBounds.maxX - cornerExtent {
                result.insert(.right)
            }
        }
        let hasHorizontalEdge = result.contains(.left) || result.contains(.right)
        let hasVerticalEdge = result.contains(.bottom) || result.contains(.top)
        return hasHorizontalEdge && hasVerticalEdge ? result : []
    }

    static func resizeCursor(for edges: MirrorResizeEdges) -> MirrorResizeCursorKind? {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.bottom) || edges.contains(.top)
        switch (horizontal, vertical) {
        case (true, true):
            let isTopLeftOrBottomRight =
                (edges.contains(.top) && edges.contains(.left)) ||
                (edges.contains(.bottom) && edges.contains(.right))
            return isTopLeftOrBottomRight ? .topLeftBottomRight : .bottomLeftTopRight
        case (true, false):
            return .horizontal
        case (false, true):
            return .vertical
        case (false, false):
            return nil
        }
    }

    static func isTopEdgeHoverTarget(
        _ point: CGPoint,
        in bounds: CGRect,
        activationWidth: CGFloat
    ) -> Bool {
        guard bounds.contains(point) else { return false }
        let width = min(max(1, activationWidth), bounds.height)
        return point.y >= bounds.maxY - width
    }

    static func resizedFrame(
        from startFrame: CGRect,
        edges: MirrorResizeEdges,
        mouseDelta: CGPoint,
        aspectRatio: CGFloat,
        visibleFrame: CGRect,
        minimumShortEdge: CGFloat
    ) -> CGRect {
        guard !edges.isEmpty else { return startFrame }
        let ratio = normalizedAspectRatio(aspectRatio)

        var proposedWidth = startFrame.width
        var proposedHeight = startFrame.height
        if edges.contains(.left) { proposedWidth -= mouseDelta.x }
        if edges.contains(.right) { proposedWidth += mouseDelta.x }
        if edges.contains(.bottom) { proposedHeight -= mouseDelta.y }
        if edges.contains(.top) { proposedHeight += mouseDelta.y }

        let hasHorizontal = edges.contains(.left) || edges.contains(.right)
        let hasVertical = edges.contains(.bottom) || edges.contains(.top)
        var targetWidth: CGFloat
        if hasHorizontal && hasVertical {
            let widthChange = abs(proposedWidth - startFrame.width) / max(1, startFrame.width)
            let heightChange = abs(proposedHeight - startFrame.height) / max(1, startFrame.height)
            targetWidth = widthChange >= heightChange ? proposedWidth : proposedHeight * ratio
        } else if hasHorizontal {
            targetWidth = proposedWidth
        } else {
            targetWidth = proposedHeight * ratio
        }

        let minimumWidth = ratio <= 1
            ? max(1, minimumShortEdge)
            : max(1, minimumShortEdge) * ratio
        let maximumWidth = max(
            minimumWidth,
            min(visibleFrame.width * 0.98, visibleFrame.height * 0.98 * ratio)
        )
        targetWidth = min(maximumWidth, max(minimumWidth, targetWidth))
        let targetHeight = targetWidth / ratio

        let originX: CGFloat
        if edges.contains(.left) {
            originX = startFrame.maxX - targetWidth
        } else if edges.contains(.right) {
            originX = startFrame.minX
        } else {
            originX = startFrame.midX - targetWidth / 2
        }

        let originY: CGFloat
        if edges.contains(.bottom) {
            originY = startFrame.maxY - targetHeight
        } else if edges.contains(.top) {
            originY = startFrame.minY
        } else {
            originY = startFrame.midY - targetHeight / 2
        }

        return CGRect(x: originX, y: originY, width: targetWidth, height: targetHeight)
    }

    static func resizedOuterFrame(
        from startOuterFrame: CGRect,
        haloWidth: CGFloat,
        edges: MirrorResizeEdges,
        mouseDelta: CGPoint,
        aspectRatio: CGFloat,
        visibleFrame: CGRect,
        minimumShortEdge: CGFloat
    ) -> CGRect {
        let startPhoneFrame = visiblePhoneFrame(inOuterFrame: startOuterFrame, haloWidth: haloWidth)
        let availablePhoneFrame = visibleFrame.insetBy(dx: max(0, haloWidth), dy: max(0, haloWidth))
        let targetPhoneFrame = resizedFrame(
            from: startPhoneFrame,
            edges: edges,
            mouseDelta: mouseDelta,
            aspectRatio: aspectRatio,
            visibleFrame: availablePhoneFrame,
            minimumShortEdge: minimumShortEdge
        )
        return outerFrame(aroundVisiblePhoneFrame: targetPhoneFrame, haloWidth: haloWidth)
    }

    private static func boundedHaloWidth(_ haloWidth: CGFloat, for size: CGSize) -> CGFloat {
        let maximum = max(0, min(size.width, size.height) / 2 - 0.5)
        return min(max(0, haloWidth), maximum)
    }
}

@MainActor
enum MirrorWindowDragTarget {
    static func resolve(from window: NSWindow?) -> NSWindow? {
        window?.parent ?? window
    }
}

enum MirrorWindowPinPolicy {
    private static let managedBehaviors: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
    ]

    static func collectionBehavior(
        base: NSWindow.CollectionBehavior,
        isPinned: Bool
    ) -> NSWindow.CollectionBehavior {
        var result = base
        if isPinned {
            // AppKit permits at most one of managed/transient/stationary.
            // A pinned mirror is stationary, so remove any mutually-exclusive
            // behavior inherited from the SwiftUI window scene first. The
            // same exclusivity rule applies to full-screen modes: a pinned
            // mirror is auxiliary rather than a full-screen primary window.
            result.remove([.managed, .transient])
            result.remove([.fullScreenPrimary, .fullScreenNone])
            result.insert(managedBehaviors)
        }
        return result
    }

    static func level(isPinned: Bool) -> NSWindow.Level {
        isPinned ? .floating : .normal
    }
}

enum MirrorWindowActivationPolicy {
    static func seamlessFocusableStyleMask(from base: NSWindow.StyleMask) -> NSWindow.StyleMask {
        var result = base
        // `titled + fullSizeContentView` still installs AppKit's native
        // title-bar composition. On macOS 26 that composition can become
        // visible again even with a transparent/hidden title. Keyability is a
        // window-class responsibility, not a reason to retain native chrome.
        result.remove([
            .titled,
            .fullSizeContentView,
            .unifiedTitleAndToolbar,
            .resizable,
        ])
        result.insert([.closable, .miniaturizable])
        return result
    }
}

/// AppKit's stock borderless window refuses key status. The mirror needs a
/// real first-responder chain for keyboard/IME input, while remaining entirely
/// free of title-bar chrome, so it owns a narrow NSWindow subclass.
@MainActor
final class SeamlessMirrorWindow: NSWindow {
    var closeAttemptObserver: ((SeamlessMirrorWindow) -> Void)?
    private(set) var isPresentationRetired = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performMiniaturize(_ sender: Any?) {
        guard styleMask.contains(.miniaturizable) else { return }
        miniaturize(sender)
    }

    override func performClose(_ sender: Any?) {
        closeAttemptObserver?(self)
        guard delegate?.windowShouldClose?(self) != false else { return }
        close()
    }

    func retireSeamlessPresentation() {
        guard !isPresentationRetired else { return }
        isPresentationRetired = true
        for child in childWindows ?? [] {
            removeChildWindow(child)
            child.orderOut(nil)
        }
        orderOut(nil)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performClose(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        return styleMask.contains(.closable)
    }
}
