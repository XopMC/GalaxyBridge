import Foundation
import GalaxyBridgeCore

@MainActor enum UserDefaults { static let standard = Defaults(); final class Defaults { func set(_ value: Any, forKey: String) {} } }
struct DeviceRow { let id: String; var isReady = true; var adbSerial: String? = "synthetic-usb" }
@MainActor final class ScrcpySession {
    let serial = "synthetic-usb"
    var legacyAutomaticWrites: [Bool] = []
    func setAutomaticDisplayManagement(_ enabled: Bool) async throws { legacyAutomaticWrites.append(enabled) }
}
@MainActor final class PhysicalOwner: PhoneDisplayPowerOwner {
    var failureHandler: ((String) -> Void)?
    var panelPowerChangedHandler: ((PhonePanelPowerSnapshot) -> Void)?
    var current = try! PhonePanelPowerSnapshot(validating: [.init(id: "17", on: false), .init(id: "22", on: true)])
    var writes: [Bool] = []; var restorations: [PhonePanelPowerSnapshot] = []; var starts = 0; var stops = 0
    func start() async throws { starts += 1 }
    func snapshot() async throws -> PhonePanelPowerSnapshot { current }
    func panelPower() async throws -> PhonePanelPowerState { current.hasActivePanel ? .on : .off }
    func setPanelPower(on: Bool) async throws {
        writes.append(on); current = try .init(validating: [.init(id: "17", on: false), .init(id: "22", on: on)])
    }
    func restorePanelSnapshot(_ snapshot: PhonePanelPowerSnapshot) async throws { restorations.append(snapshot); current = snapshot }
    func setPanelPowerChanged(_ snapshot: PhonePanelPowerSnapshot) { current = snapshot; panelPowerChangedHandler?(snapshot) }
    func stop() async throws { stops += 1 }
}
@MainActor final class AppModel {
    struct Admission { var admitsWork = true }
    var phonePrivacyPreferences: [String: Bool] = [:]
    var phonePrivacyAliases: [String: String] = [:]
    var phonePrivacyLeases: [UUID: (deviceID: String, serial: String)] = [:]
    var primaryPhonePrivacyLeases: [ObjectIdentifier: UUID] = [:]
    var phonePrivacyRoutes: [String: String] = [:]
    var phonePrivacyManualPower: [String: Bool] = [:]
    var phonePrivacyUpdates: [String: Task<Void, Never>] = [:]
    var phonePrivacyUpdateTickets: [String: UUID] = [:]
    var phoneDisplayPrivacyStatuses: [String: PhoneDisplayPrivacyStatus] = [:]
    var scrcpySessions: [String: ScrcpySession] = [:]
    var preparingDirectDevices = Set<String>()
    var terminationAdmission = Admission()
    let owner = PhysicalOwner()
    lazy var phoneDisplayPrivacy = PhoneDisplayPrivacyCoordinator { [owner] _ in owner }
    func row(id: String) -> DeviceRow? { .init(id: id) }
    func enhancedCaptureRoute(for row: DeviceRow) -> (serial: String, unused: Bool)? { ("synthetic-usb", false) }
    func hasEnhancedTransport(deviceID: String) -> Bool { true }
    func activeEnhancedDeviceID(_ session: ScrcpySession) -> String? { scrcpySessions.first(where: { $0.value === session })?.key }
    // ACTUAL_PHONE_PRIVACY_METHODS
}
@main enum PhonePrivacyEntryPointSpec {
    @MainActor static func main() async throws {
        let phone = "phone", model = AppModel(), session = ScrcpySession(), lease = UUID()
        model.scrcpySessions[phone] = session; model.primaryPhonePrivacyLeases[ObjectIdentifier(session)] = lease
        let original = model.owner.current
        var readiness = PhonePrivacySessionReadiness()
        readiness.receive(.firstFrame); model.publishPrimaryReadiness(readiness.isReady, session: session)
        precondition(model.phonePrivacyLeases.isEmpty && model.owner.writes.isEmpty, "An early decoded frame acquired privacy before control was ready")
        readiness.receive(.controlReady); model.publishPrimaryReadiness(readiness.isReady, session: session)
        await model.phonePrivacyUpdates[phone]?.value
        precondition(model.phoneDisplayPrivacyEnabled(deviceID: phone) && model.owner.writes == [false] && model.owner.current.isAllOff, "Untouched default ON did not hide both physical folded panels")
        model.publishPrimaryReadiness(true, session: session)
        precondition(model.phonePrivacyLeases.count == 1, "Repeated current readiness duplicated the physical owner")
        model.setPhoneDisplayPrivacy(false, deviceID: phone)
        await model.phonePrivacyUpdates[phone]?.value
        precondition(model.owner.current == original && model.owner.restorations == [original], "OFF did not restore the exact initial OFF/ON snapshot")
        precondition(!session.legacyAutomaticWrites.contains(true), "OFF enabled legacy automatic blackout instead of leaving the phone active")
        model.setPhoneDisplayPrivacy(true, deviceID: phone); await model.phonePrivacyUpdates[phone]?.value
        let applicationLease = UUID()
        model.phoneDisplaySessionReady(deviceID: phone, serial: session.serial, leaseID: applicationLease)
        await model.phonePrivacyUpdates[phone]?.value
        model.releasePhoneDisplaySession(lease)
        await model.phoneDisplayPrivacy.waitForSettlement(deviceID: phone)
        precondition(model.owner.current.isAllOff, "Closing the primary mirror revealed a phone with a remaining app window")
        let writes = model.owner.writes
        model.owner.setPanelPowerChanged(original)
        precondition(model.phoneDisplayPrivacy.status(deviceID: phone) == .visible && model.owner.writes == writes, "Physical wake must be visible without a timer forcing OFF again")
        model.releasePhoneDisplaySession(applicationLease)
        await model.phoneDisplayPrivacy.waitForSettlement(deviceID: phone)
        precondition(model.owner.current == original, "Last app-window cleanup failed exact restoration")
        let disabled = AppModel(), disabledSession = ScrcpySession(), disabledLease = UUID()
        disabled.scrcpySessions[phone] = disabledSession; disabled.primaryPhonePrivacyLeases[ObjectIdentifier(disabledSession)] = disabledLease
        disabled.setPhoneDisplayPrivacy(false, deviceID: phone); await disabled.phonePrivacyUpdates[phone]?.value
        disabled.publishPrimaryReadiness(true, session: disabledSession); await disabled.phonePrivacyUpdates[phone]?.value
        precondition(disabled.owner.starts == 0 && disabled.owner.writes.isEmpty && !disabledSession.legacyAutomaticWrites.contains(true), "Saved OFF was blanked or woke a panel during initial mirror opening")
        print("PASS actual privacy entry points: both readiness signals, untouched default ON, exact folded restoration, OFF without legacy blackout, shared app leases and respectful physical wake")
    }
}
