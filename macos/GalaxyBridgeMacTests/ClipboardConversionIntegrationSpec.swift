import Foundation
import Combine
import CryptoKit

// ACTUAL_PEER_FINGERPRINT

struct TestPasteboardType {
    let rawValue: String
    static let string = Self(rawValue: "public.utf8-plain-text")
    static let png = Self(rawValue: "public.png")
}
@MainActor final class TestPasteboard {
    var changeCount = 1
    var types: [TestPasteboardType]? = [.string]
    var text: String? = "fixture"
    var image: MacClipboardImageSource? = .encoded(Data([1]))
    var snapshotReads = 0
    func string(forType type: TestPasteboardType) -> String? { text }
    func data(forType type: TestPasteboardType) -> Data? { nil }
    func clearContents() { changeCount += 1; text = nil; image = nil }
    func setString(_ value: String, forType type: TestPasteboardType) -> Bool { changeCount += 1; text = value; return true }
}
struct TestDevice { var id = "phone"; var isReady = true }
struct TestTerminationAdmission { var admitsWork = true }
enum GBClipboardKind { case text, url, png, unknown }
@MainActor enum MacClipboardImageWriter {
    static func write(_ data: Data, to pasteboard: TestPasteboard) -> Bool { preconditionFailure("This fixture exercises remote text only") }
}
@MainActor final class ClipboardCacheAdmissionProbe {
    typealias Owner = ContentCacheMaintenanceCoordinator
    typealias Key = Owner.Key
    final class Disk: @unchecked Sendable {
        let lock = NSLock()
        var writes: [(Owner.Key, Data)] = []
    }
    let disk = Disk()
    let owner: Owner
    var admitted: [Data] { disk.lock.withLock { disk.writes.map { $0.1 } } }
    var devices: [String] { disk.lock.withLock { disk.writes.map { $0.0.deviceID } } }
    init() {
        let disk = self.disk
        owner = Owner(storage: .init(remove: { _, _ in true }, put: { key, data in
            disk.lock.withLock { disk.writes.append((key, data)) }
        }, contents: { _, _ in [] }, revoke: { deviceID in
            disk.lock.withLock { disk.writes.removeAll { $0.0.deviceID == deviceID } }
        }), automatic: false)
    }
    func store(_ key: Key, payload: Data, clipboardTrust: Owner.ClipboardTrustToken? = nil) {
        owner.store(key, payload: payload, clipboardTrust: clipboardTrust); owner.drain()
    }
    func invalidateDevice(_ deviceID: String, occurrence: UUID = UUID(), revoke: Bool = false, clipboardFingerprint: Data? = nil, clipboardIdentity: Data? = nil) {
        owner.invalidateDevice(deviceID, occurrence: occurrence, revoke: revoke, clipboardFingerprint: clipboardFingerprint, clipboardIdentity: clipboardIdentity)
    }
    func reevaluateClipboardRoutes(deviceID: String) { owner.reevaluateClipboardRoutes(deviceID: deviceID) }
    func clipboardTrustToken(deviceID: String) -> Owner.ClipboardTrustToken? { owner.clipboardTrustToken(deviceID: deviceID) }
    func isCurrent(_ token: Owner.ClipboardTrustToken, routeID: String? = nil, sourceIdentity: Data? = nil) -> Bool {
        owner.isCurrent(token, routeID: routeID, sourceIdentity: sourceIdentity)
    }
    func clipboardValidationToken(deviceID: String, fingerprint: Data, routes: Set<String>) -> Owner.ClipboardTrustToken? {
        owner.clipboardValidationToken(deviceID: deviceID, fingerprint: fingerprint, routes: routes)
    }
    func validateClipboardRoutes(_ token: Owner.ClipboardTrustToken, fingerprint: Data, evaluated: Set<String>, approved: Set<String>) {
        owner.validateClipboardRoutes(token, fingerprint: fingerprint, evaluated: evaluated, approved: approved)
    }
}

