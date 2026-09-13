#if !GALAXYBRIDGE_APP_STORE
import Foundation

enum ADBCompanionTunnelError: Error, Equatable {
    case stopped, revoked, invalidBinding, capacity, serialRetiring, invalidForward, ownershipUncertain, cleanupFailed
}

struct ADBCompanionTunnelLease: Sendable, Equatable {
    let token: UUID
    let peerID: String
    let serial: String
    let port: UInt16
    let host = "127.0.0.1"
}

struct ADBCompanionTunnelResource: Sendable {
    let port: UInt16
    let remove: @Sendable () throws -> Void
}

/// A forward is only a transport. The caller must still pin the peer's TLS certificate and
/// perform signed session authentication on every channel before trusting this endpoint.
actor ADBCompanionTunnelCoordinator {
    typealias Allocate = @Sendable (String) throws -> ADBCompanionTunnelResource
    private struct Entry {
        let token: UUID
        let serial: String
        let task: Task<ADBCompanionTunnelResource, Error>
    }
    private let allocate: Allocate
    private var entries: [String: Entry] = [:]
    private var revoked: Set<String> = []
    private var retiringSerials: Set<String> = []
    private var retirements: [UUID: Task<Void, Error>] = [:]
    private var retiringEntries: [UUID: Entry] = [:]
    private var quarantined: [String: Entry] = [:]
    private var stopped = false
    private let capacity: Int

    init(capacity: Int = 8, allocate: @escaping Allocate) {
        self.capacity = max(1, min(32, capacity)); self.allocate = allocate
    }

    init(clientFactory: @escaping @Sendable () throws -> ADBClient = { try ADBClient() }) {
        capacity = 8
        allocate = { serial in try Self.allocateForward(serial: serial, client: clientFactory()) }
    }

    /// peerID must include the verified pairing generation. Never call this using an
    /// unverified USB serial/name as peer identity. Repeated acquisition shares one endpoint.
    func acquire(peerID: String, serial: String) async throws -> ADBCompanionTunnelLease {
        guard !stopped else { throw ADBCompanionTunnelError.stopped }
        guard !revoked.contains(peerID) else { throw ADBCompanionTunnelError.revoked }
        guard !peerID.isEmpty, peerID.utf8.count <= 512, !serial.isEmpty, serial.utf8.count <= 256,
              !serial.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" })
        else { throw ADBCompanionTunnelError.invalidBinding }
        guard quarantined[serial] == nil else { throw ADBCompanionTunnelError.ownershipUncertain }
        let entry: Entry
        if let existing = entries[peerID] {
            guard existing.serial == serial else { throw ADBCompanionTunnelError.invalidBinding }
            entry = existing
        } else {
            guard entries.count + retirements.count + quarantined.count < capacity else { throw ADBCompanionTunnelError.capacity }
            guard !retiringSerials.contains(serial), !entries.values.contains(where: { $0.serial == serial })
            else { throw ADBCompanionTunnelError.serialRetiring }
            let allocate = self.allocate
            entry = Entry(token: UUID(), serial: serial,
                          task: Task.detached(priority: .utility) { try allocate(serial) })
            entries[peerID] = entry
        }
        do {
            let resource = try await entry.task.value
            guard !stopped, !revoked.contains(peerID), entries[peerID]?.token == entry.token
            else { throw ADBCompanionTunnelError.revoked }
            try Task.checkCancellation()
            return ADBCompanionTunnelLease(token: entry.token, peerID: peerID, serial: serial, port: resource.port)
        } catch {
            // A cancelled waiter does not destroy an endpoint another waiter/consumer uses.
            // A failed allocation has no reusable resource; retiring paths own their cleanup.
            if !(error is CancellationError), entries[peerID]?.token == entry.token {
                entries.removeValue(forKey: peerID)
                if error as? ADBCompanionTunnelError == .ownershipUncertain {
                    quarantined[serial] = entry
                }
            }
            throw error
        }
    }

    /// Retire only this lease occurrence; a late caller cannot remove a replacement lease.
    func release(_ lease: ADBCompanionTunnelLease) async throws {
        guard let entry = entries[lease.peerID], entry.token == lease.token else { return }
        entries.removeValue(forKey: lease.peerID)
        try await retire(entry)
    }

    /// Admission closes before suspension. A new pairing should use a new peerID generation.
    func revoke(peerID: String) async throws {
        guard revoked.count < 1024 || revoked.contains(peerID) else { stopped = true; throw ADBCompanionTunnelError.capacity }
        revoked.insert(peerID)
        if let entry = entries.removeValue(forKey: peerID) { try await retire(entry) }
    }

    /// Await this before shutting down the owned ADB runtime. In-flight creation is allowed
    /// to settle, so its exact allocated port can be retired; we never cancel away its receipt.
    func shutdown() async throws {
        stopped = true
        let admitted = Array(entries.values) + Array(quarantined.values)
        entries.removeAll()
        for entry in admitted { startRetirement(entry) }
        let pending = Array(retirements)
        var failed = false
        for (token, task) in pending {
            do {
                try await task.value
                if let entry = retiringEntries[token], quarantined[entry.serial]?.token == token {
                    quarantined.removeValue(forKey: entry.serial)
                }
            } catch {
                failed = true
                if let entry = retiringEntries[token] { quarantined[entry.serial] = entry }
            }
        }
        retirements.removeAll(); retiringEntries.removeAll(); retiringSerials.removeAll()
        if failed || !quarantined.isEmpty { throw ADBCompanionTunnelError.cleanupFailed }
    }

    private func startRetirement(_ entry: Entry) {
        guard retirements[entry.token] == nil else { return }
        retiringSerials.insert(entry.serial)
        retiringEntries[entry.token] = entry
        retirements[entry.token] = Task.detached(priority: .utility) {
            let resource: ADBCompanionTunnelResource
            do { resource = try await entry.task.value }
            catch {
                // A failed command may still have installed a forward. Losing
                // its receipt is not proof that this serial is safe to reuse.
                if error as? ADBCompanionTunnelError == .ownershipUncertain { throw error }
                return
            }
            try resource.remove()
        }
    }
    private func retire(_ entry: Entry) async throws {
        startRetirement(entry)
        defer {
            retirements.removeValue(forKey: entry.token)
            retiringEntries.removeValue(forKey: entry.token)
            retiringSerials.remove(entry.serial)
        }
        do { try await retirements[entry.token]!.value }
        catch {
            // Retain the exact cleanup closure for shutdown retry, and prevent
            // topology refresh from allocating another forward on this serial.
            quarantined[entry.serial] = entry
            throw error
        }
    }

    private nonisolated static func allocateForward(serial: String, client: ADBClient) throws -> ADBCompanionTunnelResource {
        func matchingPorts() throws -> Set<UInt16> {
            let output = try client.run(arguments: ["forward", "--list"], timeout: 3)
            var ports: Set<UInt16> = []
            for line in output.split(whereSeparator: \.isNewline) {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 3, fields[0] == Substring(serial), fields[2] == "tcp:46737",
                      fields[1].hasPrefix("tcp:"), let port = UInt16(fields[1].dropFirst(4)), port > 0 else { continue }
                ports.insert(port)
            }
            return ports
        }
        let before = try matchingPorts()
        var commandFailure: Error?
        var reported: UInt16?
        do {
            let output = try client.run(arguments: ["-s", serial, "forward", "tcp:0", "tcp:46737"], timeout: 3)
            reported = UInt16(output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { commandFailure = error }
        let after: Set<UInt16>
        do { after = try matchingPorts() }
        catch { throw ADBCompanionTunnelError.ownershipUncertain }
        let created = after.subtracting(before)
        guard created.count == 1, let port = created.first, port > 0 else {
            // No guessed port removal if a command's outcome cannot be established.
            throw ADBCompanionTunnelError.ownershipUncertain
        }
        let remove: @Sendable () throws -> Void = {
            let listing = try client.run(arguments: ["forward", "--list"], timeout: 3)
            let exact = listing.split(whereSeparator: \.isNewline).contains {
                $0.split(whereSeparator: \.isWhitespace).map(String.init) == [serial, "tcp:\(port)", "tcp:46737"]
            }
            guard exact else { return } // Already gone or reassigned; never remove another mapping.
            _ = try client.run(arguments: ["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 3)
        }
        if commandFailure != nil || reported != port {
            do { try remove() }
            catch { throw ADBCompanionTunnelError.ownershipUncertain }
            throw commandFailure ?? ADBCompanionTunnelError.invalidForward
        }
        return ADBCompanionTunnelResource(port: port, remove: remove)
    }
}
#endif
