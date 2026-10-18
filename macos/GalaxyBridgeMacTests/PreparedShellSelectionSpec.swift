import Foundation
import OSLog

enum TransportKind { case usbADB, wirelessADB, companionLAN }
struct DeviceRow {
    let id: String
    var isReady = true
    var transport = TransportKind.companionLAN
    var adbSerial: String?
}
struct Peer { let deviceID: String }
final class Control {
    let peer: Peer
    var supportsShellBridge = true
    let authenticatedSessionID = "current-session"
    init(peerID: String) { peer = Peer(deviceID: peerID) }
}
final class ShellCapabilityBridgeProvider {
    var available = true
    var bootGeneration: String? = UUID().uuidString.lowercased()
}
final class ScrcpySession {
    let serial: String
    init(_ serial: String) { self.serial = serial }
}
struct ApplicationWindowSession { let nativeSession: ScrcpySession }
@MainActor final class ApplicationWindowCoordinator {
    struct Record { let session: ApplicationWindowSession }
    var records: [String: Record] = [:]
    var retiringRecords: [String: Record] = [:]
    func add(deviceID: String, package: String = "com.example.synthetic", serial: String) {
        records[deviceID + "\u{0}" + package] = Record(session: .init(nativeSession: ScrcpySession(serial)))
    }
    // ACTUAL_OWNED_SESSIONS
    // ACTUAL_OWNED_APP_QUERY
    // ACTUAL_OWNED_SHELL_APP_QUERY
}
enum CompanionConnectionState { case connected, disconnected }
@MainActor enum QuicRuntimeArtifacts { static var explicitlyEnabled = false }
struct QuicWirelessSelection { let targetToken: UInt64 }
@MainActor struct ADBBindingStore {
    struct Binding { let deviceID: String }
    enum Failure: Error { case missing }
    static var records: [String: Binding] = [:]
    func record(for serial: String) throws -> Binding {
        guard let record = Self.records[serial] else { throw Failure.missing }
        return record
    }
}
@MainActor final class AppModel {
    struct Admission { var admitsWork = true }
    var terminationAdmission = Admission()
    var shellPreferredDevices = Set<String>()
    var shellProviders: [String: ShellCapabilityBridgeProvider] = [:]
    var devices: [String: DeviceRow] = [:]
    var controls: [String: Control] = [:]
    var companionStates: [String: CompanionConnectionState] = [:]
    var scrcpySessions: [String: ScrcpySession] = [:]
    var enhancedRetirements: [UUID: Bool] = [:]
    var unsettledEnhancedRetirements: [UUID: ScrcpySession] = [:]
    var enhancedRetirementDeviceIDs: [UUID: String] = [:]
    var applicationWindowCoordinator: ApplicationWindowCoordinator?
    var preparingDirectDevices = Set<String>()
    var captureRouteTransitionDevices = Set<String>()
    var validatedWirelessSerials = Set<String>()
    // The actual policy must not depend on Nearby state or invoke preparation.
    var nearbyAutoConnectEnabled = false
    func row(id: String) -> DeviceRow? { devices[id] }
    func companionControl(for id: String) -> Control? { controls[id] }
    func companionID(for id: String) -> String? { controls[id] == nil ? nil : "route:" + id }
    func install(_ id: String) -> ShellCapabilityBridgeProvider {
        let provider = ShellCapabilityBridgeProvider()
        shellProviders[id] = provider
        devices[id] = DeviceRow(id: id)
        controls[id] = Control(peerID: String(id.dropFirst("device:".count)))
        companionStates["route:" + id] = .connected
        return provider
    }
    // ACTUAL_PREPARED_SHELL_POLICY
    // ACTUAL_AVAILABLE_SHELL_POLICY
    // ACTUAL_SHELL_OWNER_LOOKUP
    // ACTUAL_ENHANCED_CAPTURE_ROUTE
    // ACTUAL_CONTINUING_ROUTE
    // ACTUAL_QUIC_SELECTION
    func canRetryRetirement(deviceID: String, session: ScrcpySession) -> Bool {
        // ACTUAL_SHELL_RETIREMENT_GATE
    }
}
@main enum PreparedShellSelectionSpec {
    @MainActor static func main() {
        let phone = "device:" + UUID().uuidString.lowercased()
        let other = "device:" + UUID().uuidString.lowercased()
        let model = AppModel(), provider = model.install(phone)
        precondition(model.activeShellProvider(deviceID: phone) === provider,
            "A fresh authenticated prepared LAN broker must serve new captures without ADB or Nearby auto-connect")
        precondition(model.devices[phone]?.adbSerial == nil && !model.nearbyAutoConnectEnabled)
        model.devices[phone]?.isReady = false
        precondition(model.activeShellProvider(deviceID: phone) == nil)
        model.devices[phone]?.isReady = true
        model.companionStates["route:" + phone] = .disconnected
        precondition(model.activeShellProvider(deviceID: phone) == nil)
        model.companionStates["route:" + phone] = .connected
        model.controls.removeValue(forKey: phone)
        precondition(model.activeShellProvider(deviceID: phone) == nil)
        model.controls[phone] = Control(peerID: "different-phone")
        precondition(model.activeShellProvider(deviceID: phone) == nil, "An unrelated paired control cannot authorize this phone")
        model.controls[phone] = Control(peerID: String(phone.dropFirst(7)))
        model.controls[phone]?.supportsShellBridge = false
        precondition(model.activeShellProvider(deviceID: phone) == nil)
        model.controls[phone]?.supportsShellBridge = true
        provider.available = false
        precondition(model.activeShellProvider(deviceID: phone) == nil)
        provider.available = true
        let boot = provider.bootGeneration; provider.bootGeneration = nil
        precondition(model.activeShellProvider(deviceID: phone) == nil)
        provider.bootGeneration = boot
        model.terminationAdmission.admitsWork = false
        precondition(model.activeShellProvider(deviceID: phone) == nil)
        model.terminationAdmission.admitsWork = true

        model.devices[phone]?.transport = .usbADB
        model.devices[phone]?.adbSerial = "synthetic-usb-adb"
        precondition(model.activeShellProvider(deviceID: phone) == nil,
            "A fresh capture must keep a ready USB route rather than redirecting over LAN")
        model.scrcpySessions[phone] = ScrcpySession("shell:" + String(phone.dropFirst(7)))
        precondition(model.activeShellProvider(deviceID: phone) === provider,
            "Attaching USB must not migrate an active shell primary owner")
        model.scrcpySessions.removeValue(forKey: phone)
        model.devices[phone]?.transport = .companionLAN
        model.devices[phone]?.adbSerial = nil

        model.scrcpySessions[phone] = ScrcpySession("synthetic-wifi-adb:1")
        precondition(model.activeShellProvider(deviceID: phone) == nil, "Automatic selection must not migrate a raw primary capture")
        model.scrcpySessions[phone] = ScrcpySession("shell:" + String(phone.dropFirst(7)))
        precondition(model.activeShellProvider(deviceID: phone) === provider, "An existing native shell owner remains usable")
        model.scrcpySessions.removeValue(forKey: phone)
        model.scrcpySessions[other] = ScrcpySession("other-raw-adb:1")
        precondition(model.activeShellProvider(deviceID: phone) === provider, "Another phone's primary capture cannot block this phone")

        let windows = ApplicationWindowCoordinator()
        model.applicationWindowCoordinator = windows
        windows.add(deviceID: phone, serial: "raw-app-adb:1")
        precondition(windows.hasOwnedADBCaptureWindows(deviceID: phone))
        precondition(model.activeShellProvider(deviceID: phone) == nil, "Automatic selection must not migrate existing raw app windows")
        windows.retiringRecords = windows.records
        windows.records.removeAll()
        precondition(model.activeShellProvider(deviceID: phone) == nil,
            "A closed raw app with unconfirmed ownership must still fence backend replacement")
        windows.retiringRecords.removeAll()
        windows.add(deviceID: phone, serial: "shell:" + String(phone.dropFirst(7)))
        windows.add(deviceID: phone + "-unrelated", serial: "other-raw:1")
        precondition(!windows.hasOwnedADBCaptureWindows(deviceID: phone), "App ownership query must use the exact device delimiter and distinguish shell owners")
        precondition(model.activeShellProvider(deviceID: phone) === provider)

        model.devices[phone]?.transport = .usbADB
        model.devices[phone]?.adbSerial = "synthetic-usb-adb"
        precondition(model.activeShellProvider(deviceID: phone) === provider,
            "Attaching USB must preserve active shell app-window owners")
        windows.records.removeAll()
        windows.add(deviceID: other, serial: "shell:" + String(other.dropFirst(7)))
        precondition(model.activeShellProvider(deviceID: phone) == nil,
            "Another phone's shell app cannot override this phone's USB preference")
        model.devices[phone]?.transport = .companionLAN
        model.devices[phone]?.adbSerial = nil

        let pending = UUID()
        model.enhancedRetirementDeviceIDs[pending] = phone
        model.enhancedRetirements[pending] = true
        precondition(model.activeShellProvider(deviceID: phone) == nil, "A current retirement must settle before choosing a new backend")
        model.enhancedRetirements.removeValue(forKey: pending)
        model.unsettledEnhancedRetirements[pending] = ScrcpySession("old-raw:1")
        precondition(model.activeShellProvider(deviceID: phone) == nil, "Unsettled physical ownership must block automatic selection")
        let shellRetirement = ScrcpySession("shell:" + String(phone.dropFirst(7)))
        model.unsettledEnhancedRetirements[pending] = shellRetirement
        precondition(model.activeShellProvider(deviceID: phone) == nil,
            "An unsettled shell owner still blocks new captures")
        precondition(model.canRetryRetirement(deviceID: phone, session: shellRetirement),
            "New-capture fencing must not block exact shell-owner cleanup after a transient STOP failure")
        precondition(model.availableShellProvider(deviceID: phone) === provider,
            "A pending primary retirement must not revoke the current authenticated broker")
        precondition(model.enhancedCaptureRoute(for: model.devices[phone]!) == nil,
            "Availability for existing owners must not admit a new capture during retirement")
        precondition(model.enhancedContinuingRouteSerial(for: model.devices[phone]!, ownerSerial: shellRetirement.serial) == shellRetirement.serial,
            "A surviving shell app privacy lease or clipboard channel retains its authenticated route")
        precondition(model.enhancedContinuingRouteSerial(for: model.devices[phone]!, ownerSerial: "shell:unknown-phone") == nil,
            "Continuation cannot borrow another phone's broker")
        precondition(model.enhancedContinuingRouteSerial(for: model.devices[phone]!, ownerSerial: nil) == nil,
            "A missing owner cannot bypass new-capture fencing")
        provider.available = false
        precondition(!model.canRetryRetirement(deviceID: phone, session: shellRetirement))
        precondition(model.enhancedContinuingRouteSerial(for: model.devices[phone]!, ownerSerial: shellRetirement.serial) == nil)
        provider.available = true
        precondition(!model.canRetryRetirement(deviceID: phone, session: ScrcpySession("shell:unknown-phone")))
        model.enhancedRetirementDeviceIDs[pending] = other
        precondition(model.activeShellProvider(deviceID: phone) === provider, "Unrelated retirement cannot block this phone")

        model.devices[phone]?.transport = .wirelessADB
        model.devices[phone]?.adbSerial = "synthetic-wifi-adb:1"
        QuicRuntimeArtifacts.explicitlyEnabled = true
        precondition(model.activeShellProvider(deviceID: phone) == nil, "Prepared TLS must preserve an enabled Internal QUIC choice")
        model.shellPreferredDevices.insert(phone)
        precondition(model.activeShellProvider(deviceID: phone) === provider, "Explicit shell preference retains its existing precedence")
        model.shellPreferredDevices.remove(phone)
        QuicRuntimeArtifacts.explicitlyEnabled = false
        precondition(model.activeShellProvider(deviceID: phone) === provider)
#if GB_INPUT_REPLAY_QA
        let qa = PrimaryTouchReplayConfiguration.process!
        let scoped = AppModel(), target = qa.peerID
        let targetProvider = scoped.install(target)
        scoped.devices[target]?.transport = .wirelessADB
        scoped.devices[target]?.adbSerial = "synthetic-qa-adb:1"
        scoped.validatedWirelessSerials.insert("synthetic-qa-adb:1")
        ADBBindingStore.records["synthetic-qa-adb:1"] = .init(deviceID: String(target.dropFirst(7)))
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[target]!)?.shellProvider == nil)
        scoped.validatedWirelessSerials.removeAll()
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[target]!) == nil)
        scoped.validatedWirelessSerials.insert("synthetic-qa-adb:1")
        ADBBindingStore.records["synthetic-qa-adb:1"] = .init(deviceID: "another-peer")
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[target]!) == nil)
        ADBBindingStore.records["synthetic-qa-adb:1"] = .init(deviceID: String(target.dropFirst(7)))
        scoped.shellPreferredDevices.insert(target)
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[target]!) == nil,
            "An incompatible explicit shell preference must reject the QUIC comparison, not silently measure TLS")
        scoped.shellPreferredDevices.remove(target)
        let ownedSerial = "shell:" + String(target.dropFirst(7))
        scoped.scrcpySessions[target] = ScrcpySession(ownedSerial)
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[target]!) == nil,
            "A QA route change cannot replace a live shell primary")
        precondition(scoped.enhancedContinuingRouteSerial(for: scoped.devices[target]!, ownerSerial: ownedSerial) == ownedSerial)
        scoped.scrcpySessions.removeAll()
        let ownedWindows = ApplicationWindowCoordinator()
        scoped.applicationWindowCoordinator = ownedWindows
        ownedWindows.add(deviceID: target, serial: ownedSerial)
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[target]!) == nil)
        ownedWindows.records.removeAll()
        let retirement = UUID()
        scoped.enhancedRetirementDeviceIDs[retirement] = target
        scoped.unsettledEnhancedRetirements[retirement] = ScrcpySession(ownedSerial)
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[target]!) == nil)
        scoped.unsettledEnhancedRetirements.removeAll()
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[target]!)?.serial == "synthetic-qa-adb:1")
        let unrelated = "device:unrelated-qa-peer", unrelatedProvider = scoped.install(unrelated)
        scoped.devices[unrelated]?.transport = .wirelessADB
        scoped.devices[unrelated]?.adbSerial = "synthetic-other-adb:1"
        precondition(scoped.enhancedCaptureRoute(for: scoped.devices[unrelated]!)?.shellProvider === unrelatedProvider)
        precondition(scoped.availableShellProvider(deviceID: target) === targetProvider)
        print("PASS actual QA QUIC route: exact peer, shell preference conflict, live/retiring owners and continuation fences")
#endif
        print("PASS actual prepared-shell policy: current paired LAN default without ADB/Nearby, availability fences, target-only raw primary/app/retirement deferral, native shell continuity, explicit preference and QUIC preservation")
    }
}
