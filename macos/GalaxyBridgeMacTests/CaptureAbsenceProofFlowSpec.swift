import Foundation
import OSLog
import CryptoKit

struct GBShellCaptureOptions { var scid: UInt32 = 0 }
struct GBShellBridgeRequest { enum Operation { case status, listApplications, startScrcpy, verifyRetirement, releaseRetiredResource } }
struct GBCaptureRetirementQuery {
    enum Kind: Equatable { case probeSupport, scrcpyCapture, displayPowerController, UNRECOGNIZED(Int) }
    var kind = Kind.probeSupport
    var scid: UInt32 = 0
    var pid: UInt32 = 0
    var processStartTicks: UInt64 = 0
    var ownedResourceID = ""
    var resourceSha256 = Data()
}
struct GBPhysicalPanelPowerState { var physicalID: String; var on: Bool }
struct GBCaptureRetirementProof {
    var kind = GBCaptureRetirementQuery.Kind.probeSupport
    var scid: UInt32 = 0
    var pid: UInt32 = 0
    var processStartTicks: UInt64 = 0
    var supported = false
    var absent = false
    var panels: [GBPhysicalPanelPowerState] = []
    var ownedResourceID = ""
    var resourceRemoved = false
}
struct GBShellBridgeResult {
    var available = true
    var errorCode = ""
    var state = "panel_off"
    var streamIds: [String] = []
    var bootGeneration = "boot-one"
    var hasRetirementProof = false
    var retirementProof = GBCaptureRetirementProof()
}
enum ScrcpyLaunchConfiguration { static let serverSHA256Hex = String(repeating: "11", count: 32) }
struct ProofContext { var sessionID: String }
struct ProofControl { var authenticatedSessionID: String; var supportsCaptureRetirementProof = true }
@MainActor final class ProviderFixture {
    enum Mode { case supported, legacy, unavailable, timeout }
    enum AbsenceProofSupport { case unknown, supported, legacy, unavailable }
    struct Pending { var operation: GBShellBridgeRequest.Operation }
    var available = true
    var bootGeneration: String? = "boot-one"
    var currentSession = "authenticated-session"
    var helperSupportsProof = true
    var absenceProofSupport = AbsenceProofSupport.unknown
    var absenceProofGeneration: String?
    var leases: [String: Int] = [:]
    var pending: [String: Pending] = [:]
    var mode = Mode.supported
    var forcedReply: GBShellBridgeResult?
    var mutateProof: ((inout GBCaptureRetirementProof) -> Void)?
    var changeSession = false
    var changeBoot = false
    var calls: [UInt32] = []
    var operations: [GBShellBridgeRequest.Operation] = []
    var queries: [GBCaptureRetirementQuery] = []
    func context() throws -> ProofContext { .init(sessionID: currentSession) }
    func control() -> ProofControl? { .init(authenticatedSessionID: currentSession, supportsCaptureRetirementProof: helperSupportsProof) }
    func perform(operation: GBShellBridgeRequest.Operation, lease: String, generation: String,
                 context: ProofContext, options: GBShellCaptureOptions? = nil, powerOn: Bool = false,
                 retirement: GBCaptureRetirementQuery? = nil) async throws -> GBShellBridgeResult {
        precondition(lease.isEmpty && !powerOn)
        operations.append(operation); calls.append(retirement?.scid ?? 0)
        if let retirement { queries.append(retirement) }
        if changeSession { currentSession = "replacement-session" }
        if changeBoot { bootGeneration = "replacement-boot" }
        if let forcedReply { return forcedReply }
        var result = GBShellBridgeResult()
        guard let retirement else { precondition(operation == .status); return result }
        precondition(options == nil && (operation == .verifyRetirement || operation == .releaseRetiredResource))
        switch mode {
        case .legacy: result.state = "failed"; result.errorCode = "shell_operation_failed"; return result
        case .unavailable: result.state = "failed"; result.errorCode = "inventory_unavailable"; return result
        case .timeout: throw ShellCapabilityBridgeFailure.timeout
        case .supported: break
        }
        var proof = GBCaptureRetirementProof()
        proof.kind = retirement.kind; proof.scid = retirement.scid; proof.pid = retirement.pid
        proof.processStartTicks = retirement.processStartTicks; proof.supported = true
        proof.ownedResourceID = retirement.ownedResourceID
        proof.absent = retirement.kind != .probeSupport
        proof.resourceRemoved = operation == .releaseRetiredResource
        if retirement.kind == .displayPowerController && operation == .verifyRetirement {
            proof.panels = [.init(physicalID: "1", on: true), .init(physicalID: "2", on: false)]
        }
        if operation == .releaseRetiredResource {
            precondition(retirement.resourceSha256 == Data(repeating: 0x11, count: 32))
        } else { precondition(retirement.resourceSha256.isEmpty && retirement.ownedResourceID.isEmpty) }
        mutateProof?(&proof)
        result.state = operation == .releaseRetiredResource ? "resources_released" : retirement.kind == .probeSupport ? "retirement_supported" : "retired"
        result.hasRetirementProof = true; result.retirementProof = proof
        return result
    }
    // ACTUAL_PROVIDER_PROPERTIES
    // ACTUAL_PROVIDER_METHODS
}
final class ADBFixture: @unchecked Sendable {
    let fails: Bool
    private let lock = NSLock()
    private var values: [(String, UInt32)] = []
    var attempts: [(String, UInt32)] { lock.withLock { values } }
    init(fails: Bool) { self.fails = fails }
    func retireScrcpyServer(serial: String, scid: UInt32) throws {
        lock.withLock { values.append((serial, scid)) }
        if fails { throw ShellCapabilityBridgeFailure.unavailable }
    }
}
@MainActor final class CleanupFixture {
    let remoteRetirement = EnhancedRemoteRetirementFence(captureSerial: "captured-usb")
    let adb: ADBFixture
    let remoteAbsenceProof: EnhancedCaptureAbsenceProof?
    let logger = Logger(subsystem: "com.xopmc.GalaxyBridge.fixture", category: "CaptureAbsence")
    private(set) var localLaunchersSettled = false
    init(fails: Bool, proof: EnhancedCaptureAbsenceProof?) {
        adb = ADBFixture(fails: fails); remoteAbsenceProof = proof
        remoteRetirement.requireRetirement(scid: 18)
    }
    func retireLocalLaunchers() async { localLaunchersSettled = true }
    // ACTUAL_REMOTE_RETIREMENT
}
@MainActor final class ADBOwnedRuntime {
    static let shared = ADBOwnedRuntime()
    var activeGeneration: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
}
struct ADBBindingRecord { let adbSerial: String; let deviceID: String }
struct ProofADBRow { var isReady: Bool; var adbSerial: String? }
struct ProofPeer { var deviceID: String; var identityPublicKey: Data }
struct AuthenticatedProofControl { var peer: ProofPeer }
enum ProofConnectionState { case connected, disconnected }
@MainActor final class ModelProofFixture {
    var boundPeer: VerifiedCaptureRetirementPeer?
    var captureRetirementAuthorities: [String: CaptureRetirementAuthority] = [:]
    let provider = ProviderFixture()
    var adbRows: [ProofADBRow] = []
    var currentControl: AuthenticatedProofControl?
    var companionStates: [String: ProofConnectionState] = [:]
    func companionID(for id: String) -> String? { "control" }
    func companionControl(for id: String) -> AuthenticatedProofControl? { currentControl }
    func captureRetirementIdentity(deviceID: String, captureSerial: String) -> VerifiedCaptureRetirementPeer? { boundPeer }
    func retirementProvider(for peer: VerifiedCaptureRetirementPeer) -> ProviderFixture? {
        guard boundPeer?.publicKeySHA256 == peer.publicKeySHA256 else { return nil }
        return provider
    }
    // ACTUAL_PROOF_FACTORIES
}
@MainActor final class ProofCounter { var values: [UInt32] = [] }
@main struct CaptureAbsenceProofFlowSpec {
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: message, code: 1) }
    }
    @MainActor static func main() async throws {
        let firstPair = ModelProofFixture()
        let prePairProof = firstPair.captureRetirementAbsenceProof(deviceID: "adb:captured-usb", captureSerial: "captured-usb")
        try expect(prePairProof != nil, "a USB owner started before pairing cannot gain verified Helper retirement authority")
        var deniedBeforePairing = false
        do { try await prePairProof!(18) } catch { deniedBeforePairing = true }
        try expect(deniedBeforePairing && firstPair.provider.calls.isEmpty, "an unpaired USB capture must not consult any Helper")
        let firstPeer = VerifiedCaptureRetirementPeer(logicalDeviceID: "device:first", bindingDeviceID: "first",
            publicKeySHA256: Data(SHA256.hash(data: Data([1, 2, 3]))), bindingVerified: true)!
        let authority = firstPair.captureRetirementAuthorities["captured-usb"]!
        try expect(!authority.adopt(firstPeer, currentADBSerial: nil, generation: ADBOwnedRuntime.shared.activeGeneration), "a lost ADB route cannot acquire proof authority lazily")
        try expect(!authority.adopt(firstPeer, currentADBSerial: "other-usb", generation: ADBOwnedRuntime.shared.activeGeneration), "another live USB phone cannot authorize this capture")
        firstPair.boundPeer = firstPeer
        firstPair.currentControl = .init(peer: .init(deviceID: "first", identityPublicKey: Data([1, 2, 3])))
        firstPair.companionStates["control"] = .connected
        let binding = ADBBindingRecord(adbSerial: "captured-usb", deviceID: "first")
        firstPair.adoptCaptureRetirementIdentity(binding)
        try expect(authority.peer == nil, "signed binding without a currently live exact ADB route must not authorize an old owner")
        firstPair.adbRows = [.init(isReady: true, adbSerial: "captured-usb")]
        firstPair.companionStates["control"] = .disconnected
        firstPair.adoptCaptureRetirementIdentity(binding)
        try expect(authority.peer == nil, "disconnected authenticated session must not authorize adoption")
        firstPair.companionStates["control"] = .connected
        firstPair.adoptCaptureRetirementIdentity(binding)
        try expect(authority.peer?.deviceID == "first", "live verified first pairing must freeze the original USB owner's phone identity")
        try await prePairProof!(18)
        try expect(firstPair.provider.calls == [18], "the already-created capture must recover through its now-prepared same-phone Helper")
        let replacement = VerifiedCaptureRetirementPeer(logicalDeviceID: "device:other", bindingDeviceID: "other",
            publicKeySHA256: Data(repeating: 2, count: 32), bindingVerified: true)!
        try expect(!authority.adopt(replacement, currentADBSerial: "captured-usb", generation: ADBOwnedRuntime.shared.activeGeneration), "an adopted capture identity cannot be replaced")
        firstPair.boundPeer = replacement
        var deniedReplacement = false
        do { try await prePairProof!(18) } catch { deniedReplacement = true }
        try expect(deniedReplacement, "a new phone key must not inherit old capture proof authority")
        let beforeCrash = ModelProofFixture()
        let originalProof = beforeCrash.captureRetirementAbsenceProof(deviceID: "adb:captured-usb", captureSerial: "captured-usb")!
        let originalAuthority = beforeCrash.captureRetirementAuthorities["captured-usb"]!
        beforeCrash.boundPeer = firstPeer; beforeCrash.adbRows = [.init(isReady: true, adbSerial: "captured-usb")]
        beforeCrash.currentControl = .init(peer: .init(deviceID: "first", identityPublicKey: Data([1,2,3])))
        beforeCrash.companionStates["control"] = .connected
        ADBOwnedRuntime.shared.activeGeneration = UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        beforeCrash.adoptCaptureRetirementIdentity(binding)
        try expect(originalAuthority.peer == nil, "a replacement ADB generation must not assign an identity to the old unpaired capture")
        var oldUnpairedDenied = false
        do { try await originalProof(18) } catch { oldUnpairedDenied = true }
        try expect(oldUnpairedDenied, "a later pairing silently authorized retirement of a capture from a lost unverified route")
        _ = beforeCrash.captureRetirementAbsenceProof(deviceID: "device:first", captureSerial: "captured-usb")
        let newAuthority = beforeCrash.captureRetirementAuthorities["captured-usb"]!
        try expect(newAuthority !== originalAuthority && newAuthority.peer?.deviceID == "first",
            "a new verified capture inherited an unusable authority from the previous generation")
        let supported = ProviderFixture()
        let ready = await supported.refresh()
        try expect(ready && !supported.needsRuntimeUpgrade && supported.calls.count == 2,
            "a live broker must negotiate typed capture absence separately from ordinary panel status")
        try await supported.confirmADBCaptureAbsent(scid: 18)
        try expect(supported.calls.last == 18, "the exact captured SCID must reach the typed read-only request")
        for state in ["stopped", "ready", "panel_off", "retired"] {
            let old = ProviderFixture(); old.forcedReply = GBShellBridgeResult(state: state)
            var rejected = false
            do { try await old.confirmADBCaptureAbsent(scid: 18) } catch { rejected = true }
            try expect(rejected, "legacy untyped status cannot release this capture")
        }
        for mutation: (inout GBCaptureRetirementProof) -> Void in [
            { $0.scid = 19 }, { $0.pid = 42 }, { $0.processStartTicks = 1 },
            { $0.kind = .displayPowerController }, { $0.supported = false }, { $0.absent = false },
            { $0.panels = [.init(physicalID: "1", on: true)] }, { $0.ownedResourceID = "unexpected" }, { $0.resourceRemoved = true }] {
            let provider = ProviderFixture(); provider.mutateProof = mutation
            var rejected = false
            do { try await provider.confirmADBCaptureAbsent(scid: 18) } catch { rejected = true }
            try expect(rejected, "mismatched typed proof cannot settle a capture")
        }
        for reply in [GBShellBridgeResult(available: false, state: "retired"),
                      GBShellBridgeResult(errorCode: "failed", state: "retired"),
                      GBShellBridgeResult(state: "retired", streamIds: ["unexpected-stream"]),
                      GBShellBridgeResult(state: "retired", bootGeneration: "other-boot")] {
            let provider = ProviderFixture(); provider.forcedReply = reply
            var rejected = false
            do { try await provider.confirmADBCaptureAbsent(scid: 18) } catch { rejected = true }
            try expect(rejected, "unavailable/error/stream/boot mismatch cannot attest ownership")
        }
        for changedSession in [true, false] {
            let provider = ProviderFixture()
            provider.changeSession = changedSession; provider.changeBoot = !changedSession
            var rejected = false
            do { try await provider.confirmADBCaptureAbsent(scid: 18) } catch { rejected = true }
            try expect(rejected, "an in-flight replacement session or boot invalidates its proof")
        }
        for scid: UInt32 in [0, 0x80000000] {
            let provider = ProviderFixture(); var rejected = false
            do { try await provider.confirmADBCaptureAbsent(scid: scid) } catch { rejected = true }
            try expect(rejected && provider.calls.isEmpty, "invalid SCIDs must not reach the phone")
        }
        let oldHelper = ProviderFixture(); oldHelper.helperSupportsProof = false
        let oldReady = await oldHelper.refresh()
        try expect(oldReady && oldHelper.calls.count == 1 && !oldHelper.needsRuntimeUpgrade,
            "an older Helper remains usable and never receives an unsupported typed operation")
        let initial = try PhonePanelPowerSnapshot(validating: [.init(id: "1", on: true), .init(id: "2", on: false)])
        let process = DisplayPowerControllerIdentity(pid: 42, startTime: "123456")
        let panel = ProviderFixture()
        try await panel.confirmDisplayControllerRetired(identity: process, initial: initial)
        try expect(panel.queries.last?.pid == 42 && panel.queries.last?.processStartTicks == 123456,
            "power retirement must query exact PID/start identity")
        for mutation: (inout GBCaptureRetirementProof) -> Void in [
            { $0.pid = 43 }, { $0.processStartTicks = 123457 }, { $0.absent = false },
            { $0.panels = [.init(physicalID: "1", on: false), .init(physicalID: "2", on: false)] },
            { $0.panels = [.init(physicalID: "1", on: true), .init(physicalID: "1", on: false)] }] {
            let provider = ProviderFixture(); provider.mutateProof = mutation
            var rejected = false
            do { try await provider.confirmDisplayControllerRetired(identity: process, initial: initial) } catch { rejected = true }
            try expect(rejected, "changed process, unretired controller or wrong/malformed mixed panel state cannot restore ownership")
        }
        let resourceID = "69830b65-6352-4b3a-8a21-70bcda45787e"
        let cleanup = ProviderFixture()
        try await cleanup.releaseRetiredControllerResource(identity: process, resourceID: resourceID)
        try expect(cleanup.operations == [.releaseRetiredResource] && cleanup.queries[0].ownedResourceID == resourceID,
            "resource cleanup must use its scoped typed operation, never arbitrary shell/path data")
        for mutation: (inout GBCaptureRetirementProof) -> Void in [
            { $0.resourceRemoved = false }, { $0.ownedResourceID = "other" }, { $0.pid = 43 }, { $0.absent = false }] {
            let provider = ProviderFixture(); provider.mutateProof = mutation
            var rejected = false
            do { try await provider.releaseRetiredControllerResource(identity: process, resourceID: resourceID) } catch { rejected = true }
            try expect(rejected, "resource cleanup must acknowledge exact retired identity and ownership UUID")
        }
        let legacy = ProviderFixture(); legacy.mode = .legacy
        let legacyReady = await legacy.refresh()
        try expect(legacyReady && legacy.needsRuntimeUpgrade && legacy.canUpgradeRuntimeSafely,
            "ordinary legacy readiness remains usable and exposes a quiescent upgrade")
        legacy.leases["owned-child"] = 1
        try expect(!legacy.canUpgradeRuntimeSafely, "active children must prevent runtime replacement")
        legacy.leases = [:]; legacy.pending["starting"] = .init(operation: .startScrcpy)
        try expect(!legacy.canUpgradeRuntimeSafely, "an uncommitted START must also prevent replacement")
        legacy.pending = ["read": .init(operation: .verifyRetirement)]
        try expect(legacy.canUpgradeRuntimeSafely, "read-only status owns no child lifetime")
        legacy.pending = ["cleanup": .init(operation: .releaseRetiredResource)]
        try expect(!legacy.canUpgradeRuntimeSafely, "in-flight exact resource release must finish before broker replacement")
        for mode in [ProviderFixture.Mode.unavailable, .timeout] {
            let provider = ProviderFixture(); provider.mode = mode
            let baseReady = await provider.refresh()
            try expect(baseReady && !provider.needsRuntimeUpgrade,
                "failed optional inventory must preserve the usable broker without inventing legacy support")
        }
        let counter = ProofCounter()
        let fallback = CleanupFixture(fails: true, proof: { counter.values.append($0) })
        await fallback.retirePendingRemoteServers()
        try expect(fallback.localLaunchersSettled && fallback.remoteRetirement.settled && counter.values == [18], "exact Helper absence must settle failed ADB retirement only after local launchers settle")
        let native = CleanupFixture(fails: false, proof: { counter.values.append($0) })
        await native.retirePendingRemoteServers()
        try expect(native.remoteRetirement.settled && counter.values == [18], "successful ADB retirement must preserve its original path")
        let denied = CleanupFixture(fails: true, proof: { _ in throw ShellCapabilityBridgeFailure.sessionChanged })
        await denied.retirePendingRemoteServers()
        try expect(!denied.remoteRetirement.settled, "failed current-identity proof must retain the remote fence")
        let missing = CleanupFixture(fails: true, proof: nil)
        await missing.retirePendingRemoteServers()
        try expect(!missing.remoteRetirement.settled, "an unverified capture cannot borrow Helper cleanup authority")
        print("PASS actual capture proof: exact SCID, legacy rejection, session/boot fences, optional readiness, safe runtime upgrade and ADB fallback ownership")
    }
}
