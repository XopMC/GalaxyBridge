#if !GALAXYBRIDGE_APP_STORE
import Foundation

typealias EnhancedCaptureAbsenceProof = @MainActor @Sendable (UInt32) async throws -> Void

/// A verified phone key authorizes only same-phone absence attestations.
struct VerifiedCaptureRetirementPeer: Sendable {
    let logicalDeviceID: String
    let deviceID: String
    let publicKeySHA256: Data

    init?(logicalDeviceID: String, bindingDeviceID: String, publicKeySHA256: Data, bindingVerified: Bool) {
        guard bindingVerified, !bindingDeviceID.isEmpty,
              logicalDeviceID == "device:\(bindingDeviceID)", publicKeySHA256.count == 32 else { return nil }
        self.logicalDeviceID = logicalDeviceID
        deviceID = bindingDeviceID
        self.publicKeySHA256 = publicKeySHA256
    }

    func accepts(deviceID: String, publicKeySHA256: Data, authenticated: Bool) -> Bool {
        authenticated && self.deviceID == deviceID && self.publicKeySHA256 == publicKeySHA256
    }
}

/// Unpaired USB captures share this handle with their panel owner. Initial
/// pairing may freeze its identity once, while that exact ADB route is live.
/// A later advertisement, lost route or replacement key cannot retarget it.
@MainActor
final class CaptureRetirementAuthority {
    let captureSerial: String
    private(set) var peer: VerifiedCaptureRetirementPeer?
    let captureGeneration: UUID?
    init(captureSerial: String, peer: VerifiedCaptureRetirementPeer?, generation: UUID?) {
        self.captureSerial = captureSerial; self.peer = peer; captureGeneration = generation
    }
    @discardableResult func adopt(_ peer: VerifiedCaptureRetirementPeer, currentADBSerial: String?, generation: UUID?) -> Bool {
        guard self.peer == nil, !captureSerial.hasPrefix("shell:"), currentADBSerial == captureSerial,
              let generation, captureGeneration == generation else { return false }
        self.peer = peer
        return true
    }
}

struct CaptureRouteHandoffPlan: Equatable, Sendable {
    let destinationSerial: String
    let requiresMigration: Bool

    static func resolve(deviceReady: Bool, adbSerial: String?, helperDeviceID: String?,
                        capturedSerials: Set<String>, retirementsPending: Bool, windowsPending: Bool,
                        generationChanged: Bool = false) -> Self? {
        guard deviceReady else { return nil }
        guard let destination = destination(adbSerial: adbSerial, helperDeviceID: helperDeviceID, capturedSerials: capturedSerials) else { return nil }
        let raw = capturedSerials.filter { !$0.hasPrefix("shell:") }
        let migrate = generationChanged || raw.contains { $0 != destination }
        guard migrate || retirementsPending || windowsPending else { return nil }
        return Self(destinationSerial: destination, requiresMigration: migrate)
    }

    static func destination(adbSerial: String?, helperDeviceID: String?, capturedSerials: Set<String>) -> String? {
        let adb = adbSerial.flatMap { $0.isEmpty ? nil : $0 }
        let shell = helperDeviceID.flatMap { $0.isEmpty ? nil : "shell:" + $0 }
        // Attaching USB must not interrupt a surviving prepared Shell owner.
        return shell.flatMap { capturedSerials.contains($0) ? $0 : nil } ?? adb ?? shell
    }
}

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
