import Foundation

@MainActor class NSWindow {
    struct CollectionBehavior: OptionSet, Sendable {
        let rawValue: Int
        static let participatesInCycle = Self(rawValue: 1)
        static let ignoresCycle = Self(rawValue: 2)
        static let canJoinAllSpaces = Self(rawValue: 4)
        static let fullScreenAuxiliary = Self(rawValue: 8)
        static let stationary = Self(rawValue: 16)
        static let managed = Self(rawValue: 32)
        static let transient = Self(rawValue: 64)
        static let fullScreenPrimary = Self(rawValue: 128)
        static let fullScreenNone = Self(rawValue: 256)
    }
    enum Level { case normal, floating }
    var collectionBehavior: CollectionBehavior = [.managed, .ignoresCycle]
    var level = Level.normal
    var title = "Phone"
    var isExcludedFromWindowsMenu = true
    weak var delegate: AnyObject?
}
@MainActor final class SeamlessMirrorWindow: NSWindow {
    var retired = false
    func retireSeamlessPresentation() { retired = true }
}
@MainActor final class WindowMenuProbe {
    var added: [ObjectIdentifier] = [], changed: [ObjectIdentifier] = [], removed: [ObjectIdentifier] = []
    func addWindowsItem(_ window: NSWindow, title: String, filename: Bool) { added.append(ObjectIdentifier(window)) }
    func changeWindowsItem(_ window: NSWindow, title: String, filename: Bool) { changed.append(ObjectIdentifier(window)) }
    func removeWindowsItem(_ window: NSWindow) { removed.append(ObjectIdentifier(window)) }
}
@MainActor enum NSApplication { static let shared = WindowMenuProbe() }
// ACTUAL_CYCLE_POLICY
@MainActor final class PresenterProbe {
    var windowsByDeviceID: [String: SeamlessMirrorWindow] = [:]
    var closeHandlersByWindowID: [ObjectIdentifier: () -> Void] = [:]
    var leasesByWindowID: [ObjectIdentifier: UUID] = [:]
    // ACTUAL_PRESENTER_METHODS
}
@MainActor final class ConfiguratorProbe {
    var baseCollectionBehavior: NSWindow.CollectionBehavior?
    var resizePanels: [NSWindow] = []
    // ACTUAL_PIN_METHODS
    func headerBehavior(parent: NSWindow, isPinned: Bool) -> NSWindow.CollectionBehavior {
        let panel = NSWindow()
        panel.isExcludedFromWindowsMenu = false
        // ACTUAL_HEADER_ASSIGNMENT
        precondition(panel.isExcludedFromWindowsMenu)
        return panel.collectionBehavior
    }
    func resizeBehavior(parent: NSWindow) -> NSWindow.CollectionBehavior {
        let panel = NSWindow()
        panel.isExcludedFromWindowsMenu = false
        // ACTUAL_RESIZE_ASSIGNMENT
        precondition(panel.isExcludedFromWindowsMenu)
        return panel.collectionBehavior
    }
}
@main enum MirrorWindowCycleSpec {
    @MainActor static func main() {
        let presenter = PresenterProbe(), primary = SeamlessMirrorWindow()
        var closed = 0
        presenter.registerPrimaryWindow(primary, forDeviceID: "A", onClose: { closed += 1 })
        precondition(primary.collectionBehavior.contains(.participatesInCycle) && !primary.collectionBehavior.contains(.ignoresCycle),
            "An owned borderless primary mirror must explicitly participate in native window cycling")
        precondition(!primary.isExcludedFromWindowsMenu && NSApplication.shared.added == [ObjectIdentifier(primary)],
            "The owned phone mirror is absent from the native Window menu")
        primary.title = "Renamed phone"
        presenter.registerPrimaryWindow(primary, forDeviceID: "A")
        precondition(NSApplication.shared.added.count == 1 && NSApplication.shared.changed == [ObjectIdentifier(primary)],
            "Repeated registration must update one native Window entry")
        let config = ConfiguratorProbe(), resize = NSWindow()
        resize.isExcludedFromWindowsMenu = false
        config.resizePanels = [resize]
        for pinned in [true, false, true] {
            config.updatePinPolicy(for: primary, isPinned: pinned)
            precondition(primary.collectionBehavior.contains(.participatesInCycle) && !primary.collectionBehavior.contains(.ignoresCycle),
                "Pinning must preserve the primary's explicit cycle participation")
            precondition(primary.level == (pinned ? .floating : .normal))
            precondition(resize.isExcludedFromWindowsMenu)
            if pinned { precondition(primary.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]) && !primary.collectionBehavior.contains(.managed)) }
            else { precondition(primary.collectionBehavior.contains(.managed) && !primary.collectionBehavior.contains(.stationary)) }
            for behavior in [resize.collectionBehavior, config.headerBehavior(parent: primary, isPinned: pinned), config.resizeBehavior(parent: primary)] {
                precondition(behavior.contains(.ignoresCycle) && !behavior.contains(.participatesInCycle),
                    "Header/resize child panels must not inherit primary cycle participation")
            }
        }
        let second = SeamlessMirrorWindow()
        presenter.registerPrimaryWindow(second, forDeviceID: "B")
        let other = NSWindow()
        presenter.windowWillClose(Notification(name: Notification.Name("close"), object: other))
        precondition(NSApplication.shared.removed.isEmpty, "Unowned main windows must retain native lifecycle ownership")
        presenter.windowWillClose(Notification(name: Notification.Name("close"), object: primary))
        precondition(NSApplication.shared.removed == [ObjectIdentifier(primary)] && presenter.windowsByDeviceID["B"] === second && presenter.windowsByDeviceID.count == 1 && primary.retired && closed == 1,
            "Closing a primary must remove its exact native Window entry and release its existing lease once")
        presenter.windowWillClose(Notification(name: Notification.Name("close"), object: primary))
        precondition(NSApplication.shared.removed.count == 1 && closed == 1, "Repeated close callbacks must not remove another window or release a lease twice")
        print("PASS actual mirror registration/pin/child lifecycle: native Window entry, explicit primary cycle, pinned behavior, excluded auxiliaries, idempotent registration and exact close cleanup")
    }
}
