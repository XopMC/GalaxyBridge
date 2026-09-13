import Foundation

@main
private enum AppWindowHeaderVisibilitySpec {
    static func main() {
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }
        var header = AppWindowHeaderVisibility()
        expect(!header.isVisible && header.pendingHideID == nil, "header starts hidden")
        header.setTopEdgeHovered(true)
        expect(header.isVisible && header.pendingHideID == nil, "edge reveals immediately")

        // NSView's mouseExited can arrive before SwiftUI's header hover enter.
        header.setTopEdgeHovered(false)
        let edgeExit = header.pendingHideID!
        expect(header.isVisible, "moving away from the 10pt edge must not hide the buttons")
        header.setControlsHovered(true)
        expect(header.isVisible && header.pendingHideID == nil, "full controls band retains header")
        header.completeHide(requestID: edgeExit)
        expect(header.isVisible, "stale timeout cannot hide the hovered controls")
        header.setControlsHovered(true)
        expect(header.pendingHideID == nil, "moving across buttons never starts a hide")

        header.setControlsHovered(false)
        let firstLeave = header.pendingHideID!
        expect(header.isVisible, "grace starts visible")
        header.setControlsHovered(false)
        expect(header.pendingHideID == firstLeave, "duplicate exits do not postpone hiding forever")
        header.setTopEdgeHovered(true)
        header.completeHide(requestID: firstLeave)
        expect(header.isVisible && header.pendingHideID == nil, "reentry cancels pending hide")
        header.setTopEdgeHovered(false)
        let secondLeave = header.pendingHideID!
        expect(secondLeave != firstLeave, "each hide has a fresh identity")
        header.completeHide(requestID: firstLeave)
        expect(header.isVisible && header.pendingHideID == secondLeave, "old deadline cannot win a later leave")
        header.completeHide(requestID: secondLeave)
        expect(!header.isVisible && header.pendingHideID == nil, "current deadline hides outside both regions")

        // The reverse ordering also occurs when the controls overlay appears.
        header.setTopEdgeHovered(true)
        header.setControlsHovered(true)
        header.setTopEdgeHovered(false)
        expect(header.isVisible && header.pendingHideID == nil, "edge exit while controls hovered never hides")
        header.setTopEdgeHovered(true)
        header.setControlsHovered(false)
        expect(header.isVisible && header.pendingHideID == nil, "controls exit while edge hovered never hides")
        header.setTopEdgeHovered(false)
        let disposedTicket = header.pendingHideID!
        header.reset()
        expect(!header.isVisible && header.pendingHideID == nil, "removed view clears state")
        header.setTopEdgeHovered(true)
        header.setTopEdgeHovered(false)
        let reopenedTicket = header.pendingHideID!
        header.completeHide(requestID: disposedTicket)
        expect(header.isVisible && reopenedTicket != disposedTicket, "reopened view rejects disposed work")
        header.completeHide(requestID: reopenedTicket)
        expect(!header.isVisible, "reopened view still hides normally")
        expect(AppWindowHeaderVisibility.hideDelayMilliseconds == 650, "leave grace is 650ms")
        print("PASS app header edge-to-controls retention, grace identity, reentry and disposal")
    }
}
