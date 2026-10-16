#if !GALAXYBRIDGE_APP_STORE
import Foundation

/// A cleanup alias backed by the same persisted, currently verified identity.
/// This transfers only cleanup authority; capture generations stay immutable.
struct VerifiedEnhancedRetirementRoute {
    let captureSerial: String
    let routeSerial: String

    init?(logicalDeviceID: String, captureSerial: String, routeSerial: String,
          captureBindingDeviceID: String, routeBindingDeviceID: String,
          captureIdentity: Data, routeIdentity: Data, routeCurrentlyVerified: Bool) {
        guard routeCurrentlyVerified, !captureSerial.isEmpty, !routeSerial.isEmpty,
              logicalDeviceID == "device:\(captureBindingDeviceID)",
              captureBindingDeviceID == routeBindingDeviceID,
              !captureIdentity.isEmpty, captureIdentity == routeIdentity else { return nil }
        self.captureSerial = captureSerial; self.routeSerial = routeSerial
    }
}

@MainActor
final class EnhancedRemoteRetirementFence {
    let captureSerial: String
    private(set) var cleanupSerial: String
    private var pending = Set<UInt32>()
    var settled: Bool { pending.isEmpty }

    init(captureSerial: String) { self.captureSerial = captureSerial; cleanupSerial = captureSerial }

    func requireRetirement(scid: UInt32) { pending.insert(scid) }

    @discardableResult func install(_ route: VerifiedEnhancedRetirementRoute) -> Bool {
        guard route.captureSerial == captureSerial else { return false }
        cleanupSerial = route.routeSerial
        return true
    }

    func retire(_ operation: (String, UInt32) async throws -> Void) async {
        for scid in pending.sorted() {
            for _ in 0 ..< 2 {
                let attemptedSerial = cleanupSerial
                do {
                    try await operation(attemptedSerial, scid)
                    pending.remove(scid)
                    break
                } catch {
                    // A verified route can arrive while old USB I/O awaits.
                    // Retry that same SCID once through the newer alias.
                    if attemptedSerial == cleanupSerial { break }
                }
            }
        }
    }
}
#endif
