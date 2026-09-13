/// Per-window hover state shared by the narrow reveal edge and the whole
/// controls band. A hide belongs to one leave event, never to a later visit.
struct AppWindowHeaderVisibility: Equatable {
    static let hideDelayMilliseconds = 650

    private(set) var isVisible = false
    private(set) var pendingHideID: UInt64?
    private var topEdgeHovered = false
    private var controlsHovered = false
    private var nextHideID: UInt64 = 0

    mutating func setTopEdgeHovered(_ hovered: Bool) {
        guard topEdgeHovered != hovered else { return }
        topEdgeHovered = hovered
        updateVisibility()
    }

    mutating func setControlsHovered(_ hovered: Bool) {
        guard controlsHovered != hovered else { return }
        controlsHovered = hovered
        updateVisibility()
    }

    mutating func completeHide(requestID: UInt64) {
        guard pendingHideID == requestID, !topEdgeHovered, !controlsHovered else { return }
        pendingHideID = nil
        isVisible = false
    }

    mutating func reset() {
        isVisible = false
        pendingHideID = nil
        topEdgeHovered = false
        controlsHovered = false
        // Keep the sequence so disposed work cannot match a subsequent visit.
    }

    private mutating func updateVisibility() {
        if topEdgeHovered || controlsHovered {
            pendingHideID = nil
            isVisible = true
        } else if isVisible, pendingHideID == nil {
            nextHideID &+= 1
            pendingHideID = nextHideID
        }
    }
}