struct GBClipboardUpdate {
    var changeID = ""
    var kind = GBClipboardKind.text
    var content = Data()
    var sensitive = false
}
enum CompanionConnectionState { case connected, disconnected }
@MainActor final class CompanionTLSClient {
    let authenticatedSessionID: String
    let peer: PairedPeer
    var sent: [Data] = []
    init(peer: PairedPeer, sessionID: String = UUID().uuidString) { self.peer = peer; authenticatedSessionID = sessionID }
    func sendClipboard(_ update: GBClipboardUpdate) throws { sent.append(update.content) }
}
struct CompanionConnections { let control: CompanionTLSClient }
@MainActor final class ScrcpyClipboardSession {
    var serial = "fixture-serial"
    var clipboardTrustGeneration = UUID()
    var clipboardTrustPeer: PairedPeer?
    var usesClipboardOccurrences = false
    var supportsClipboardAvailability = true
    var sent: [String] = []
    func setText(_ text: String, changeID: String) -> Bool { sent.append(text); return true }
}
@MainActor final class ScrcpySession {
    var serial = "fixture-serial"
    var clipboardTrustGeneration = UUID()
    var clipboardTrustPeer: PairedPeer?
    var sent: [Data] = []
    func sendControl(_ data: Data) { sent.append(data) }
}
enum ScrcpyControlMessage {
    static func setClipboard(sequence: UInt64, text: String, paste: Bool) -> Data { Data(text.utf8) }
}
struct ADBBindingStore {
    func isVerified(serial: String, peer: PairedPeer) -> Bool { false }
}
@MainActor final class ClipboardBootstrapProbe {
    var trusted: [PairedPeer] = []
    func peers(merging: [PairedPeer]) -> [PairedPeer] { trusted }
}
struct TestCaptureRoute { let shellProvider: Bool? = true }
@MainActor final class ClipboardAppModelProbe {
    let clientSetup: ClientSetupModel
    let clipboardPasteboard = TestPasteboard()
    let clipboardConversion: MacClipboardConversionWorker
    var lastPasteboardChangeCount = 0
    var terminationAdmission = TestTerminationAdmission()
    var devices: [TestDevice] = []
    var clipboardHub = ClipboardHubState()
    var seenClipboardChangeIDs = Set<String>()
    let cacheMaintenance = ClipboardCacheAdmissionProbe()
    var companionStates: [String: CompanionConnectionState] = [:]
    var companionClients: [String: CompanionConnections] = [:]
    var filePeerFingerprints: [String: Data] = [:]
    var clipboardSessions: [String: ScrcpyClipboardSession] = [:]
    var scrcpySessions: [String: ScrcpySession] = [:]
    var clipboardSequence: UInt64 = 1
    var clipboardVerifiedADBIdentities: [String: Data] = [:]
    var controls: [CompanionTLSClient] = []
    var companionConnectionBootstrap: ClipboardBootstrapProbe? = ClipboardBootstrapProbe()
    var clipboardReconnectTasks: [String: Task<Void, Never>] = [:]
    var clipboardReconnectAttempts: [String: Int] = [:]
    var enhancedReconnectTasks: [String: Task<Void, Never>] = [:]
    var enhancedReconnectAttempts: [String: Int] = [:]
    func detachGamepads(from: String) {}
    func syncGamepadsToSelectedSession() {}
    func loadEnhancedDisplays(deviceID: String, serial: String) {}
    func mergeDevices() { revalidateClipboardTrust(for: companionConnectionBootstrap?.peers(merging: []) ?? []) }

