#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeCore

/// Serializes shell gestures per logical device and caches the physical input
/// coordinate space. This keeps Process work off the main actor while avoiding
/// one `wm size` round trip for every tap.
actor EnhancedADBPositionalInputDispatcher {
    private let adb: ADBClient
    private var displaySize: ADBPhysicalDisplaySize?

    init(adb: ADBClient) {
        self.adb = adb
    }

    func send(serial: String, command: EnhancedADBTouchCommand) throws {
        let size: ADBPhysicalDisplaySize
        if let displaySize {
            size = displaySize
        } else {
            size = try adb.physicalDisplaySize(serial: serial)
            displaySize = size
        }
        try adb.injectTouch(serial: serial, command: command, displaySize: size)
    }

    func invalidateDisplaySize() {
        displaySize = nil
    }
}
#endif
