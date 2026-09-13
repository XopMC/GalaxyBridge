import AppKit
import CoreGraphics
import Foundation

@main
enum MirrorWindowGeometrySpec {
    static func main() throws {
        try expectEqual(
            MirrorHeaderControlID.windowControls,
            [.close, .minimize, .zoom],
            "window controls preserve the native traffic-light order"
        )
        try expectEqual(
            MirrorHeaderControlID.primaryControls(enhanced: true),
            [.back, .home, .recents, .pin, .record, .displayTarget, .rotate, .screenOff, .screenOn],
            "enhanced mirror controls have one stable left-to-right order"
        )
        try expectEqual(
            MirrorHeaderControlID.primaryControls(enhanced: false),
            [.back, .home, .recents, .pin, .record],
            "companion mirror hides only enhanced-only controls"
        )
        try expectEqual(MirrorHeaderActionRouting.effect(for: .close), .closeWindow, "close routes to the mirror window")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .minimize), .minimizeWindow, "minimize routes to the mirror window")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .zoom), .toggleWindowZoom, "zoom routes to the mirror window")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .back), .androidKeycode(4), "Back key routing")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .home), .androidKeycode(3), "Home key routing")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .recents), .androidKeycode(187), "Recents key routing")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .pin), .togglePin, "pin routing")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .record), .toggleRecording, "record routing")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .displayTarget), .presentDisplayMenu, "display menu routing")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .rotate), .rotateDevice, "rotate routing")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .screenOff), .setDisplayPower(false), "screen-off routing")
        try expectEqual(MirrorHeaderActionRouting.effect(for: .screenOn), .setDisplayPower(true), "screen-on routing")

        let controlCenters = MirrorHeaderLayout.centeredControlCenters(
            count: MirrorHeaderControlID.primaryControls(enhanced: true).count,
            containerWidth: 430
        )
        try expectEqual(controlCenters.count, 9, "every primary action gets one layout slot")
        try expect(
            abs((controlCenters.first ?? 0) + (controlCenters.last ?? 0) - 430) < 0.000_001,
            "the primary controls are symmetric around the exact header midpoint"
        )
        try expect(
            zip(controlCenters, controlCenters.dropFirst()).allSatisfy {
                abs(($1 - $0) - MirrorHeaderLayout.controlPitch) < 0.000_001
            },
            "primary controls use one even visual pitch"
        )

        var zoomState = MirrorWindowZoomState()
        let originalMirrorFrame = CGRect(x: 300, y: 180, width: 400, height: 800)
        let zoomedMirrorFrame = zoomState.toggledFrame(
            currentFrame: originalMirrorFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            headerClearance: 48
        )
        try expectEqual(
            zoomedMirrorFrame,
            CGRect(x: 562, y: 0, width: 476, height: 952),
            "green control zooms the seamless phone to the largest aspect-correct visible frame"
        )
        try expectEqual(
            zoomState.toggledFrame(
                currentFrame: zoomedMirrorFrame,
                visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
                headerClearance: 48
            ),
            originalMirrorFrame,
            "second green-control click restores the exact prior phone frame"
        )

        try expect(
            MirrorResizeAcquisitionPolicy.windowServerBackingAlpha >= 1.0 / 255.0,
            "external corner surfaces must survive WindowServer alpha quantization"
        )
        let portrait = MirrorWindowGeometry.fittedContentSize(
            preservingAreaOf: CGSize(width: 400, height: 800),
            aspectRatio: 0.5,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000),
            minimumShortEdge: 280
        )
        try expectEqual(portrait, CGSize(width: 400, height: 800), "portrait size preserves area")
        try expect(abs(portrait.width / portrait.height - 0.5) < 0.000_001, "portrait aspect is exact")

        let landscape = MirrorWindowGeometry.fittedContentSize(
            preservingAreaOf: CGSize(width: 400, height: 800),
            aspectRatio: 2,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000),
            minimumShortEdge: 280
        )
        try expectEqual(landscape, CGSize(width: 800, height: 400), "orientation change preserves area")
        try expect(abs(landscape.width / landscape.height - 2) < 0.000_001, "landscape aspect is exact")

        try expectEqual(
            MirrorAspectUpdateDecision.resolve(
                appliedAspectRatio: 0.5,
                requestedAspectRatio: 1,
                isLiveResize: true
            ),
            .deferUntilResizeEnds(1),
            "aspect changes must not snap a live resize"
        )
        try expectEqual(
            MirrorAspectUpdateDecision.resolve(
                appliedAspectRatio: 0.5,
                requestedAspectRatio: 0.502,
                isLiveResize: false
            ),
            .unchanged,
            "sub-threshold decoder jitter must not resize the window"
        )

        var resizeActivity = MirrorResizeActivity()
        try expect(!resizeActivity.isActive(systemLiveResize: false), "resize starts inactive")
        resizeActivity.beginManualResize()
        try expect(
            resizeActivity.isActive(systemLiveResize: false),
            "custom border drag participates in live-resize deferral"
        )
        resizeActivity.endManualResize()
        try expect(!resizeActivity.isActive(systemLiveResize: false), "mouse-up ends custom live resize")
        try expect(
            resizeActivity.isActive(systemLiveResize: true),
            "native AppKit live resize remains recognized"
        )

        var aspectLock = MirrorResizeAspectLock()
        aspectLock.begin(aspectRatio: 0.5)
        try expectEqual(
            aspectLock.effectiveAspectRatio(current: 1),
            0.5,
            "orientation updates cannot change aspect in the middle of a border drag"
        )
        aspectLock.end()
        try expectEqual(
            aspectLock.effectiveAspectRatio(current: 1),
            1,
            "new aspect takes effect after the border drag ends"
        )

        let header = MirrorWindowGeometry.headerPlacement(
            parentFrame: CGRect(x: 100, y: 100, width: 400, height: 800),
            panelHeight: 52,
            transparentBridgeHeight: 8
        )
        try expectEqual(header.panelFrame, CGRect(x: 100, y: 892, width: 400, height: 52), "header panel placement")
        try expectEqual(header.visibleHeaderFrame.minY, 900, "visible header starts above the phone")
        try expect(!header.visibleHeaderFrame.intersects(CGRect(x: 100, y: 100, width: 400, height: 800)), "visible header never occludes video")

        let narrowHeader = MirrorWindowGeometry.headerPlacement(
            parentFrame: CGRect(x: 100, y: 100, width: 280, height: 800),
            panelHeight: 52,
            transparentBridgeHeight: 8,
            minimumPanelWidth: 430
        )
        try expectEqual(narrowHeader.panelFrame.minX, 25, "wide header remains centered over a narrow phone")
        try expectEqual(narrowHeader.visibleHeaderFrame.minY, 900, "wide header remains detached from video")

        let visibleScreen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let nearTop = CGRect(x: 500, y: 20, width: 400, height: 870)
        let initiallyPlaced = MirrorWindowGeometry.frameReservingHeader(
            nearTop,
            visibleFrame: visibleScreen,
            headerClearance: 48
        )
        try expectEqual(initiallyPlaced.maxY, visibleScreen.maxY - 48, "initial placement reserves header room")
        try expect(
            abs(initiallyPlaced.width / initiallyPlaced.height - nearTop.width / nearTop.height) < 0.0001,
            "initial header clearance preserves phone aspect"
        )
        let frameBeforeHover = initiallyPlaced
        _ = MirrorWindowGeometry.headerPlacement(
            parentFrame: frameBeforeHover,
            panelHeight: 52,
            transparentBridgeHeight: 8
        )
        try expectEqual(frameBeforeHover, initiallyPlaced, "revealing the header must never move the phone window")

        let visiblePhoneFrame = CGRect(x: 100, y: 100, width: 400, height: 800)
        try expectEqual(
            MirrorResizeAcquisitionPolicy.externalHaloWidth,
            24,
            "external resize acquisition stays close to the seamless contour"
        )
        try expectEqual(
            MirrorResizeAcquisitionPolicy.cornerArmLength,
            72,
            "external corner arms are targetable without covering the desktop"
        )
        let generousOuterBounds = CGRect(
            origin: .zero,
            size: MirrorWindowGeometry.outerSize(
                aroundVisiblePhoneSize: visiblePhoneFrame.size,
                haloWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth
            )
        )
        let generousPhoneBounds = generousOuterBounds.insetBy(
            dx: MirrorResizeAcquisitionPolicy.externalHaloWidth,
            dy: MirrorResizeAcquisitionPolicy.externalHaloWidth
        )
        try expectEqual(
            generousPhoneBounds,
            CGRect(x: 24, y: 24, width: 400, height: 800),
            "the compact acquisition halo remains entirely outside the phone"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 12, y: 424),
                in: generousOuterBounds,
                edgeHitWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth,
                cornerHitSize: MirrorResizeAcquisitionPolicy.cornerArmLength
            ),
            [],
            "straight external edges remain click-through and never resize"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 24, y: 424),
                in: generousOuterBounds,
                edgeHitWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth,
                cornerHitSize: MirrorResizeAcquisitionPolicy.cornerArmLength
            ),
            [],
            "the exact visible phone edge never becomes a resize target"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 423.9, y: 823.9),
                in: generousOuterBounds,
                edgeHitWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth,
                cornerHitSize: MirrorResizeAcquisitionPolicy.cornerArmLength
            ),
            [],
            "phone pixels beside a resize corner remain entirely interactive"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 12, y: 72),
                in: generousOuterBounds,
                edgeHitWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth,
                cornerHitSize: MirrorResizeAcquisitionPolicy.cornerArmLength
            ),
            [.left, .bottom],
            "the bottom-left corner arm remains wholly outside phone pixels"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 436, y: 776),
                in: generousOuterBounds,
                edgeHitWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth,
                cornerHitSize: MirrorResizeAcquisitionPolicy.cornerArmLength
            ),
            [.right, .top],
            "the top-right external corner arm acquires diagonal resize"
        )
        try expect(
            MirrorWindowGeometry.isTopEdgeHoverTarget(
                CGPoint(x: 224, y: 819),
                in: generousPhoneBounds,
                activationWidth: 10
            ),
            "the header trigger remains the top ten visible phone points"
        )
        try expect(
            !MirrorWindowGeometry.isTopEdgeHoverTarget(
                CGPoint(x: 224, y: 836),
                in: generousPhoneBounds,
                activationWidth: 10
            ),
            "the enlarged external halo never reveals the header"
        )
        let externalCornerZones = MirrorWindowGeometry.externalCornerAcquisitionZones(
            around: visiblePhoneFrame,
            thickness: MirrorResizeAcquisitionPolicy.externalHaloWidth,
            armLength: MirrorResizeAcquisitionPolicy.cornerArmLength
        )
        try expectEqual(externalCornerZones.count, 8, "four corners use two wholly external arms each")
        try expect(
            externalCornerZones.allSatisfy { !$0.frame.intersects(visiblePhoneFrame) },
            "external corner panels never overlap a visible phone pixel"
        )
        try expect(
            externalCornerZones.allSatisfy {
                MirrorWindowGeometry.resizeCursor(for: $0.edges) == .topLeftBottomRight ||
                    MirrorWindowGeometry.resizeCursor(for: $0.edges) == .bottomLeftTopRight
            },
            "every external corner panel always presents a diagonal resize cursor"
        )
        try expect(
            externalCornerZones.contains { $0.frame.contains(CGPoint(x: 88, y: 150)) },
            "the bottom-left vertical arm remains targetable just outside the phone"
        )
        try expect(
            externalCornerZones.contains { $0.frame.contains(CGPoint(x: 150, y: 88)) },
            "the bottom-left corner keeps a usable horizontal acquisition arm"
        )
        try expect(
            !externalCornerZones.contains { $0.frame.contains(CGPoint(x: 300, y: 88)) },
            "the middle of the straight bottom edge must remain click-through"
        )
        try expect(
            !externalCornerZones.contains { $0.frame.contains(CGPoint(x: 88, y: 500)) },
            "the straight external left side remains outside every acquisition window"
        )
        let outerHaloFrame = MirrorWindowGeometry.outerFrame(
            aroundVisiblePhoneFrame: visiblePhoneFrame,
            haloWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth
        )
        try expectEqual(
            outerHaloFrame,
            CGRect(x: 76, y: 76, width: 448, height: 848),
            "the resize halo expands only outside the visible phone"
        )
        try expectEqual(
            MirrorWindowGeometry.visiblePhoneFrame(
                inOuterFrame: outerHaloFrame,
                haloWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth
            ),
            visiblePhoneFrame,
            "removing the halo restores every visible phone pixel"
        )
        try expectEqual(
            MirrorWindowGeometry.outerSize(
                aroundVisiblePhoneSize: CGSize(width: 280, height: 560),
                haloWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth
            ),
            CGSize(width: 328, height: 608),
            "minimum outer window size includes the transparent halo"
        )

        let haloHeader = MirrorWindowGeometry.headerPlacement(
            parentFrame: MirrorWindowGeometry.visiblePhoneFrame(
                inOuterFrame: outerHaloFrame,
                haloWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth
            ),
            panelHeight: 52,
            transparentBridgeHeight: 8
        )
        try expectEqual(
            haloHeader.panelFrame,
            CGRect(x: 100, y: 892, width: 400, height: 52),
            "the detached header follows the visible phone rather than the invisible halo"
        )
        try expect(
            !haloHeader.visibleHeaderFrame.intersects(visiblePhoneFrame),
            "the halo does not make the visible header occlude phone content"
        )

        let baseBehavior: NSWindow.CollectionBehavior = [.managed, .fullScreenAuxiliary]
        let pinned = MirrorWindowPinPolicy.collectionBehavior(base: baseBehavior, isPinned: true)
        try expect(
            !pinned.contains(.managed),
            "pinning must remove .managed because AppKit permits at most one of managed/transient/stationary"
        )
        try expect(pinned.contains(.canJoinAllSpaces), "pinned window joins every Space")
        try expect(pinned.contains(.fullScreenAuxiliary), "pinned window remains available with full-screen apps")
        try expect(pinned.contains(.stationary), "pinned window remains stationary across Spaces")

        let transientPinned = MirrorWindowPinPolicy.collectionBehavior(base: [.transient], isPinned: true)
        try expect(
            !transientPinned.contains(.transient),
            "pinning must remove .transient because AppKit permits at most one of managed/transient/stationary"
        )

        let primaryPinned = MirrorWindowPinPolicy.collectionBehavior(
            base: [.managed, .fullScreenPrimary],
            isPinned: true
        )
        try expect(
            !primaryPinned.contains(.fullScreenPrimary),
            "pinning must remove .fullScreenPrimary before adding .fullScreenAuxiliary"
        )
        try expect(
            primaryPinned.contains(.fullScreenAuxiliary),
            "pinned mirror remains visible beside full-screen apps"
        )

        let unpinned = MirrorWindowPinPolicy.collectionBehavior(base: baseBehavior, isPinned: false)
        try expectEqual(unpinned, baseBehavior, "unpinning removes only GalaxyBridge pin behavior")
        try expectEqual(MirrorWindowPinPolicy.level(isPinned: true), .floating, "pinned level")
        try expectEqual(MirrorWindowPinPolicy.level(isPinned: false), .normal, "unpinned level")

        let seamlessFocusableStyle = MirrorWindowActivationPolicy.seamlessFocusableStyleMask(
            from: [.titled, .fullSizeContentView, .resizable]
        )
        try expect(
            !seamlessFocusableStyle.contains(.titled),
            "the seamless viewer must not retain AppKit's native title-bar composition"
        )
        try expect(
            !seamlessFocusableStyle.contains(.fullSizeContentView),
            "a borderless viewer must not depend on title-bar layout flags"
        )
        try expect(
            !seamlessFocusableStyle.contains(.resizable),
            "the exact-size phone window must not expose AppKit straight-edge resize hit zones"
        )
        try expect(
            seamlessFocusableStyle.contains(.closable) && seamlessFocusableStyle.contains(.miniaturizable),
            "removing native resize must preserve the seamless window's standard window capabilities"
        )
        let focusableMirror = SeamlessMirrorWindow(
            contentRect: CGRect(x: 0, y: 0, width: 432, height: 832),
            styleMask: seamlessFocusableStyle,
            backing: .buffered,
            defer: false
        )
        try expect(
            focusableMirror.canBecomeKey,
            "the custom borderless mirror must regain keyboard focus without native chrome"
        )
        try expect(
            focusableMirror.canBecomeMain,
            "the custom borderless mirror must remain a main window without native resize"
        )
        try expectEqual(
            focusableMirror.contentLayoutRect,
            focusableMirror.contentView?.bounds ?? .zero,
            "every window content point belongs to the halo or visible phone, never a title bar"
        )
        try expect(
            focusableMirror.standardWindowButton(.closeButton) == nil &&
                focusableMirror.standardWindowButton(.miniaturizeButton) == nil &&
                focusableMirror.standardWindowButton(.zoomButton) == nil,
            "the seamless viewer must not instantiate native traffic lights"
        )

        let resizeBounds = CGRect(x: 0, y: 0, width: 432, height: 832)
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 16, y: 400),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "the visible phone edge belongs to Android input, never window resize"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 16.1, y: 400),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "phone content immediately inside the visible edge remains interactive"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 200, y: 16),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "the visible bottom edge belongs to Android input"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 415.9, y: 815.9),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "phone pixels next to the top-right contour remain Android input"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 8, y: 400),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "the external left straight edge stays click-through"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 424, y: 400),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "the external right straight edge stays click-through"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 200, y: 824),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "the external top straight edge stays click-through"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 200, y: 8),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "the external bottom straight edge stays click-through"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 8, y: 50),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [.left, .bottom],
            "the external corner has a long easy-to-acquire vertical arm"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 50, y: 8),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [.left, .bottom],
            "the external corner has a long easy-to-acquire horizontal arm"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 424, y: 8),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [.right, .bottom],
            "the bottom-right external corner remains easy to acquire"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 8, y: 782),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [.left, .top],
            "the top-left external corner has a long vertical arm"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: 382, y: 824),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [.right, .top],
            "the top-right external corner has a long horizontal arm"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeEdges(
                at: CGPoint(x: -1, y: 400),
                in: resizeBounds,
                edgeHitWidth: 16,
                cornerHitSize: 44
            ),
            [],
            "points beyond the outer window do not resize"
        )
        let visiblePhoneBounds = resizeBounds.insetBy(dx: 16, dy: 16)
        try expect(
            MirrorWindowGeometry.isTopEdgeHoverTarget(
                CGPoint(x: 200, y: 811),
                in: visiblePhoneBounds,
                activationWidth: 10
            ),
            "top ten pixels reveal the detached header"
        )
        try expect(
            !MirrorWindowGeometry.isTopEdgeHoverTarget(
                CGPoint(x: 200, y: 824),
                in: visiblePhoneBounds,
                activationWidth: 10
            ),
            "the external resize halo does not reveal the detached header"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeCursor(for: [.left]),
            .horizontal,
            "vertical borders use a horizontal resize cursor"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeCursor(for: [.top]),
            .vertical,
            "horizontal borders use a vertical resize cursor"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeCursor(for: [.left, .top]),
            .topLeftBottomRight,
            "top-left corner uses a diagonal cursor"
        )
        try expectEqual(
            MirrorWindowGeometry.resizeCursor(for: [.right, .top]),
            .bottomLeftTopRight,
            "top-right corner uses the opposite diagonal cursor"
        )

        let resizeStart = CGRect(x: 100, y: 100, width: 400, height: 800)
        let unconstrainedScreen = CGRect(x: -2_000, y: -2_000, width: 4_000, height: 4_000)
        let rightResize = MirrorWindowGeometry.resizedFrame(
            from: resizeStart,
            edges: [.right],
            mouseDelta: CGPoint(x: 100, y: 0),
            aspectRatio: 0.5,
            visibleFrame: unconstrainedScreen,
            minimumShortEdge: 280
        )
        try expectEqual(rightResize, CGRect(x: 100, y: 0, width: 500, height: 1_000), "right resize preserves aspect and opposite edge")

        let topResize = MirrorWindowGeometry.resizedFrame(
            from: resizeStart,
            edges: [.top],
            mouseDelta: CGPoint(x: 0, y: 100),
            aspectRatio: 0.5,
            visibleFrame: unconstrainedScreen,
            minimumShortEdge: 280
        )
        try expectEqual(topResize, CGRect(x: 75, y: 100, width: 450, height: 900), "top resize preserves aspect and bottom edge")

        let bottomLeftResize = MirrorWindowGeometry.resizedFrame(
            from: resizeStart,
            edges: [.left, .bottom],
            mouseDelta: CGPoint(x: -50, y: -100),
            aspectRatio: 0.5,
            visibleFrame: unconstrainedScreen,
            minimumShortEdge: 280
        )
        try expectEqual(
            bottomLeftResize,
            CGRect(x: 50, y: 0, width: 450, height: 900),
            "corner resize preserves aspect and the opposite corner"
        )

        let outerRightResize = MirrorWindowGeometry.resizedOuterFrame(
            from: outerHaloFrame,
            haloWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth,
            edges: [.right],
            mouseDelta: CGPoint(x: 100, y: 0),
            aspectRatio: 0.5,
            visibleFrame: unconstrainedScreen,
            minimumShortEdge: 280
        )
        try expectEqual(
            outerRightResize,
            CGRect(x: 76, y: -24, width: 548, height: 1_048),
            "external right-edge drag resizes the visible phone and carries the halo"
        )
        let resizedVisiblePhone = MirrorWindowGeometry.visiblePhoneFrame(
            inOuterFrame: outerRightResize,
            haloWidth: MirrorResizeAcquisitionPolicy.externalHaloWidth
        )
        try expectEqual(
            resizedVisiblePhone,
            CGRect(x: 100, y: 0, width: 500, height: 1_000),
            "external resize preserves the opposite visible edge"
        )
        try expect(
            abs(resizedVisiblePhone.width / resizedVisiblePhone.height - 0.5) < 0.000_001,
            "the visible video, not the transparent outer window, keeps the device aspect"
        )

        let parentWindow = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 400, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let headerPanel = NSPanel(
            contentRect: CGRect(x: 100, y: 900, width: 400, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        try expect(!headerPanel.canBecomeKey, "the detached header and its buttons must never retain keyboard focus")
        parentWindow.addChildWindow(headerPanel, ordered: .above)
        try expect(
            MirrorWindowDragTarget.resolve(from: headerPanel) === parentWindow,
            "dragging the detached header must target its phone parent"
        )
        try expect(
            MirrorWindowDragTarget.resolve(from: parentWindow) === parentWindow,
            "dragging a standalone mirror targets itself"
        )
        parentWindow.removeChildWindow(headerPanel)

        print("PASS Mirror window geometry preserves aspect, live resize, resize hit zones, attached header drag, and pin policy")
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