    var cancellables = Set<AnyCancellable>()
    var broadcasts: [Data] { controls.flatMap(\.sent) }
    init(queue: DispatchQueue,
         featureStorageURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("gb-clipboard-features-" + UUID().uuidString).appendingPathComponent("choices.json"),
         encode: @escaping @Sendable (MacClipboardImageSource) -> Data?) {
        clientSetup = ClientSetupModel(storageURL: featureStorageURL)
        clipboardConversion = MacClipboardConversionWorker(queue: queue, encodeImage: encode)
    }
    static func clipboardImageSource(from pasteboard: TestPasteboard) -> MacClipboardImageSource? {
        pasteboard.snapshotReads += 1
        return pasteboard.image
    }
    // Baseline dependency boundary: the original synchronous method used this
    // entry point. It also reads only fixture bytes, never the global pasteboard.
    static func pngData(from pasteboard: TestPasteboard) -> Data? {
        pasteboard.snapshotReads += 1
        return Data([1])
    }
    @discardableResult func connect(_ id: String, fingerprint: Data = Data([1])) -> CompanionTLSClient {
        let control = CompanionTLSClient(peer: PairedPeer(deviceID: id, displayName: id, identityPublicKey: fingerprint,
            tlsCertificateSHA256: Data(repeating: 0x5a, count: 32), pairedAt: Date(timeIntervalSince1970: 1)))
        controls.append(control)
        companionClients[id] = CompanionConnections(control: control)
        companionStates[id] = .connected
        filePeerFingerprints[id] = fingerprint
        devices.removeAll { $0.id == id }; devices.append(.init(id: id))
        return control
    }
    @discardableResult func connectPeer(_ peer: PairedPeer) -> CompanionTLSClient {
        let id = "device:" + peer.deviceID
        let control = CompanionTLSClient(peer: peer)
        controls.append(control); companionClients[id] = CompanionConnections(control: control)
        companionStates[id] = .connected
        filePeerFingerprints[id] = OutgoingFileTransferStore.peerFingerprint(identityKey: peer.identityPublicKey,
            tlsFingerprint: peer.tlsCertificateSHA256, pairedAt: peer.pairedAt)
        devices.removeAll { $0.id == id }; devices.append(.init(id: id))
        return control
    }
    func companionControl(for deviceID: String) -> CompanionTLSClient? { companionClients[deviceID]?.control }
    func companionID(for deviceID: String) -> String? { companionClients[deviceID] == nil ? nil : deviceID }
    func row(id: String) -> TestDevice? { devices.first { $0.id == id } }
    func clientSetupEvidenceReceipt(deviceID: String, feature: Feature) -> (() -> Void)? { nil }
    enum Feature { case clipboard }
    // ACTUAL_APP_MODEL_CLIPBOARD_METHODS
}
@main enum ClipboardConversionIntegrationSpec {
    @MainActor static func main() async throws {
        await repeatedVendorCopiesDoNotRewriteEveryPhone()
        try await disabledFeatureIsolatesPhone()
        let eligibilityQueue = DispatchQueue(label: "clipboard.integration.eligibility")
        let ineligible = ClipboardAppModelProbe(queue: eligibilityQueue, encode: { _ in preconditionFailure("No eligible encoder work") })
        ineligible.publishClipboardIfChanged()
        precondition(ineligible.clipboardPasteboard.snapshotReads == 0 && ineligible.broadcasts.isEmpty,
            "AppModel must skip image capture and broadcast without a ready destination")
        ineligible.connect("phone")
        ineligible.clipboardPasteboard.changeCount = 2
        ineligible.clipboardPasteboard.types = [.init(rawValue: "org.nspasteboard.ConcealedType")]
        ineligible.publishClipboardIfChanged()
        precondition(ineligible.clipboardPasteboard.snapshotReads == 0, "AppModel must reject sensitive types before image snapshot")

        let queue = DispatchQueue(label: "clipboard.integration.occurrence")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let probe = ClipboardAppModelProbe(queue: queue, encode: { source in
            guard case let .encoded(data) = source else { preconditionFailure() }
            if data == Data([1]) { entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success) }
            return data
        })
        probe.connect("phone")
        probe.publishClipboardIfChanged()
        precondition(entered.wait(timeout: .now() + 5) == .success, "Image conversion must run asynchronously")
        // No second poll has occurred yet. Live pasteboard occurrence still
        // fences completion before the next 500 ms system poll.
        probe.clipboardPasteboard.changeCount = 2
        release.signal()
        await Task.detached { queue.sync {} }.value
        for _ in 0..<20 { await Task.yield() }
        precondition(probe.broadcasts.isEmpty, "Changed clipboard must reject an old completion before another poll")
        probe.clipboardPasteboard.image = .encoded(Data([2]))
        probe.publishClipboardIfChanged()
        await Task.detached { queue.sync {} }.value
        for _ in 0..<100 where probe.broadcasts.isEmpty { await Task.yield() }
        precondition(probe.broadcasts == [Data([2])], "Current occurrence must be broadcast once")
        probe.publishClipboardIfChanged()
        precondition(probe.broadcasts.count == 1, "Unchanged clipboard must not echo")
        // Accept a real remote event through AppModel while a local conversion
        // is blocked. It supersedes that conversion and records the write count.
        probe.clipboardPasteboard.changeCount = 3
        probe.clipboardPasteboard.image = .encoded(Data([1]))
        probe.publishClipboardIfChanged()
        precondition(entered.wait(timeout: .now() + 5) == .success)
        let remote = Data("remote copy".utf8)
        probe.acceptRemoteClipboard(deviceID: "phone", changeID: "remote-1", kind: .text, content: remote, sensitive: false)
        release.signal()
        await Task.detached { queue.sync {} }.value
        for _ in 0..<20 { await Task.yield() }
        precondition(probe.broadcasts == [Data([2])],
            "Remote acceptance must fence old local conversion and exclude its source from fanout")
        precondition(probe.cacheMaintenance.admitted == [Data([2]), remote] && probe.clipboardPasteboard.text == "remote copy")
        probe.clipboardPasteboard.changeCount += 1
        probe.clipboardPasteboard.image = .encoded(Data([1]))
        probe.publishClipboardIfChanged()
        precondition(entered.wait(timeout: .now() + 5) == .success)
        let unchangedRemoteCount = probe.clipboardPasteboard.changeCount
        probe.acceptRemoteClipboard(deviceID: "phone", changeID: "remote-2", kind: .text, content: remote, sensitive: false)
        precondition(probe.clipboardPasteboard.changeCount == unchangedRemoteCount,
            "Identical remote bytes must exercise supersession without a pasteboard write")
        release.signal()
        await Task.detached { queue.sync {} }.value
        for _ in 0..<20 { await Task.yield() }
        precondition(probe.broadcasts == [Data([2])],
            "An identical remote occurrence must invalidate pending local work even when changeCount stays equal")
        probe.acceptRemoteClipboard(deviceID: "phone", changeID: "remote-1", kind: .text, content: remote, sensitive: false)
        let reads = probe.clipboardPasteboard.snapshotReads
        probe.publishClipboardIfChanged()
        precondition(probe.clipboardPasteboard.snapshotReads == reads && probe.broadcasts.count == 1,
            "A remote write and duplicate event must not echo through the next clipboard poll")
        await shellReadinessReevaluatesUnchangedGeneration()
        await inboundPromotionQuarantineRejectsOldSource()
        await independentWindowClipboardKeepsItsOwnCallback()
        await promotionBeforeDeferredMergeFencesClipboard()
        await recipientsStayBoundToCopyOccurrence()
        await clipboardFallbackKeepsOriginalRoute()
        print("PASS actual AppModel clipboard poll/completion: real per-phone disabled send/history/input isolation, early eligibility, async conversion, live occurrence fence, unchanged and remote echo suppression")
    }
    @MainActor static func repeatedVendorCopiesDoNotRewriteEveryPhone() async {
        let probe = ClipboardAppModelProbe(queue: DispatchQueue(label: "clipboard.integration.vendor-recopy"), encode: { _ in nil })
        let ids = (0..<3).map { _ in "device:" + UUID().uuidString.lowercased() }
        let a = probe.connect(ids[0]), b = probe.connect(ids[1]), c = probe.connect(ids[2])
        for id in ids { probe.clipboardSessions[id] = ScrcpyClipboardSession() }
        func copy(_ id: String, _ occurrence: String, _ content: Data) {
            probe.acceptRemoteClipboard(deviceID: id, changeID: occurrence, kind: .text, content: content, sensitive: false,
                sourceRouteID: "clipboard:" + probe.clipboardSessions[id]!.clipboardTrustGeneration.uuidString)
        }
        let first = Data("first copy".utf8), second = Data("next copy".utf8)
        copy(ids[0], "genuine-first", first)
        precondition(b.sent == [first] && c.sent == [first])
        for index in 0..<10 {
            copy(ids[1 + index % 2], "vendor-new-occurrence-\(index)", first)
        }
        precondition(a.sent.isEmpty && b.sent.count <= 2 && c.sent.count <= 2,
            "A vendor keyboard recopy with a fresh ID must not rewrite an unchanged clipboard on every other phone")
        copy(ids[0], "deliberate-identical-recopy", first)
        precondition(probe.seenClipboardChangeIDs.contains("deliberate-identical-recopy"),
            "Identical genuine copies must still be admitted as occurrences and history")
        copy(ids[0], "genuine-next", second)
        precondition(b.sent.last == second && c.sent.last == second && probe.clipboardPasteboard.text == "next copy")
        copy(ids[1], "genuine-previous-content-recopy", first)
        precondition(a.sent == [first] && c.sent.last == first && probe.clipboardPasteboard.text == "first copy",
            "A genuine later copy of an older value must replace the newer clipboard")
        let replacement = probe.connect(ids[2])
        probe.broadcastClipboard(kind: .text, content: first, changeID: "fresh-after-route-replacement", excluding: nil)
        precondition(replacement.sent == [first], "A new authenticated route must not inherit an old payload claim")
    }
    @MainActor static func disabledFeatureIsolatesPhone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-clipboard-feature-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "clipboard.integration.feature-policy")
        let probe = ClipboardAppModelProbe(queue: queue, featureStorageURL: root.appendingPathComponent("choices.json"), encode: { _ in nil })
        let first = "device:" + UUID().uuidString.lowercased(), second = "device:" + UUID().uuidString.lowercased()
        let a = probe.connect(first, fingerprint: Data([11])), b = probe.connect(second, fingerprint: Data([22]))
        try probe.clientSetup.saveSelection(deviceID: first, features: Set(ClientSetupFeature.shippingFeatures).subtracting([.clipboard]))
        probe.clipboardPasteboard.image = nil
        probe.publishClipboardIfChanged()
        await Task.detached { queue.sync {} }.value
        for _ in 0..<100 { await Task.yield() }
        precondition(a.sent.isEmpty && b.sent == [Data("fixture".utf8)] && probe.cacheMaintenance.devices == [second],
            "Clipboard OFF must prevent outbound send/history for A while B remains active")
        let before = probe.cacheMaintenance.admitted
        probe.acceptRemoteClipboard(deviceID: first, changeID: "disabled-A", kind: .text, content: Data("blocked".utf8), sensitive: false)
        precondition(probe.clipboardPasteboard.text == "fixture" && probe.cacheMaintenance.admitted == before && !probe.seenClipboardChangeIDs.contains("disabled-A"),
            "Clipboard OFF must reject remote input before pasteboard/history/dedupe admission")
        probe.acceptRemoteClipboard(deviceID: second, changeID: "enabled-B", kind: .text, content: Data("allowed".utf8), sensitive: false)
        precondition(probe.clipboardPasteboard.text == "allowed" && probe.cacheMaintenance.devices == [second, second] && a.sent.isEmpty,
            "Disabled A must not receive fanout from B or disable B's inbound clipboard")
    }
    @MainActor static func recipientsStayBoundToCopyOccurrence() async {
        for scenario in ["late join", "identity replacement", "connection replacement", "trust replacement", "other recipient revoked", "unchanged"] {
            let queue = DispatchQueue(label: "clipboard.integration.recipients")
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let probe = ClipboardAppModelProbe(queue: queue, encode: { _ in
                entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success)
                return Data([7])
            })
            let a = probe.connect("A", fingerprint: Data([11]))
            if scenario == "other recipient revoked" { probe.connect("B", fingerprint: Data([22])) }
            probe.publishClipboardIfChanged()
            precondition(entered.wait(timeout: .now() + 5) == .success)
            var b: CompanionTLSClient?
            if scenario == "late join" { b = probe.connect("B", fingerprint: Data([22])) }
            if scenario == "identity replacement" { probe.connect("A", fingerprint: Data([33])) }
            if scenario == "connection replacement" { probe.connect("A", fingerprint: Data([11])) }
            if scenario == "trust replacement" { probe.filePeerFingerprints["A"] = Data([33]) }
            if scenario == "other recipient revoked" {
                probe.devices.removeAll { $0.id == "B" }
                probe.companionClients.removeValue(forKey: "B")
                probe.filePeerFingerprints.removeValue(forKey: "B")
            }
            release.signal()
            await Task.detached { queue.sync {} }.value
            for _ in 0..<100 { await Task.yield() }
            if ["identity replacement", "connection replacement", "trust replacement"].contains(scenario) {
                precondition(probe.broadcasts.isEmpty && probe.cacheMaintenance.admitted.isEmpty,
                    "A replacement identity must receive and cache none of the old copy")
            } else {
                precondition(a.sent == [Data([7])], "An unchanged eligible A must still receive the copy")
                precondition(b?.sent.isEmpty ?? true, "A phone joining during conversion must not receive the old copy")
                precondition(probe.cacheMaintenance.devices == ["A"], "Only the admitted copy recipient may get cached history")
            }
        }
    }

    @MainActor static func clipboardFallbackKeepsOriginalRoute() async {
        for replaceOriginalRoute in [false, true] {
            let queue = DispatchQueue(label: "clipboard.integration.fallback")
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            queue.async { entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success) }
            precondition(entered.wait(timeout: .now() + 5) == .success)
            let probe = ClipboardAppModelProbe(queue: queue, encode: { _ in preconditionFailure("Text has no image conversion") })
            probe.devices = [.init(id: "A")]
            probe.filePeerFingerprints["A"] = Data([11])
            let original = ScrcpyClipboardSession()
            probe.clipboardSessions["A"] = original
            probe.clipboardPasteboard.image = nil
            probe.publishClipboardIfChanged()
            let newControl = probe.connect("A", fingerprint: Data([11]))
            let replacement = ScrcpyClipboardSession()
            if replaceOriginalRoute { probe.clipboardSessions["A"] = replacement }
            release.signal()
            await Task.detached { queue.sync {} }.value
            for _ in 0..<100 { await Task.yield() }
            precondition(newControl.sent.isEmpty && replacement.sent.isEmpty,
                "Newly admitted routes must not acquire an older clipboard occurrence")
            if replaceOriginalRoute {
                precondition(original.sent.isEmpty && probe.cacheMaintenance.admitted.isEmpty)
            } else {
                precondition(original.sent == ["fixture"] && probe.cacheMaintenance.devices == ["A"],
                    "An unchanged capture-free clipboard route must retain text delivery")
            }
        }
    }
    @MainActor static func promotionBeforeDeferredMergeFencesClipboard() async {
        let queue = DispatchQueue(label: "clipboard.integration.promotion")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let probe = ClipboardAppModelProbe(queue: queue, encode: { source in
            guard case let .encoded(data) = source else { preconditionFailure() }
            if data == Data([1]) || data == Data([3]) { entered.signal(); precondition(release.wait(timeout: .now() + 5) == .success) }
            return data
        })
        let aPeer = PairedPeer(deviceID: "A", displayName: "A", identityPublicKey: Data([11]),
            tlsCertificateSHA256: Data(repeating: 0x11, count: 32), pairedAt: Date(timeIntervalSince1970: 1))
        let bPeer = PairedPeer(deviceID: "B", displayName: "B", identityPublicKey: Data([22]),
            tlsCertificateSHA256: Data(repeating: 0x22, count: 32), pairedAt: Date(timeIntervalSince1970: 1))
        let a = probe.connectPeer(aPeer), b = probe.connectPeer(bPeer)
        let center = NotificationCenter()
        probe.installPairingObserver(in: center)
        probe.publishClipboardIfChanged()
        precondition(entered.wait(timeout: .now() + 5) == .success)
        let oldFingerprint = probe.filePeerFingerprints["device:B"]
        // Exact synchronous PairingStored subscription, before any deferred
        // Bootstrap merge updates the model fingerprint or transport object.
        CompanionLifecycleEvents.pairingStored(bPeer, notificationCenter: center)
        precondition(probe.filePeerFingerprints["device:B"] == oldFingerprint && probe.companionClients["device:B"]?.control === b)
        release.signal(); await Task.detached { queue.sync {} }.value
        for _ in 0..<100 { await Task.yield() }
        precondition(a.sent == [Data([1])] && b.sent.isEmpty && probe.cacheMaintenance.devices == ["device:A"],
            "Promotion must synchronously fence B's old conversion/cache before deferred model refresh, preserving A")
        probe.clipboardPasteboard.changeCount += 1; probe.clipboardPasteboard.image = .encoded(Data([2]))
        probe.publishClipboardIfChanged()
        await Task.detached { queue.sync {} }.value
        for _ in 0..<100 { await Task.yield() }
        precondition(a.sent == [Data([1]), Data([2])] && b.sent.isEmpty && probe.cacheMaintenance.devices == ["device:A", "device:A"],
            "Fresh polling during promotion quarantine must not admit B's still-old route")
        // Identical peer metadata still requires explicit reconciliation of
        // the promoted epoch. Ordinary cache writes must not revoke that epoch.
        probe.revalidateClipboardTrust(for: [bPeer])
        probe.clipboardPasteboard.changeCount += 1; probe.clipboardPasteboard.image = .encoded(Data([3]))
        probe.publishClipboardIfChanged()
        precondition(entered.wait(timeout: .now() + 5) == .success)
        probe.cacheMaintenance.store(.init(deviceID: "device:B", namespace: .notifications, itemID: "ordinary-update"), payload: Data([9]))
        release.signal(); await Task.detached { queue.sync {} }.value
        for _ in 0..<100 { await Task.yield() }
        precondition(a.sent.last == Data([3]) && b.sent == [Data([3])],
            "Explicitly revalidated trust must resume fresh copies and survive ordinary cache mutations")

        let replacement = PairedPeer(deviceID: "B", displayName: "B", identityPublicKey: Data([33]),
            tlsCertificateSHA256: Data(repeating: 0x33, count: 32), pairedAt: Date(timeIntervalSince1970: 2))
        CompanionLifecycleEvents.pairingStored(replacement, notificationCenter: center)
        probe.revalidateClipboardTrust(for: [replacement]) // model is still stale
        probe.filePeerFingerprints["device:B"] = OutgoingFileTransferStore.peerFingerprint(identityKey: replacement.identityPublicKey,
            tlsFingerprint: replacement.tlsCertificateSHA256, pairedAt: replacement.pairedAt)
        probe.revalidateClipboardTrust(for: [replacement]) // old authenticated control is not the promoted identity
        probe.clipboardPasteboard.changeCount += 1; probe.clipboardPasteboard.image = .encoded(Data([4]))
        probe.publishClipboardIfChanged(); await Task.detached { queue.sync {} }.value
        for _ in 0..<100 { await Task.yield() }
        precondition(a.sent.last == Data([4]) && b.sent == [Data([3])],
            "Refreshing model metadata alone must not re-authorize an old peer's control")
        let newB = probe.connectPeer(replacement)
        probe.revalidateClipboardTrust(for: [replacement])
        probe.clipboardPasteboard.changeCount += 1; probe.clipboardPasteboard.image = .encoded(Data([5]))
        probe.publishClipboardIfChanged(); await Task.detached { queue.sync {} }.value
        for _ in 0..<100 { await Task.yield() }
        precondition(newB.sent == [Data([5])] && b.sent == [Data([3])],
            "Only the promoted authenticated identity may resume delivery after reconciliation")
    }

    @MainActor static func inboundPromotionQuarantineRejectsOldSource() async {
        let queue = DispatchQueue(label: "clipboard.integration.inbound-trust")
        let probe = ClipboardAppModelProbe(queue: queue, encode: { _ in nil })
        let aPeer = PairedPeer(deviceID: "A", displayName: "A", identityPublicKey: Data([11]),
            tlsCertificateSHA256: Data(repeating: 0x11, count: 32), pairedAt: Date(timeIntervalSince1970: 1))
        let bPeer = PairedPeer(deviceID: "B", displayName: "B", identityPublicKey: Data([22]),
            tlsCertificateSHA256: Data(repeating: 0x22, count: 32), pairedAt: Date(timeIntervalSince1970: 1))
        probe.connectPeer(aPeer); probe.connectPeer(bPeer)
        let center = NotificationCenter(); probe.installPairingObserver(in: center)
        CompanionLifecycleEvents.pairingStored(bPeer, notificationCenter: center)
        probe.acceptRemoteClipboard(deviceID: "device:B", changeID: "old-B-in-gap", kind: .text,
            content: Data("old B".utf8), sensitive: false)
        precondition(probe.clipboardPasteboard.text == "fixture" && probe.cacheMaintenance.admitted.isEmpty
            && !probe.seenClipboardChangeIDs.contains("old-B-in-gap"),
            "A quarantined old remote source must not mutate the hub, Mac pasteboard, or new-generation cache")
        probe.acceptRemoteClipboard(deviceID: "device:A", changeID: "valid-A-in-gap", kind: .text,
            content: Data("valid A".utf8), sensitive: false,
            sourceRouteID: "control:" + probe.companionClients["device:A"]!.control.authenticatedSessionID)
        precondition(probe.clipboardPasteboard.text == "valid A" && probe.cacheMaintenance.devices == ["device:A"],
            "B's promotion must not disable an unaffected A's inbound clipboard")
        probe.revalidateClipboardTrust(for: [bPeer])
        let bRoute = "control:" + probe.companionClients["device:B"]!.control.authenticatedSessionID
        probe.acceptRemoteClipboard(deviceID: "device:B", changeID: "valid-B-revalidated", kind: .text,
            content: Data("valid B".utf8), sensitive: false, sourceRouteID: bRoute)
        precondition(probe.clipboardPasteboard.text == "valid B" && probe.seenClipboardChangeIDs.contains("valid-B-revalidated"))
        let replacement = PairedPeer(deviceID: "B", displayName: "B", identityPublicKey: Data([33]),
            tlsCertificateSHA256: Data(repeating: 0x33, count: 32), pairedAt: Date(timeIntervalSince1970: 2))
        CompanionLifecycleEvents.pairingStored(replacement, notificationCenter: center)
        let newB = probe.connectPeer(replacement); probe.revalidateClipboardTrust(for: [replacement])
        let before = probe.cacheMaintenance.admitted
        probe.acceptRemoteClipboard(deviceID: "device:B", changeID: "old-B-after-new-route", kind: .text,
            content: Data("old B again".utf8), sensitive: false, sourceRouteID: bRoute)
        precondition(probe.clipboardPasteboard.text == "valid B" && probe.cacheMaintenance.admitted == before,
            "An old route must stay denied after a different route is approved")
        probe.acceptRemoteClipboard(deviceID: "device:B", changeID: "new-B-approved", kind: .text,
            content: Data("new B".utf8), sensitive: false, sourceRouteID: "control:" + newB.authenticatedSessionID)
        precondition(probe.clipboardPasteboard.text == "new B")
    }

    @MainActor static func independentWindowClipboardKeepsItsOwnCallback() async {
        let queue = DispatchQueue(label: "clipboard.integration.independent-window")
        let probe = ClipboardAppModelProbe(queue: queue, encode: { _ in nil })
        let peer = PairedPeer(deviceID: "window", displayName: "window", identityPublicKey: Data([44]),
            tlsCertificateSHA256: Data(repeating: 0x44, count: 32), pairedAt: Date(timeIntervalSince1970: 1))
        let id = "device:window"
        probe.devices = [.init(id: id)]
        probe.filePeerFingerprints[id] = OutgoingFileTransferStore.peerFingerprint(identityKey: peer.identityPublicKey,
            tlsFingerprint: peer.tlsCertificateSHA256, pairedAt: peer.pairedAt)
        probe.clipboardVerifiedADBIdentities["fixture-serial"] = ClipboardPeerIdentity.fingerprint(publicKey: peer.identityPublicKey,
            tlsFingerprint: peer.tlsCertificateSHA256)
        let identity = probe.enhancedClipboardIdentity(deviceID: id, serial: "fixture-serial")
        precondition(identity != nil && probe.companionClients.isEmpty && probe.clipboardSessions.isEmpty && probe.scrcpySessions.isEmpty)
        probe.acceptEnhancedClipboard(deviceID: id, changeID: "window-before", content: Data("window before".utf8), sourceIdentity: identity)
        precondition(probe.clipboardPasteboard.text == "window before")
        let center = NotificationCenter(); probe.installPairingObserver(in: center)
        CompanionLifecycleEvents.pairingStored(peer, notificationCenter: center)
        probe.acceptEnhancedClipboard(deviceID: id, changeID: "window-in-gap", content: Data("window gap".utf8), sourceIdentity: identity)
        precondition(probe.clipboardPasteboard.text == "window before" && !probe.seenClipboardChangeIDs.contains("window-in-gap"))
        probe.revalidateClipboardTrust(for: [peer])
        probe.acceptEnhancedClipboard(deviceID: id, changeID: "window-revalidated", content: Data("window after".utf8), sourceIdentity: identity)
        precondition(probe.clipboardPasteboard.text == "window after",
            "An unchanged independent app-window callback must work without a primary/capture-free/Companion route")
        let replacement = PairedPeer(deviceID: "window", displayName: "window", identityPublicKey: Data([55]),
            tlsCertificateSHA256: Data(repeating: 0x55, count: 32), pairedAt: Date(timeIntervalSince1970: 2))
        CompanionLifecycleEvents.pairingStored(replacement, notificationCenter: center)
        probe.filePeerFingerprints[id] = OutgoingFileTransferStore.peerFingerprint(identityKey: replacement.identityPublicKey,
            tlsFingerprint: replacement.tlsCertificateSHA256, pairedAt: replacement.pairedAt)
        probe.revalidateClipboardTrust(for: [replacement])
        probe.acceptEnhancedClipboard(deviceID: id, changeID: "old-window-identity", content: Data("old identity".utf8), sourceIdentity: identity)
        precondition(probe.clipboardPasteboard.text == "window after")
        let newIdentity = ClipboardPeerIdentity.fingerprint(publicKey: replacement.identityPublicKey, tlsFingerprint: replacement.tlsCertificateSHA256)
        probe.acceptEnhancedClipboard(deviceID: id, changeID: "new-window-identity", content: Data("new identity".utf8), sourceIdentity: newIdentity)
        precondition(probe.clipboardPasteboard.text == "new identity")
    }

    @MainActor static func shellReadinessReevaluatesUnchangedGeneration() async {
        for primary in [false, true] {
            let queue = DispatchQueue(label: "clipboard.integration.shell-ready")
            let probe = ClipboardAppModelProbe(queue: queue, encode: { _ in nil })
            let peer = PairedPeer(deviceID: "shell", displayName: "shell", identityPublicKey: Data([66]),
                tlsCertificateSHA256: Data(repeating: 0x66, count: 32), pairedAt: Date(timeIntervalSince1970: 1))
            let id = "device:shell", serial = "shell:shell"
            probe.devices = [.init(id: id)]
            probe.filePeerFingerprints[id] = OutgoingFileTransferStore.peerFingerprint(identityKey: peer.identityPublicKey,
                tlsFingerprint: peer.tlsCertificateSHA256, pairedAt: peer.pairedAt)
            probe.companionConnectionBootstrap?.trusted = [peer]
            let clipboard = ScrcpyClipboardSession(), screen = ScrcpySession()
            clipboard.serial = serial; screen.serial = serial
            if primary { probe.scrcpySessions[id] = screen } else { probe.clipboardSessions[id] = clipboard }
            let center = NotificationCenter(); probe.installPairingObserver(in: center)
            CompanionLifecycleEvents.pairingStored(peer, notificationCenter: center)
            probe.revalidateClipboardTrust(for: [peer]) // lease peer has not arrived yet
            precondition(probe.clipboardRecipients(excluding: nil).isEmpty)
            let generation = primary ? screen.clipboardTrustGeneration : clipboard.clipboardTrustGeneration
            if primary { screen.clipboardTrustPeer = peer; probe.primaryStreamingReady(targetID: id, serial: serial) }
            else { clipboard.clipboardTrustPeer = peer; probe.captureFreeReady(deviceID: id, readySerial: serial) }
            precondition((primary ? screen.clipboardTrustGeneration : clipboard.clipboardTrustGeneration) == generation)
            probe.clipboardPasteboard.image = nil
            probe.publishClipboardIfChanged(); await Task.detached { queue.sync {} }.value
            for _ in 0..<100 { await Task.yield() }
            precondition(probe.cacheMaintenance.devices == [id] && (primary ? screen.sent == [Data("fixture".utf8)] : clipboard.sent == ["fixture"]),
                "Shell readiness must re-evaluate nil-to-peer evidence without requiring a new generation")
        }
    }

}
