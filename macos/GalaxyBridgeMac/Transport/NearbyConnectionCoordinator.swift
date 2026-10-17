import Combine
@preconcurrency import CoreBluetooth
import CoreLocation
import CryptoKit
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeProtocol

enum NearbyConsentPresentation: Equatable {
    case choosing, requesting, comparing(String), failed(String), manualQR
}

enum NearbyConnectionStatus: Equatable, Sendable {
    case idle, discovering, connecting, authenticating, creatingLink, joiningNetwork, verifying, connected
    case failed(String)
}

/// Advertisements are discovery hints only. All identity, credentials and lease
/// operations are authenticated inside the signed-hello/AEAD session.
@MainActor
final class NearbyConnectionCoordinator: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var statuses: [String: NearbyConnectionStatus] = [:]
    @Published private(set) var nearbyPairingURI: String?
    @Published private(set) var consentPresentation: NearbyConsentPresentation = .choosing
    @Published private(set) var locationPermissionHintKey: String?
    @Published private(set) var discoverySuggestions: [NearbyDiscoverySuggestion] = []
    private static let service = CBUUID(string: "6e5a0001-6b47-4b8f-8f41-54f4a681e602")
    private static let rx = CBUUID(string: "6e5a0002-6b47-4b8f-8f41-54f4a681e602")
    private static let tx = CBUUID(string: "6e5a0003-6b47-4b8f-8f41-54f4a681e602")
    private static let metadata = CBUUID(string: "6e5a0004-6b47-4b8f-8f41-54f4a681e602")
    private final class DiscoveryProbe {
        let peripheral: CBPeripheral
        var deadline: Task<Void, Never>?
        var closing = false
        init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
    }
    private final class Session {
        let peripheral: CBPeripheral
        let generation = UUID()
        let target: String?
        let agreement: NearbyBootstrapAgreement
        let hello: NearbyBootstrapHello
        let sessionID: String
        let offer: NearbyOfflineOffer?
        var deviceID: String?
        var peer: PairedPeer?
        var remoteHello: NearbyBootstrapHello?
        var crypto: NearbyBootstrapSession?
        var decoder = NearbyTransportDecoder()
        var rx: CBCharacteristic?
        var tx: CBCharacteristic?
        var writes: [Data] = []
        var writePending = false
        var leaseID = ""
        var joinOwnerDeviceID: String?
        var remoteLeaseExpiresAt: ContinuousClock.Instant?
        var requestID = ""
        var consentRequest: GBEnvelope?
        var commitTranscript: Data?
        var commitSignature: Data?
        var descriptor: GBDirectLinkDescriptor?
        var lifetime = NearbyLinkLifetime()
        var confirmation: (requestID: String, continuation: CheckedContinuation<Void, Error>, timeout: Task<Void, Never>)?
        var renewalState: NearbyLeaseRenewalState?
        var renewal: Task<Void, Never>?
        var work: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var polling: Task<Void, Never>?
        var closeDeadline: Task<Void, Never>?
        var anchor = false
        var automatic = false
        var groupMember: NearbyGroupMember {
            NearbyGroupMember(generation: generation, deviceID: deviceID, target: target,
                ownerDeviceID: joinOwnerDeviceID ?? descriptor?.ownerDeviceID, anchor: anchor)
        }
        init(peripheral: CBPeripheral, target: String?, agreement: NearbyBootstrapAgreement,
             hello: NearbyBootstrapHello, sessionID: String, offer: NearbyOfflineOffer?) {
            self.peripheral = peripheral; self.target = target; self.agreement = agreement
            self.hello = hello; self.sessionID = sessionID; self.offer = offer
        }
    }
    private let peers: () -> [PairedPeer]
    private let onDescriptor: (GBDirectLinkDescriptor) -> Void
    private let onPairingCommitted: () -> Void
    private let onVerifiedPairing: (String) -> Void
    private let onReleaseLease: @MainActor (String, String) async -> Bool
    private let onRenewLease: @MainActor (String, String) async -> Bool
    private let identity = KeychainIdentityStore()
    private let peerStore = PairedPeerStore()
    private let wifi = NearbyWiFiAssociation()
    private var central: CBCentralManager?
    private let location = CLLocationManager()
    private var discoveryWanted = false
    private var candidates: [UUID: CBPeripheral] = [:]
    private var discoveryCatalog = NearbyDiscoveryCatalog()
    private let discoveryOrigin = ContinuousClock.now
    private var discoveryMaintenance: Task<Void, Never>?
    private var discoveryProbe: DiscoveryProbe?
    private var offerCandidateID: UUID?
    private var offerRetryBudget = NearbyPairingRetryBudget()
    private var offerRetry: Task<Void, Never>?
    private var sessions: [UUID: Session] = [:]
    private var retiring: [UUID: Session] = [:]
    private var requested = Set<String>()
    private var automaticTargets = Set<String>()
    private var autoTickets: [String: UUID] = [:]
    private var lifecycle = UUID()
    private var tried: [String: Set<UUID>] = [:]
    private var targetDeadlines: [String: Task<Void, Never>] = [:]
    private var retirements: [UUID: Task<Void, Never>] = [:]
    private var offer: NearbyOfflineOffer?
    private var offerExpiry: Task<Void, Never>?
    private var sharedDescriptor: GBDirectLinkDescriptor?
    private var groupAdmission = NearbyGroupAdmission()
    private var groupCleanup: [UUID: NearbyGroupRetirementState] = [:]
    private var groupCleanupDeviceIDs: [UUID: String] = [:]
    private var groupCleanupTimers: [UUID: Task<Void, Never>] = [:]
    private var groupCleanupRetries: [UUID: Task<Void, Never>] = [:]

    init(peers: @escaping () -> [PairedPeer], onDescriptor: @escaping (GBDirectLinkDescriptor) -> Void,
         onPairingCommitted: @escaping () -> Void,
         onVerifiedPairing: @escaping (String) -> Void = { _ in },
         onReleaseLease: @escaping @MainActor (String, String) async -> Bool = { _, _ in false },
         onRenewLease: @escaping @MainActor (String, String) async -> Bool = { _, _ in false }) {
        self.peers = peers; self.onDescriptor = onDescriptor; self.onPairingCommitted = onPairingCommitted
        self.onVerifiedPairing = onVerifiedPairing
        self.onReleaseLease = onReleaseLease
        self.onRenewLease = onRenewLease
        super.init(); location.delegate = self
    }

    private func updateLocationPermissionHint() {
        let key: String? = switch location.authorizationStatus {
        case .denied, .restricted: "NEARBY_LOCATION_PERMISSION_HINT"
        default: nil
        }
        if locationPermissionHintKey != key { locationPermissionHintKey = key }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateLocationPermissionHint()
    }

    func startDiscovery() {
        discoveryWanted = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if central?.state == .poweredOn { central?.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
        if discoveryMaintenance == nil {
            discoveryMaintenance = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self, self.discoveryWanted else { return }
                    self.refreshDiscovery(); self.pumpDiscoveryProbe()
                }
            }
        }
        for peer in peers() where statuses[peer.deviceID] == nil { statuses[peer.deviceID] = .discovering }
    }

    func connect(deviceID: String) {
        autoTickets.removeValue(forKey: deviceID)
        beginConnect(deviceID: deviceID, automatic: false)
    }

    func isConnectionRequested(deviceID: String) -> Bool {
        requested.contains(deviceID) || autoTickets[deviceID] != nil
    }

    func autoConnectIfUnassociated(deviceID: String) {
        guard location.authorizationStatus == .authorizedAlways,
              peers().contains(where: { $0.deviceID == deviceID }), !requested.contains(deviceID), autoTickets[deviceID] == nil else { return }
        let group = sharedDescriptor
        if let group, !hasVerifiedSharedOwner(group) { return }
        let ticket = UUID(), generation = lifecycle
        autoTickets[deviceID] = ticket
        Task { [weak self, wifi] in
            let permitted: Bool
            if let group { permitted = await wifi.isOwnedAssociation(name: group.networkName) }
            else { permitted = await wifi.isUnassociated() }
            guard let self, self.lifecycle == generation, self.autoTickets[deviceID] == ticket else { return }
            self.autoTickets.removeValue(forKey: deviceID)
            guard permitted, self.sharedDescriptor == group,
                  self.location.authorizationStatus == .authorizedAlways,
                  self.peers().contains(where: { $0.deviceID == deviceID }), !self.requested.contains(deviceID) else { return }
            if let group, !self.hasVerifiedSharedOwner(group) { return }
            self.beginConnect(deviceID: deviceID, automatic: true)
        }
    }

    func cancelAutomaticConnection(deviceID: String) {
        autoTickets.removeValue(forKey: deviceID)
        guard automaticTargets.contains(deviceID), statuses[deviceID] != .connected else { return }
        disconnect(deviceID: deviceID)
    }

    private func hasVerifiedSharedOwner(_ descriptor: GBDirectLinkDescriptor) -> Bool {
        guard let owner = sessions.values.first(where: { $0.deviceID == descriptor.ownerDeviceID && $0.lifetime.verified &&
            $0.descriptor?.networkName == descriptor.networkName && $0.descriptor?.ownerDeviceID == descriptor.ownerDeviceID }) else { return false }
        return admitsTrustedSession(owner)
    }

    private func beginConnect(deviceID: String, automatic: Bool) {
        guard peers().contains(where: { $0.deviceID == deviceID }) else { statuses[deviceID] = .failed("peer_not_paired"); return }
        retryGroupCleanup()
        if let anchor = sessions.values.first(where: { $0.deviceID == deviceID && $0.anchor }) {
            guard admitsTrustedSession(anchor) else { return }
            anchor.anchor = false; requested.insert(deviceID); statuses[deviceID] = .connected
            if let descriptor = anchor.descriptor { onDescriptor(descriptor) }; return
        }
        guard sessions.values.allSatisfy({ $0.deviceID != deviceID && $0.target != deviceID }) else { return }
        guard requested.contains(deviceID) || requested.count < 5 else { statuses[deviceID] = .failed("session_limit"); return }
        requested.insert(deviceID); tried[deviceID] = []
        if automatic { automaticTargets.insert(deviceID) } else { automaticTargets.remove(deviceID) }
        statuses[deviceID] = .discovering
        targetDeadlines[deviceID]?.cancel()
        targetDeadlines[deviceID] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            guard let self else { return }
            self.disconnect(deviceID: deviceID); self.statuses[deviceID] = .failed("nearby_timeout")
        }
        startDiscovery(); pump()
    }

    func showPairingChoices() {
        cancelOffer(); consentPresentation = .choosing; startDiscovery()
    }

    func beginConsentPairing(candidateID: UUID) {
        cancelOffer(); refreshDiscovery()
        guard discoverySuggestions.contains(where: { $0.id == candidateID }) else {
            consentPresentation = .failed("CONSENT_PHONE_UNAVAILABLE"); return
        }
        do {
            let key = try identity.privateKey()
            var created = try NearbyOfflineOffer(hostID: hostID(), identity: key.publicKey.x963Representation)
            var name = (Host.current().localizedName ?? "Mac").unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
            }.prefix(80).map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            while name.utf8.count > 240 { name.removeLast() }
            created.consentName = name.isEmpty ? "Mac" : name
            created.context = NearbyConsentProof.context(token: created.token, identity: created.identity, name: created.consentName!)
            offer = created; offerCandidateID = candidateID; consentPresentation = .requesting
            offerRetryBudget = NearbyPairingRetryBudget(); tried["offline"] = []
            let sessionID = created.sessionID
            offerExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.offer?.sessionID == sessionID else { return }
                self.cancelOffer(); self.consentPresentation = .failed("CONSENT_EXPIRED")
            }
            startDiscovery(); pump()
        } catch { consentPresentation = .failed("CONSENT_PHONE_UNAVAILABLE") }
    }

    func beginManualQRPairing() {
        consentPresentation = .manualQR
        beginOfflinePairing()
    }

    func beginOfflinePairing(candidateID: UUID? = nil) {
        let candidateID = candidateID ?? offerCandidateID
        cancelOffer()
        refreshDiscovery()
        if let candidateID, !discoverySuggestions.contains(where: { $0.id == candidateID }) { return }
        offerCandidateID = candidateID
        offerRetryBudget = NearbyPairingRetryBudget()
        tried["offline"] = []
        do {
            let key = try identity.privateKey()
            let created = try NearbyOfflineOffer(hostID: hostID(), identity: key.publicKey.x963Representation)
            offer = created; nearbyPairingURI = created.uri
            updateLocationPermissionHint()
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            offerExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                self?.cancelOffer()
            }
            startDiscovery(); pump()
        } catch { nearbyPairingURI = nil }
    }

    func endOfflinePairing() { cancelOffer(); tried.removeValue(forKey: "offline") }

    func disconnect(deviceID: String) {
        autoTickets.removeValue(forKey: deviceID)
        requested.remove(deviceID); tried.removeValue(forKey: deviceID)
        automaticTargets.remove(deviceID)
        targetDeadlines.removeValue(forKey: deviceID)?.cancel()
        for session in Array(sessions.values) where session.target == deviceID || session.deviceID == deviceID {
            if NearbyGroupOwnership.retainsAnchor(session.groupMember, disconnecting: deviceID, members: sessions.values.map(\.groupMember)) {
                // The other phone still leases this shared group. Keep its
                // owner BLE anchor until the final consumer disconnects.
                session.anchor = true; continue
            }
            retire(session, sendRelease: true)
        }
        statuses[deviceID] = .idle
    }

    /// Forgetting trust terminates ownership, unlike an ordinary disconnect
    /// which may retain a group owner for another trusted consumer.
    func revoke(deviceID: String) {
        let members = sessions.values.map(\.groupMember)
        let generations = NearbyGroupOwnership.revokedSessions(deviceID: deviceID, members: members)
        let selected = generations.compactMap { generation in sessions.values.first { $0.generation == generation } }
        var affected = Set(selected.compactMap { $0.deviceID ?? $0.target }); affected.insert(deviceID)
        for id in affected {
            requested.remove(id); automaticTargets.remove(id); autoTickets.removeValue(forKey: id)
            tried.removeValue(forKey: id); targetDeadlines.removeValue(forKey: id)?.cancel()
            statuses[id] = .idle
        }
        for session in selected {
            if session.deviceID == deviceID, selected.contains(where: { $0 !== session && $0.groupMember.ownerDeviceID == deviceID }) {
                // Preserve consumer-first retirement ordering, never the
                // ordinary disconnect behavior of keeping this owner alive.
                session.anchor = true
            }
            retire(session, sendRelease: true)
        }
        pump()
    }

    func retainsLease(deviceID: String) -> Bool {
        sessions.values.contains(where: { $0.deviceID == deviceID || $0.target == deviceID })
    }

    func waitForRetirement() async {
        while !retirements.isEmpty { for task in Array(retirements.values) { await task.value } }
    }

    func stop() {
        lifecycle = UUID(); autoTickets.removeAll()
        discoveryWanted = false; central?.stopScan()
        discoveryMaintenance?.cancel(); discoveryMaintenance = nil
        endDiscoveryProbe(metadata: nil)
        discoveryCatalog.removeAll(); discoverySuggestions = []
        requested.removeAll(); tried.removeAll(); candidates.removeAll(); cancelOffer()
        automaticTargets.removeAll()
        targetDeadlines.values.forEach { $0.cancel() }; targetDeadlines.removeAll()
        for session in sessions.values where session.descriptor?.ownerDeviceID == session.deviceID {
            if sessions.values.contains(where: { $0 !== session && ($0.joinOwnerDeviceID ?? $0.descriptor?.ownerDeviceID) == session.deviceID }) { session.anchor = true }
        }
        // Consumers retire before their group owner so the owner's STOP cannot
        // remove the Wi-Fi path needed for the consumer's final receipt.
        for session in Array(sessions.values).sorted(by: { !$0.anchor && $1.anchor }) { retire(session, sendRelease: true) }
        for id in statuses.keys { statuses[id] = .idle }
    }

    func stopAndWait() async {
        stop()
        while !retirements.isEmpty { for task in Array(retirements.values) { await task.value } }
        let deadline = ContinuousClock.now + .seconds(3)
        while !retiring.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func hostID() -> String {
        let key = "com.xopmc.GalaxyBridge.host-id"
        if let value = UserDefaults.standard.string(forKey: key), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString.lowercased(); UserDefaults.standard.set(value, forKey: key); return value
    }

    private func cancelOffer() {
        offerExpiry?.cancel(); offerExpiry = nil; offer = nil; nearbyPairingURI = nil; offerCandidateID = nil
        offerRetry?.cancel(); offerRetry = nil
        for session in Array(sessions.values) where session.offer != nil && session.peer == nil { retire(session, sendRelease: false) }
    }

    private var discoveryTime: TimeInterval {
        let elapsed = discoveryOrigin.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
    private func refreshDiscovery() {
        discoveryCatalog.expire(at: discoveryTime)
        candidates = candidates.filter { discoveryCatalog.identifiers.contains($0.key) || sessions[$0.key] != nil ||
            retiring[$0.key] != nil || discoveryProbe?.peripheral.identifier == $0.key }
        let suggestions = discoveryCatalog.suggestions
        if discoverySuggestions != suggestions { discoverySuggestions = suggestions }
    }
    /// Read one short public model string. Never sends bootstrap Hello or a
    /// network request, creates trust, or asks for Wi-Fi/location permission.
    private func pumpDiscoveryProbe() {
        guard discoveryWanted, central?.state == .poweredOn, discoveryProbe == nil, offer == nil,
              requested.allSatisfy({ statuses[$0] == .connected }),
              sessions.values.allSatisfy({ $0.lifetime.verified }), retiring.isEmpty,
              let id = discoveryCatalog.nextProbe(at: discoveryTime) else { return }
        guard let peripheral = candidates[id], sessions[id] == nil, peripheral.state == .disconnected else {
            discoveryCatalog.finishProbe(id, metadata: nil); return
        }
        let probe = DiscoveryProbe(peripheral)
        discoveryProbe = probe; peripheral.delegate = self
        probe.deadline = Task { [weak self, weak probe] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, let probe, self.discoveryProbe === probe else { return }
            self.endDiscoveryProbe(metadata: nil)
        }
        central?.connect(peripheral)
    }
    private func endDiscoveryProbe(metadata: Data?) {
        guard let probe = discoveryProbe, !probe.closing else { return }
        probe.closing = true; probe.deadline?.cancel()
        let fingerprint = metadata.flatMap { NearbyDiscoveryMetadata.parse($0)?.pairedHostFingerprint } != nil
            ? try? identity.existingFingerprint() : nil
        discoveryCatalog.finishProbe(probe.peripheral.identifier, metadata: metadata, localHostFingerprint: fingerprint)
        refreshDiscovery()
        // Retain the probe until CoreBluetooth confirms closure, so a late
        // disconnect cannot be mistaken for a new authenticated session.
        central?.cancelPeripheralConnection(probe.peripheral)
    }
    private func settleDiscoveryProbe(_ peripheral: CBPeripheral) -> Bool {
        guard let probe = discoveryProbe, probe.peripheral.identifier == peripheral.identifier else { return false }
        probe.deadline?.cancel(); discoveryCatalog.finishProbe(peripheral.identifier, metadata: nil)
        discoveryProbe = nil; refreshDiscovery(); pump()
        return true
    }

    private func pump() {
        guard discoveryWanted, central?.state == .poweredOn, retirements.isEmpty else { return }
        if discoveryProbe != nil {
            if offer != nil || requested.contains(where: { statuses[$0] != .connected }) { endDiscoveryProbe(metadata: nil) }
            return
        }
        while sessions.count + retiring.count < 5 {
            let target = requested.sorted().first { id in !sessions.values.contains(where: { $0.target == id || $0.deviceID == id }) &&
                candidates.keys.contains(where: { !(tried[id] ?? []).contains($0) && sessions[$0] == nil }) }
            let offline = target == nil && offer?.valid() == true && !sessions.values.contains(where: { $0.offer != nil })
            guard target != nil || offline else { pumpDiscoveryProbe(); return }
            let key = target ?? "offline"
            guard let peripheral = candidates.values.first(where: { sessions[$0.identifier] == nil && retiring[$0.identifier] == nil && !(tried[key] ?? []).contains($0.identifier) &&
                (!offline || offerCandidateID == nil || offerCandidateID == $0.identifier) }) else { return }
            if offline {
                guard offerRetryBudget.permit(at: discoveryTime), let sessionID = offer?.sessionID else { return }
                offerRetry?.cancel()
                offerRetry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.offer?.sessionID == sessionID, self.offer?.valid() == true else { return }
                    guard self.offer?.consentName == nil else { return }
                    self.tried["offline"] = []; self.pump()
                }
            }
            guard (tried[key]?.count ?? 0) < 32 else {
                if let target { disconnect(deviceID: target); statuses[target] = .failed("probe_limit") } else { cancelOffer() }
                return
            }
            tried[key, default: []].insert(peripheral.identifier)
            do {
                let signingKey = try identity.privateKey(), offer = offline ? self.offer : nil
                let context = offer?.context ?? Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
                let agreement = NearbyBootstrapAgreement(role: .initiator, deviceID: hostID(), context: context,
                    identity: signingKey.publicKey.x963Representation, sign: { try signingKey.signature(for: $0).derRepresentation })
                let session = Session(peripheral: peripheral, target: target, agreement: agreement, hello: try agreement.hello(),
                    sessionID: offer?.sessionID ?? UUID().uuidString.lowercased(), offer: offer)
                session.automatic = target.map { automaticTargets.contains($0) } ?? false
                sessions[peripheral.identifier] = session; peripheral.delegate = self
                if let target { statuses[target] = .connecting }
                session.deadline = Task { [weak self, weak session] in
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    guard let self, let session, self.current(session) else { return }
                    self.fail(session, code: "nearby_timeout")
                }
                central?.connect(peripheral)
            } catch { if let target { statuses[target] = .failed("identity_unavailable"); requested.remove(target) } else { cancelOffer() }; return }
        }
    }

    private func current(_ session: Session) -> Bool { sessions[session.peripheral.identifier] === session }
    private func admitsTrustedSession(_ session: Session) -> Bool {
        guard current(session), let peer = session.peer else { return false }
        let trusted = peers().first { $0.deviceID == peer.deviceID }
        guard NearbyGroupOwnership.trusted(identity: peer.identityPublicKey, pin: peer.tlsCertificateSHA256,
            currentIdentity: trusted?.identityPublicKey, currentPin: trusted?.tlsCertificateSHA256) else {
            revoke(deviceID: peer.deviceID); return false
        }
        return true
    }
    private func update(_ session: Session, _ status: NearbyConnectionStatus) {
        if let id = session.deviceID ?? session.target { statuses[id] = status }
    }
    private func fail(_ session: Session, code: String) {
        guard current(session) else { return }
        if session.descriptor != nil, let deviceID = session.deviceID {
            requested.remove(deviceID); tried.removeValue(forKey: deviceID)
            targetDeadlines.removeValue(forKey: deviceID)?.cancel()
        }
        let isConsent = session.offer?.consentName != nil && session.peer == nil
        update(session, .failed(code)); retire(session, sendRelease: true)
        if isConsent { cancelOffer(); consentPresentation = .failed(code.hasPrefix("CONSENT_") ? code : "CONSENT_PHONE_UNAVAILABLE") }
        pump()
    }

    private func retire(_ session: Session, sendRelease: Bool) {
        guard current(session) else { return }
        groupAdmission.retiring(session.generation)
        groupCleanup[session.generation] = NearbyGroupRetirementState(wifiSettled: false,
            remoteSafeAfter: sendRelease ? NearbyRemoteLeaseDeadline.retiring(at: .now, previous: session.remoteLeaseExpiresAt) : .now)
        groupCleanupDeviceIDs[session.generation] = session.deviceID ?? session.target
        session.lifetime.retire()
        sessions.removeValue(forKey: session.peripheral.identifier)
        retiring[session.peripheral.identifier] = session
        session.deadline?.cancel(); session.polling?.cancel(); session.work?.cancel()
        session.renewal?.cancel()
        if let confirmation = session.confirmation {
            session.confirmation = nil; confirmation.timeout.cancel()
            confirmation.continuation.resume(throwing: CancellationError())
        }
        wifi.cancel(owner: session.generation)
        // Queue the exact lease release before disconnect; never target another
        // peer/group. A lost BLE link may make release unavailable to the phone.
        if sendRelease, !session.anchor, !session.leaseID.isEmpty, session.crypto != nil, session.peripheral.state == .connected {
            var request = GBDirectLinkRequest(); request.requestID = UUID().uuidString.lowercased()
            request.enabled = false; request.groupLeaseID = session.leaseID
            var envelope = baseEnvelope(session); envelope.directLinkRequest = request
            try? send(envelope, session)
        }
        session.closeDeadline = Task { [weak self, weak session] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, let session, self.retiring[session.peripheral.identifier] === session else { return }
            self.central?.cancelPeripheralConnection(session.peripheral)
        }
        if session.peripheral.state == .disconnected {
            retiring.removeValue(forKey: session.peripheral.identifier); session.closeDeadline?.cancel()
        } else if session.writes.isEmpty && !session.writePending { central?.cancelPeripheralConnection(session.peripheral) }
        let earlierRetirements = Array(retirements.values)
        retirements[session.generation] = Task { [weak self, wifi, onReleaseLease] in
            if session.anchor { for task in earlierRetirements { await task.value } }
            var remoteSettled = !sendRelease || session.remoteLeaseExpiresAt == nil
            if sendRelease, let deviceID = session.deviceID, !session.leaseID.isEmpty {
                let released = await onReleaseLease(deviceID, session.leaseID)
                remoteSettled = released
                if !released, session.peripheral.state == .disconnected,
                   let self, !self.sessions.values.contains(where: { $0.deviceID == deviceID }) {
                    self.statuses[deviceID] = .failed("nearby_cleanup_unconfirmed")
                }
            }
            var wifiSettled = false
            do { try await wifi.release(owner: session.generation); wifiSettled = true }
            catch {
                if let self, let id = session.deviceID ?? session.target,
                   !self.sessions.values.contains(where: { $0.deviceID == id || $0.target == id }) {
                    self.statuses[id] = .failed("wifi_restore_failed")
                }
            }
            self?.retirements.removeValue(forKey: session.generation)
            guard let self else { return }
            if var cleanup = self.groupCleanup[session.generation] {
                cleanup.wifiSettled = wifiSettled
                cleanup.remoteAcknowledged = remoteSettled
                if remoteSettled { cleanup.remoteSafeAfter = .now }
                self.groupCleanup[session.generation] = cleanup
            }
            if !wifiSettled { self.reportGroupCleanupFailure() }
            for anchor in Array(self.sessions.values) where anchor.anchor {
                if !self.sessions.values.contains(where: { !$0.anchor && ($0.joinOwnerDeviceID ?? $0.descriptor?.ownerDeviceID) == anchor.deviceID }) {
                    self.retire(anchor, sendRelease: true)
                }
            }
            self.scheduleGroupCleanup(session.generation)
            self.pump()
        }
        if sharedDescriptor?.deviceID == session.deviceID {
            sharedDescriptor = sessions.values.filter { $0.lifetime.verified }.compactMap(\.descriptor).first
        }
    }

    private func baseEnvelope(_ session: Session) -> GBEnvelope {
        var envelope = GBEnvelope(); envelope.protocolMajor = 1; envelope.deviceID = hostID(); envelope.sessionID = session.sessionID
        return envelope
    }
    private func drainGroupRequests() {
        guard discoveryWanted, groupCleanup.isEmpty, retirements.isEmpty, retiring.isEmpty else { return }
        for generation in groupAdmission.queued {
            if let session = sessions.values.first(where: { $0.generation == generation }) { requestLink(session) }
            else { groupAdmission.retiring(generation) }
        }
    }

    private func finishGroupCleanup(_ generation: UUID) {
        guard let cleanup = groupCleanup[generation], cleanup.settled(at: .now,
            taskRunning: retirements[generation] != nil,
            bluetoothRetiring: retiring.values.contains(where: { $0.generation == generation })) else { return }
        groupCleanup.removeValue(forKey: generation); groupCleanupDeviceIDs.removeValue(forKey: generation)
        groupCleanupTimers.removeValue(forKey: generation)?.cancel()
        groupAdmission.settled(generation)
        drainGroupRequests(); pump()
    }

    private func recordRemoteLeaseDelivery(_ session: Session) {
        let deadline = NearbyRemoteLeaseDeadline.delivered(at: .now, previous: session.remoteLeaseExpiresAt)
        session.remoteLeaseExpiresAt = deadline
        // An awaited TLS renewal may finish after retirement started. Extend
        // only its retained, exact generation; never recreate an old fence or
        // override the Android exact-lease STOP acknowledgement.
        if var cleanup = groupCleanup[session.generation], !cleanup.remoteAcknowledged, deadline > cleanup.remoteSafeAfter {
            cleanup.remoteSafeAfter = deadline; groupCleanup[session.generation] = cleanup
            groupCleanupTimers.removeValue(forKey: session.generation)?.cancel()
            scheduleGroupCleanup(session.generation)
        }
    }

    private func scheduleGroupCleanup(_ generation: UUID) {
        finishGroupCleanup(generation)
        guard let cleanup = groupCleanup[generation], cleanup.remoteSafeAfter > .now,
              groupCleanupTimers[generation] == nil else { return }
        let deadline = cleanup.remoteSafeAfter
        // A lost STOP receipt is not success. Keep only generation/deadline
        // metadata until the silence TTL (plus transport margin) proves expiry.
        // This timer is outside bounded stopAndWait's physical cleanup tasks.
        groupCleanupTimers[generation] = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self else { return }
            self.groupCleanupTimers.removeValue(forKey: generation)
            self.finishGroupCleanup(generation)
        }
    }

    private func reportGroupCleanupFailure() {
        for generation in groupAdmission.queued {
            if let session = sessions.values.first(where: { $0.generation == generation }) { update(session, .failed("wifi_restore_failed")) }
        }
    }

    private func retryGroupCleanup() {
        // Explicit Connect is also the safe retry for retained local cleanup;
        // it cannot admit a new group while this original ownership is dirty.
        for (id, session) in Array(retiring) where session.peripheral.state == .disconnected {
            retiring.removeValue(forKey: id); session.closeDeadline?.cancel(); finishGroupCleanup(session.generation)
        }
        for (generation, cleanup) in groupCleanup where !cleanup.wifiSettled && retirements[generation] == nil && groupCleanupRetries[generation] == nil {
            groupCleanupRetries[generation] = Task { [weak self, wifi] in
                do {
                    try await wifi.release(owner: generation)
                    guard let self else { return }
                    self.groupCleanup[generation]?.wifiSettled = true
                } catch {
                    if let self, self.discoveryWanted {
                        if let id = self.groupCleanupDeviceIDs[generation] { self.statuses[id] = .failed("wifi_restore_failed") }
                        self.reportGroupCleanupFailure()
                    }
                }
                guard let self else { return }
                self.groupCleanupRetries.removeValue(forKey: generation)
                self.scheduleGroupCleanup(generation)
            }
        }
    }
    private func enqueue(_ bytes: Data, _ session: Session) throws {
        let framed = try NearbyTransportDecoder.encode(bytes)
        guard session.writes.reduce(0, { $0 + $1.count }) + framed.count <= 131_080 else { throw NearbyTransportFailure.frame }
        session.writes.append(framed); flush(session)
    }
    private func flush(_ session: Session) {
        guard !session.writePending, !session.writes.isEmpty, let rx = session.rx else { return }
        let count = min(session.peripheral.maximumWriteValueLength(for: .withResponse), session.writes[0].count)
        guard count > 0 else { bootstrapLost(session, code: "gatt_write_unavailable"); return }
        let chunk = session.writes[0].prefix(count)
        session.writes[0].removeFirst(count)
        if session.writes[0].isEmpty { session.writes.removeFirst() }
        session.writePending = true
        session.peripheral.writeValue(Data(chunk), for: rx, type: .withResponse)
    }
    private func send(_ envelope: GBEnvelope, _ session: Session) throws {
        guard var crypto = session.crypto else { throw NearbyTransportFailure.authentication }
        let encrypted = try crypto.seal(envelope.serializedData()); session.crypto = crypto
        try enqueue(encrypted, session)
    }

    private func receive(_ frame: Data, _ session: Session) throws {
        if session.crypto == nil {
            let hello = try NearbyBootstrapHello(wire: frame)
            session.remoteHello = hello
            if let target = session.target {
                guard let peer = peers().first(where: { $0.deviceID == target }), hello.deviceID == peer.deviceID else { throw NearbyTransportFailure.authentication }
                session.crypto = try session.agreement.complete(remote: hello, expectedIdentity: peer.identityPublicKey)
                session.peer = peer; session.deviceID = peer.deviceID
                discoveryCatalog.markTrusted(session.peripheral.identifier); refreshDiscovery()
                requestLink(session)
            } else {
                guard let offer = session.offer, offer.valid(), self.offer?.sessionID == offer.sessionID,
                      !peers().contains(where: { $0.deviceID == hello.deviceID && $0.identityPublicKey != hello.identity }) else { throw NearbyTransportFailure.authentication }
                session.crypto = try session.agreement.complete(remote: hello, expectedIdentity: hello.identity, pairingToken: offer.consentName == nil ? offer.token : nil)
                session.deviceID = hello.deviceID
                if let name = offer.consentName {
                    var request = GBPairingRequest(); request.oneTimeToken = offer.token
                    request.identityPublicKey = offer.identity; request.clientNonce = session.hello.nonce
                    request.displayName = name
                    request.transcriptSignature = try identity.sign(nonce: PairingTranscript.makeRequest(
                        token: offer.token, clientNonce: session.hello.nonce, macPublicKey: offer.identity, displayName: Data(name.utf8)))
                    var envelope = baseEnvelope(session); envelope.pairingRequest = request
                    session.consentRequest = envelope
                    consentPresentation = .comparing(NearbyConsentProof.comparison(session.hello.transcript, hello.transcript, offer.token))
                    try send(envelope, session)
                }
            }
            return
        }
        guard var crypto = session.crypto else { throw NearbyTransportFailure.authentication }
        let envelope = try GBEnvelope(serializedBytes: crypto.open(frame)); session.crypto = crypto
        guard envelope.protocolMajor == 1, envelope.sessionID == session.sessionID, envelope.deviceID == session.deviceID else { throw NearbyTransportFailure.authentication }
        if let offer = session.offer, session.peer == nil {
            try receivePairing(envelope, session, offer); return
        }
        guard admitsTrustedSession(session) else { throw NearbyTransportFailure.authentication }
        switch envelope.payload {
        case let .directLinkStatus(status):
            switch NearbyDirectStatusReceipt.classify(requestID: status.requestID,
                expectedRequestID: session.confirmation?.requestID ?? session.requestID,
                state: status.state, errorCode: status.errorCode) {
            case .ignore: return
            case let .failure(code):
                // This is an authenticated rejection by the requested phone,
                // not an unrelated BLE candidate worth probing again.
                if let id = session.deviceID {
                    requested.remove(id); tried.removeValue(forKey: id)
                    targetDeadlines.removeValue(forKey: id)?.cancel()
                }
                // retire() remains the sole owner of any confirmation waiter.
                fail(session, code: code)
                return
            case .process: break
            }
            if let confirmation = session.confirmation {
                guard status.requestID == confirmation.requestID else { return }
                session.confirmation = nil; confirmation.timeout.cancel()
                let wasVerified = session.lifetime.verified
                guard status.groupLeaseID == session.leaseID, status.state == "established", status.errorCode.isEmpty,
                      let descriptor = session.descriptor, session.lifetime.markVerified() else {
                    confirmation.continuation.resume(throwing: NearbyTransportFailure.descriptor); return
                }
                recordRemoteLeaseDelivery(session)
                // Complete the ownership transition in the ACK callback. A
                // Bluetooth disconnect queued immediately after the ACK must
                // already see the established Wi-Fi lifetime.
                sharedDescriptor = sharedDescriptor ?? descriptor
                session.renewalState = NearbyLeaseRenewalState(confirmedAt: .now)
                session.deadline?.cancel(); targetDeadlines.removeValue(forKey: descriptor.deviceID)?.cancel()
                if !wasVerified {
                    groupAdmission.verified(session.generation)
                    update(session, .connected); onDescriptor(descriptor); startRenewing(session)
                    drainGroupRequests()
                }
                confirmation.continuation.resume()
                return
            }
            guard !session.requestID.isEmpty, status.requestID == session.requestID, !status.groupLeaseID.isEmpty,
                  session.leaseID.isEmpty || session.leaseID == status.groupLeaseID,
                  status.errorCode.isEmpty, status.state == "pending" else { throw NearbyTransportFailure.descriptor }
            session.leaseID = status.groupLeaseID
            recordRemoteLeaseDelivery(session)
            session.polling?.cancel()
            session.polling = Task { [weak self, weak session] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let session, self.current(session) else { return }
                self.requestLink(session)
            }
        case let .directLinkDescriptor(descriptor): try receivedDescriptor(descriptor, session)
        default: throw NearbyTransportFailure.frame
        }
    }

    private func requestLink(_ session: Session) {
        guard admitsTrustedSession(session) else { return }
        update(session, .creatingLink)
        if session.leaseID.isEmpty {
            let decision = groupAdmission.request(session.generation, sharedGroup: sharedDescriptor != nil,
                cleanupPending: !groupCleanup.isEmpty || !retirements.isEmpty || !retiring.isEmpty)
            guard decision != .wait else {
                if groupCleanup.contains(where: { !$0.value.wifiSettled && retirements[$0.key] == nil }) { update(session, .failed("wifi_restore_failed")) }
                return
            }
            if decision == .join { session.joinOwnerDeviceID = sharedDescriptor?.ownerDeviceID }
            // Record a possible delivery; receipts advance this clock and
            // retirement separately covers outstanding request/close bounds.
            // An empty-lease create with a lost first response must also fence
            // a successor; lack of a lease ID is not proof no group was made.
            recordRemoteLeaseDelivery(session)
        }
        var request = GBDirectLinkRequest(); request.requestID = UUID().uuidString.lowercased(); request.enabled = true
        request.groupLeaseID = session.leaseID; session.requestID = request.requestID
        if session.leaseID.isEmpty, let sharedDescriptor { request.join = sharedDescriptor }
        var envelope = baseEnvelope(session); envelope.directLinkRequest = request
        do { try send(envelope, session) } catch { fail(session, code: "gatt_send_failed") }
    }

    private func confirmLink(_ session: Session) async throws {
        guard admitsTrustedSession(session), session.peripheral.state == .connected, session.crypto != nil,
              session.confirmation == nil, session.descriptor != nil else { throw NearbyTransportFailure.unavailable }
        let requestID = UUID().uuidString.lowercased()
        recordRemoteLeaseDelivery(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeout = Task { [weak self, weak session] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self, let session, self.current(session), let pending = session.confirmation,
                      pending.requestID == requestID else { return }
                session.confirmation = nil; pending.continuation.resume(throwing: NearbyTransportFailure.timeout)
            }
            session.confirmation = (requestID, continuation, timeout)
            var request = GBDirectLinkRequest(); request.requestID = requestID; request.enabled = true
            request.confirmed = true; request.groupLeaseID = session.leaseID
            var envelope = baseEnvelope(session); envelope.directLinkRequest = request
            do { try send(envelope, session) }
            catch {
                session.confirmation = nil; timeout.cancel(); continuation.resume(throwing: error)
            }
        }
    }

    private func startRenewing(_ session: Session) {
        session.renewal?.cancel()
        session.renewal = Task { [weak self, weak session] in
            while true {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, let session, self.current(session), !Task.isCancelled,
                      let deviceID = session.deviceID, let state = session.renewalState else { return }
                guard self.admitsTrustedSession(session) else { return }
                guard !state.expired(at: .now) else { self.fail(session, code: "nearby_lease_expired"); return }
                var renewed = false
                if session.peripheral.state == .connected, session.crypto != nil {
                    do { try await self.confirmLink(session); renewed = true } catch {}
                }
                guard self.current(session), !Task.isCancelled else { return }
                guard self.admitsTrustedSession(session) else { return }
                if !renewed {
                    self.recordRemoteLeaseDelivery(session)
                    renewed = await self.onRenewLease(deviceID, session.leaseID)
                    // A missing/timed-out receipt does not prove non-delivery.
                    self.recordRemoteLeaseDelivery(session)
                }
                guard self.current(session), !Task.isCancelled else { return }
                guard self.admitsTrustedSession(session) else { return }
                if renewed { session.renewalState?.confirmed(at: .now) }
                else if session.renewalState?.expired(at: .now) == true {
                    self.fail(session, code: "nearby_lease_expired"); return
                }
            }
        }
    }

    private func receivePairing(_ envelope: GBEnvelope, _ session: Session, _ offer: NearbyOfflineOffer) throws {
        guard offer.valid(), self.offer?.sessionID == offer.sessionID else { throw NearbyTransportFailure.invalidOffer }
        if case let .pairingResponse(response)? = envelope.payload {
            if offer.consentName != nil && !response.accepted {
                if response.rejectionReason == "consent_pending" {
                    session.polling?.cancel()
                    session.polling = Task { [weak self, weak session] in
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        guard let self, let session, self.current(session), let request = session.consentRequest,
                              self.offer?.sessionID == offer.sessionID, session.commitTranscript == nil else { return }
                        do { try self.send(request, session) } catch { self.fail(session,code: "CONSENT_PHONE_UNAVAILABLE") }
                    }
                } else {
                    let key: String = switch response.rejectionReason {
                    case "consent_declined": "CONSENT_DECLINED"
                    case "consent_busy": "CONSENT_BUSY"
                    case "consent_open_helper": "CONSENT_OPEN_HELPER"
                    case "consent_expired": "CONSENT_EXPIRED"
                    default: "CONSENT_PHONE_UNAVAILABLE"
                    }
                    fail(session,code:key)
                }
                return
            }
            session.polling?.cancel(); session.polling = nil
            guard response.accepted, response.deviceID == session.deviceID, response.identityPublicKey.count == 65,
                  response.identityPublicKey == session.remoteHello?.identity,
                  response.tlsCertificateSha256.count == 32, response.serverNonce == session.remoteHello?.nonce else { throw NearbyTransportFailure.authentication }
            let transcript = PairingTranscript.make(token: offer.token, clientNonce: session.hello.nonce, serverNonce: response.serverNonce,
                macPublicKey: offer.identity, androidPublicKey: response.identityPublicKey)
            guard try PairingTranscript.verify(signatureDER: response.transcriptSignature, transcript: transcript, publicKeyX963: response.identityPublicKey) else { throw NearbyTransportFailure.authentication }
            let peer = PairedPeer(deviceID: response.deviceID, displayName: response.displayName, identityPublicKey: response.identityPublicKey,
                tlsCertificateSHA256: response.tlsCertificateSha256, pairedAt: Date())
            let commitTranscript = PairingTranscript.makeCommit(token: offer.token, clientNonce: session.hello.nonce,
                serverNonce: response.serverNonce, macPublicKey: offer.identity, androidPublicKey: peer.identityPublicKey,
                hostID: offer.hostID, deviceID: peer.deviceID, sessionID: offer.sessionID)
            let signature = try identity.sign(nonce: commitTranscript)
            try peerStore.stage(StagedPairingTrust(peer: peer, hostID: offer.hostID, sessionID: offer.sessionID,
                commitTranscript: commitTranscript, commitSignature: signature, expiresAt: offer.expiresAt))
            session.commitTranscript = commitTranscript; session.commitSignature = signature
            var commit = GBPairingCommit(); commit.hostID = offer.hostID; commit.deviceID = peer.deviceID
            commit.sessionID = offer.sessionID; commit.transcriptSignature = signature
            var message = baseEnvelope(session); message.pairingCommit = commit
            try send(message, session)
        } else if case let .pairingCommitAck(ack)? = envelope.payload {
            guard ack.committed, ack.hostID == offer.hostID, ack.deviceID == session.deviceID, ack.sessionID == offer.sessionID,
                  let transcript = session.commitTranscript, let signature = session.commitSignature,
                  let staged = try peerStore.staged(deviceID: ack.deviceID, sessionID: offer.sessionID),
                  try PairingTranscript.verify(signatureDER: ack.transcriptSignature,
                    transcript: PairingTranscript.makeCommitAcknowledgement(commitTranscript: transcript, commitSignature: signature),
                    publicKeyX963: staged.peer.identityPublicKey) else { throw NearbyTransportFailure.authentication }
            let promotedPeer = try peerStore.promote(deviceID: ack.deviceID, sessionID: offer.sessionID)
            session.peer = promotedPeer
            discoveryCatalog.markTrusted(session.peripheral.identifier); refreshDiscovery()
            CompanionLifecycleEvents.pairingStored(promotedPeer)
            self.offer = nil; nearbyPairingURI = nil; offerExpiry?.cancel(); offerExpiry = nil
            offerRetry?.cancel(); offerRetry = nil; offerCandidateID = nil
            onPairingCommitted(); update(session, .idle)
            retire(session, sendRelease: false)
            // The app may now resolve an existing route or request a safe
            // automatic connection using this cryptographically verified ID.
            onVerifiedPairing(promotedPeer.deviceID); pump()
        } else { throw NearbyTransportFailure.frame }
    }

    private func receivedDescriptor(_ descriptor: GBDirectLinkDescriptor, _ session: Session) throws {
        guard !session.requestID.isEmpty, let peer = session.peer, peers().contains(where: { $0.deviceID == peer.deviceID && $0.identityPublicKey == peer.identityPublicKey && $0.tlsCertificateSHA256 == peer.tlsCertificateSHA256 }),
              descriptor.deviceID == peer.deviceID,
              descriptor.identityPublicKey == peer.identityPublicKey, descriptor.tlsCertificateSha256 == peer.tlsCertificateSHA256,
              descriptor.groupLeaseID == session.leaseID || session.leaseID.isEmpty,
              !descriptor.groupLeaseID.isEmpty, descriptor.generation > 0,
              descriptor.ownerDeviceID == peer.deviceID || peers().contains(where: { $0.deviceID == descriptor.ownerDeviceID }),
              descriptor.companionPort > 0, descriptor.companionPort <= UInt16.max,
              ["p2p", "local_only_hotspot"].contains(descriptor.mode), session.work == nil else { throw NearbyTransportFailure.descriptor }
        session.leaseID = descriptor.groupLeaseID; session.polling?.cancel()
        recordRemoteLeaseDelivery(session)
        update(session, .joiningNetwork)
        session.work = Task { [weak self, weak session, wifi] in
            guard let self, let session, self.current(session), !Task.isCancelled else { return }
            do {
                if !session.automatic, self.location.authorizationStatus == .notDetermined {
                    self.location.requestWhenInUseAuthorization()
                    let deadline = ContinuousClock.now + .seconds(20)
                    while self.location.authorizationStatus == .notDetermined && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                guard self.location.authorizationStatus == .authorizedAlways else { throw NearbyTransportFailure.unavailable }
                try Task.checkCancellation()
                guard self.current(session) else { throw CancellationError() }
                // A queued automatic request may now share our verified owner
                // association. That adds a lease; it does not select a different
                // healthy network. Keep its owner anchor alive until retirement.
                if let owner = session.joinOwnerDeviceID {
                    guard self.sessions.values.contains(where: { $0.deviceID == owner && $0.lifetime.verified }) else { throw NearbyTransportFailure.ownership }
                }
                try await wifi.join(name: descriptor.networkName, password: descriptor.passphrase, owner: session.generation,
                    automatic: session.automatic, sharingOwnedAssociation: session.joinOwnerDeviceID != nil)
                guard self.current(session), !Task.isCancelled else { throw CancellationError() }
                guard self.peers().contains(where: { $0.deviceID == peer.deviceID && $0.identityPublicKey == peer.identityPublicKey && $0.tlsCertificateSHA256 == peer.tlsCertificateSHA256 }) else { throw NearbyTransportFailure.authentication }
                self.update(session, .verifying)
                try await NearbyTLSProbe.verify(address: descriptor.deviceAddress, port: UInt16(descriptor.companionPort), pin: peer.tlsCertificateSHA256)
                guard self.current(session), !Task.isCancelled else { throw CancellationError() }
                guard self.peers().contains(where: { $0.deviceID == peer.deviceID && $0.identityPublicKey == peer.identityPublicKey && $0.tlsCertificateSHA256 == peer.tlsCertificateSHA256 }) else { throw NearbyTransportFailure.authentication }
                session.descriptor = descriptor
                try await self.confirmLink(session)
            } catch {
                self.fail(session, code: "nearby_join_or_verification_failed")
                // retire() owns the single STOP/association cleanup sequence;
                // a second release here could remove its TLS route too early.
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, discoveryWanted { startDiscovery(); pump() }
        else if central.state != .poweredOn {
            discoveryProbe?.deadline?.cancel(); discoveryProbe = nil
            discoveryCatalog.removeAll(); discoverySuggestions = []
            for session in Array(sessions.values) { bootstrapLost(session, code: "bluetooth_unavailable") }
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard discoveryWanted else { return }
        discoveryCatalog.observe(peripheral.identifier, at: discoveryTime)
        candidates[peripheral.identifier] = peripheral
        refreshDiscovery(); pump()
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let probe = discoveryProbe, probe.peripheral.identifier == peripheral.identifier {
            if probe.closing { central.cancelPeripheralConnection(peripheral) }
            else { peripheral.discoverServices([Self.service]) }
            return
        }
        guard let session = sessions[peripheral.identifier] else { central.cancelPeripheralConnection(peripheral); return }
        update(session, .authenticating); peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if settleDiscoveryProbe(peripheral) { return }
        if let retired = retiring.removeValue(forKey: peripheral.identifier) { retired.closeDeadline?.cancel(); finishGroupCleanup(retired.generation); drainGroupRequests(); pump(); return }
        if let session = sessions[peripheral.identifier] { bootstrapLost(session, code: "ble_connection_failed") }
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if settleDiscoveryProbe(peripheral) { return }
        if let retired = retiring.removeValue(forKey: peripheral.identifier) { retired.closeDeadline?.cancel(); finishGroupCleanup(retired.generation); drainGroupRequests(); pump(); return }
        if let session = sessions[peripheral.identifier] { bootstrapLost(session, code: "ble_disconnected") }
    }
    private func bootstrapLost(_ session: Session, code: String) {
        guard current(session) else { return }
        guard !session.lifetime.retiresOnBootstrapLoss else { fail(session, code: code); return }
        // The pin-verified Wi-Fi lease has its own lifetime. Do not restore the
        // Mac's association merely because this discovery/control radio drops.
        session.lifetime.detachBootstrap()
        if let pending = session.confirmation {
            session.confirmation = nil; pending.timeout.cancel()
            pending.continuation.resume(throwing: NearbyTransportFailure.unavailable)
        }
        session.polling?.cancel(); session.writes.removeAll(); session.writePending = false
        session.rx = nil; session.tx = nil; session.crypto = nil
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let probe = discoveryProbe, probe.peripheral.identifier == peripheral.identifier {
            guard !probe.closing, error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { endDiscoveryProbe(metadata: nil); return }
            peripheral.discoverCharacteristics([Self.metadata], for: service); return
        }
        guard let session = sessions[peripheral.identifier], !session.lifetime.bootstrapDetached else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { fail(session, code: "ble_service_missing"); return }
        peripheral.discoverCharacteristics([Self.rx, Self.tx], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let probe = discoveryProbe, probe.peripheral.identifier == peripheral.identifier {
            guard !probe.closing, error == nil, let metadata = service.characteristics?.first(where: { $0.uuid == Self.metadata && $0.properties.contains(.read) }) else { endDiscoveryProbe(metadata: nil); return }
            peripheral.readValue(for: metadata); return
        }
        guard let session = sessions[peripheral.identifier], !session.lifetime.bootstrapDetached else { return }
        session.rx = service.characteristics?.first(where: { $0.uuid == Self.rx && $0.properties.contains(.write) })
        session.tx = service.characteristics?.first(where: { $0.uuid == Self.tx && $0.properties.contains(.indicate) })
        guard error == nil, session.rx != nil, let tx = session.tx else { fail(session, code: "ble_characteristics_missing"); return }
        peripheral.setNotifyValue(true, for: tx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let session = sessions[peripheral.identifier], !session.lifetime.bootstrapDetached, characteristic.uuid == Self.tx else { return }
        guard error == nil, characteristic.isNotifying else { bootstrapLost(session, code: "ble_subscription_failed"); return }
        do { try enqueue(session.hello.wireEncoded(), session) } catch { fail(session, code: "ble_frame_failed") }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let session = sessions[peripheral.identifier] ?? retiring[peripheral.identifier], characteristic.uuid == Self.rx else { return }
        if retiring[peripheral.identifier] === session {
            session.writePending = false
            if error != nil || session.writes.isEmpty { central?.cancelPeripheralConnection(peripheral) }
            else { flush(session) }
            return
        }
        guard !session.lifetime.bootstrapDetached else { return }
        guard error == nil else { bootstrapLost(session, code: "ble_write_failed"); return }
        session.writePending = false; flush(session)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let probe = discoveryProbe, probe.peripheral.identifier == peripheral.identifier {
            guard !probe.closing, characteristic.uuid == Self.metadata else { return }
            endDiscoveryProbe(metadata: error == nil ? characteristic.value : nil); return
        }
        guard let session = sessions[peripheral.identifier], !session.lifetime.bootstrapDetached, characteristic.uuid == Self.tx else { return }
        guard error == nil, let bytes = characteristic.value else { bootstrapLost(session, code: "ble_read_failed"); return }
        do { for frame in try session.decoder.append(bytes) { try receive(frame, session) } }
        catch { fail(session, code: "nearby_authentication_or_frame_failed") }
    }
}
