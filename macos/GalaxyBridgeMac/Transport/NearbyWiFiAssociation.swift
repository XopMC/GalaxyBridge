@preconcurrency import CoreWLAN
import CoreLocation
import Foundation
import Security
import SystemConfiguration

/// CoreWLAN is blocking. All radio calls and restoration run on this one queue;
/// cancellation marks ownership immediately but never abandons a late join.
final class NearbyWiFiAssociation: @unchecked Sendable {
    private final class Lease {
        let name: String
        let interface: CWInterface
        let original: CWNetwork?
        let originalPassword: String?
        var ownership = NearbyAssociationOwnership()
        var ownedBSSID: String?
        init(name: String, interface: CWInterface, original: CWNetwork?, password: String?) {
            self.name = name; self.interface = interface; self.original = original; originalPassword = password
        }
    }
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.nearby-wifi", qos: .utility)
    private let lock = NSLock()
    private var cancelled = Set<UUID>()
    private var lease: Lease?
    func cancel(owner: UUID) { lock.withLock { _ = cancelled.insert(owner) } }
    private func isCancelled(_ owner: UUID) -> Bool { lock.withLock { cancelled.contains(owner) } }

    func isUnassociated() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: unassociatedOnQueue()) }
        }
    }
    private func unassociatedOnQueue() -> Bool {
        guard lease == nil, let interface = CWWiFiClient.shared().interface() else { return false }
        return positivelyUnassociated(interface)
    }
    private func positivelyUnassociated(_ interface: CWInterface) -> Bool {
        guard CLLocationManager().authorizationStatus == .authorizedAlways, interface.powerOn(),
              let name = interface.interfaceName, interface.ssid() == nil, interface.bssid() == nil,
              interface.wlanChannel() == nil,
              let link = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any],
              let active = link["Active"] as? Bool else { return false }
        return !active
    }

    func join(name: String, password: String, owner: UUID, automatic: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard !isCancelled(owner), (1...32).contains(name.utf8.count), (8...63).contains(password.utf8.count)
                    else { throw NearbyTransportFailure.association }
                    guard !automatic || unassociatedOnQueue() else { throw NearbyTransportFailure.ownership }
                    if let lease {
                        guard lease.name == name, lease.interface.ssid() == name,
                              lease.ownedBSSID == lease.interface.bssid() else { throw NearbyTransportFailure.ownership }
                        guard lease.ownership.acquire(owner: owner, network: name) else { throw NearbyTransportFailure.ownership }
                    } else {
                        guard CLLocationManager().authorizationStatus == .authorizedAlways,
                              let interface = CWWiFiClient.shared().interface() else { throw NearbyTransportFailure.unavailable }
                        let before = interface.ssid()
                        var original: CWNetwork?, secret: NSString?
                        if let before {
                            original = try interface.scanForNetworks(withSSID: Data(before.utf8)).first(where: { $0.ssid == before })
                            guard let original else { throw NearbyTransportFailure.association }
                            if !original.supportsSecurity(.none) {
                                guard CWKeychainFindWiFiPassword(.user, Data(before.utf8), &secret) == errSecSuccess
                                else { throw NearbyTransportFailure.association }
                            }
                        }
                        guard !isCancelled(owner) else { throw CancellationError() }
                        let created = Lease(name: name, interface: interface, original: original, password: secret as String?)
                        created.ownedBSSID = before == name ? interface.bssid() : nil
                        guard created.ownership.acquire(owner: owner, network: name) else { throw NearbyTransportFailure.ownership }
                        lease = created
                        if before != name {
                            guard let network = try interface.scanForNetworks(withSSID: Data(name.utf8)).first(where: { $0.ssid == name })
                            else { throw NearbyTransportFailure.association }
                            guard !isCancelled(owner) else { throw CancellationError() }
                            // Arm compare-and-restore ownership BEFORE the
                            // blocking call: it can apply and still throw.
                            guard let expectedBSSID = network.bssid else { throw NearbyTransportFailure.ownership }
                            created.ownedBSSID = expectedBSSID
                            try interface.associate(to: network, password: password)
                        }
                        guard created.ownedBSSID == interface.bssid() else { throw NearbyTransportFailure.ownership }
                    }
                    guard !isCancelled(owner), lease?.interface.ssid() == name else { throw CancellationError() }
                    continuation.resume()
                } catch {
                    do { try releaseOnQueue(owner: owner) } catch { /* Retain failed restoration lease for another explicit cleanup. */ }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func release(owner: UUID) async throws {
        cancel(owner: owner)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do { try releaseOnQueue(owner: owner); continuation.resume() }
                catch { continuation.resume(throwing: NearbyTransportFailure.association) }
            }
        }
    }

    private func releaseOnQueue(owner: UUID) throws {
        defer { lock.withLock { _ = cancelled.remove(owner) } }
        guard let lease else { return }
        let finalOwner = lease.ownership.release(owner: owner)
        // A failed last-owner restoration retains this lease with no owners,
        // allowing a later explicit release to retry the same owned cleanup.
        guard finalOwner || lease.ownership.network == nil else { return }
        // Do not replace an association chosen by the user or another program.
        // Exact STOP may remove the phone AP before its receipt is processed.
        // A positively absent association is safe to restore; privacy-redacted
        // or unknown state and any newly chosen association remain untouched.
        if NearbyAssociationRestoration.permits(currentName: lease.interface.ssid(), currentBSSID: lease.interface.bssid(),
            ownedName: lease.name, ownedBSSID: lease.ownedBSSID, positivelyUnassociated: positivelyUnassociated(lease.interface)),
           lease.original?.ssid != lease.name {
            if let original = lease.original { try lease.interface.associate(to: original, password: lease.originalPassword) }
            else { lease.interface.disassociate() }
        }
        self.lease = nil
    }
}
