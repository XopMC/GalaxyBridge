import Foundation
import GalaxyBridgeCore

@MainActor enum UserDefaults { static let standard = Defaults(); final class Defaults { func set(_ value: Any, forKey: String) {} } }
struct DeviceRow { let id: String; var isReady = true; var adbSerial: String? = "synthetic-usb" }
@MainActor final class ScrcpySession {
    let serial = "synthetic-usb"
    var usesCompositeDisplayInteraction = false
    var nativeSession: ScrcpySession { self }
    var legacyAutomaticWrites: [Bool] = []
    func setAutomaticDisplayManagement(_ enabled: Bool) async throws { legacyAutomaticWrites.append(enabled) }
}
@MainActor final class RetryGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}
@MainActor final class RetiringApplications {
    var retry: ((String) async -> Bool)?
    func retryRetiringOwners(deviceID: String) async -> Bool { await retry?(deviceID) ?? true }
}
@MainActor final class CompositeOwner: PhoneDisplayInteractionBackend {
    enum Failure: Error { case synthetic }
    var failPoll = false
    var retirementFailures = 0
    var retireCalls = 0
    var pollCalls = 0
    var writes: [DisplayStateControllerAcknowledgement.PanelPolicy] = []
    var retired = false
    func beginSnapshot() async throws {}
    func apply(_ policy: DisplayStateControllerAcknowledgement.PanelPolicy) async throws { writes.append(policy) }
    func poll() async throws { pollCalls += 1; if failPoll { throw Failure.synthetic } }
    func retire() async throws {
        retireCalls += 1
        if retirementFailures > 0 { retirementFailures -= 1; throw Failure.synthetic }
        retired = true
    }
}
@MainActor final class ShellProvider {
    let displayInteraction: PhoneDisplayInteractionCoordinator
    init(_ interaction: PhoneDisplayInteractionCoordinator) { displayInteraction = interaction }
}
@MainActor final class PhysicalOwner: PhoneDisplayPowerOwner {
    var failureHandler: ((String) -> Void)?
    var panelPowerChangedHandler: ((PhonePanelPowerSnapshot) -> Void)?
    var current = try! PhonePanelPowerSnapshot(validating: [.init(id: "17", on: false), .init(id: "22", on: true)])
    var startFailures = 0
    var writes: [Bool] = []; var restorations: [PhonePanelPowerSnapshot] = []; var starts = 0; var stops = 0
    func start() async throws {
        starts += 1
        if startFailures > 0 { startFailures -= 1; throw CompositeOwner.Failure.synthetic }
    }
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
    var captureRouteHandoffTasks: [String: Task<Void, Never>] = [:]
    var phonePrivacyUpdates: [String: Task<Void, Never>] = [:]
    var phonePrivacyUpdateTickets: [String: UUID] = [:]
    var phoneDisplayPrivacyStatuses: [String: PhoneDisplayPrivacyStatus] = [:]
    var scrcpySessions: [String: ScrcpySession] = [:]
    var shellProviders: [String: ShellProvider] = [:]
    var preparingDirectDevices = Set<String>()
    var primaryCleanup: ((String) async -> Bool)?
    var applicationWindowCoordinator: RetiringApplications? = .init()
    func settlePrimaryCaptureRetirements(deviceID: String) async -> Bool { await primaryCleanup?(deviceID) ?? true }

    var terminationAdmission = Admission()
    let owner = PhysicalOwner()
    lazy var phoneDisplayPrivacy = PhoneDisplayPrivacyCoordinator { [owner] _ in owner }
    func row(id: String) -> DeviceRow? { .init(id: id) }
    func enhancedCaptureRoute(for row: DeviceRow) -> (serial: String, unused: Bool)? { ("synthetic-usb", false) }
    func enhancedContinuingRouteSerial(for row: DeviceRow, ownerSerial: String?) -> String? {
        ownerSerial ?? enhancedCaptureRoute(for: row)?.serial
    }
    func hasEnhancedTransport(deviceID: String) -> Bool { true }
    func activeEnhancedDeviceID(_ session: ScrcpySession) -> String? { scrcpySessions.first(where: { $0.value === session })?.key }
    // ACTUAL_PHONE_PRIVACY_METHODS
}
@main enum PhonePrivacyEntryPointSpec {
    @MainActor static func main() async throws {
        do {
            let phone = "retry-legacy", model = AppModel(), session = ScrcpySession()
            let idle = PhoneDisplayInteractionCoordinator(makeOwner: { CompositeOwner() }, heartbeat: nil)
            model.shellProviders[phone] = ShellProvider(idle)
            model.scrcpySessions[phone] = session
            model.primaryPhonePrivacyLeases[ObjectIdentifier(session)] = UUID()
            model.owner.startFailures = 1
            model.publishPrimaryReadiness(true, session: session)
            await model.phonePrivacyUpdates[phone]?.value
            guard case .failed = model.phoneDisplayPrivacy.status(deviceID: phone) else {
                preconditionFailure("Legacy fixture must fail before Retry")
            }
            model.retryFromVisibleControl(deviceID: phone)
            await model.phonePrivacyUpdates[phone]?.value
            precondition(model.owner.starts == 2 && model.phoneDisplayPrivacy.status(deviceID: phone) == .hidden
                         && !idle.hasOutstandingOwnership,
                         "An idle composite provider must not intercept Retry for a failed legacy owner")
            model.releasePhoneDisplaySession(model.primaryPhonePrivacyLeases[ObjectIdentifier(session)]!)
            await model.phoneDisplayPrivacy.waitForSettlement(deviceID: phone)
        }
        do {
            let phone = "retry-retirement", model = AppModel(), backend = CompositeOwner()
            let interaction = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            model.shellProviders[phone] = ShellProvider(interaction)
            model.configurePhoneDisplayInteraction(interaction, deviceID: phone)
            let lease = UUID(); try interaction.reserve(lease); try await interaction.prepare(lease)
            interaction.ready(lease); await interaction.waitForSettlement()
            backend.retirementFailures = 1
            do { try await interaction.release(lease); preconditionFailure("Synthetic cleanup must fail first") } catch {}
            precondition(interaction.status == .failed && backend.retireCalls == 1)
            model.retryFromVisibleControl(deviceID: phone)
            await model.phonePrivacyUpdates[phone]?.value
            await interaction.waitForSettlement()
            precondition(backend.retireCalls == 2 && backend.retired && interaction.status == .idle,
                         "Visible Retry must retry failed retirement even when the privacy preference is unchanged")
            precondition(model.phoneDisplayPrivacyEnabled(deviceID: phone) && model.owner.starts == 0,
                         "Retry must preserve preference and never open a competing legacy owner")
        }
        do {
            let phone = "retry-producers", model = AppModel(), backend = CompositeOwner()
            let interaction = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            model.shellProviders[phone] = ShellProvider(interaction)
            model.configurePhoneDisplayInteraction(interaction, deviceID: phone)
            let primary = UUID(), application = UUID()
            try interaction.reserve(primary); try await interaction.prepare(primary); interaction.ready(primary)
            try interaction.reserve(application); try await interaction.prepare(application); interaction.ready(application)
            await interaction.waitForSettlement(); backend.failPoll = true
            await interaction.poll(); precondition(interaction.status == .failed)
            let gate = RetryGate()
            model.primaryCleanup = { target in
                guard target == phone else { return true }
                await gate.wait()
                try? await interaction.release(primary)
                return false
            }
            model.applicationWindowCoordinator?.retry = { target in
                guard target == phone else { return true }
                precondition(gate.entered && backend.retireCalls == 0,
                             "App retirement must follow primary retry and retain the shared panel owner")
                try? await interaction.release(application)
                return true
            }
            model.retryFromVisibleControl(deviceID: phone)
            for _ in 0..<1000 where !gate.entered { await Task.yield() }
            precondition(gate.entered && backend.retireCalls == 0,
                         "Retry must not retire panel ownership before producer cleanup")
            let other = "parallel", otherBackend = CompositeOwner()
            let otherInteraction = PhoneDisplayInteractionCoordinator(makeOwner: { otherBackend }, heartbeat: nil)
            model.shellProviders[other] = ShellProvider(otherInteraction)
            let otherLease = UUID(); try otherInteraction.reserve(otherLease); try await otherInteraction.prepare(otherLease)
            otherBackend.retirementFailures = 1; try? await otherInteraction.release(otherLease)
            model.retryFromVisibleControl(deviceID: other); await model.phonePrivacyUpdates[other]?.value
            precondition(otherBackend.retired && backend.retireCalls == 0,
                         "One blocked phone must not prevent another phone's retry")
            gate.release(); await model.phonePrivacyUpdates[phone]?.value
            precondition(backend.retired && interaction.status == .idle && model.owner.starts == 0)
        }
        do {
            let phone = "retry-unsettled", model = AppModel(), backend = CompositeOwner()
            let interaction = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            model.shellProviders[phone] = ShellProvider(interaction)
            let lease = UUID(); try interaction.reserve(lease); try await interaction.prepare(lease)
            backend.failPoll = true; await interaction.poll()
            model.primaryCleanup = { _ in false }
            model.applicationWindowCoordinator?.retry = { _ in false }
            model.retryFromVisibleControl(deviceID: phone)
            await model.phonePrivacyUpdates[phone]?.value
            precondition(backend.retireCalls == 0 && interaction.status == .failed && interaction.hasOutstandingOwnership,
                         "Retry must retain physical ownership while an unsettled producer still has demand")
            try await interaction.release(lease)
        }
        do {
            let phone = "retry-coalesced", model = AppModel(), backend = CompositeOwner()
            let interaction = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            model.shellProviders[phone] = ShellProvider(interaction)
            let lease = UUID(); try interaction.reserve(lease); try await interaction.prepare(lease)
            backend.retirementFailures = 1; try? await interaction.release(lease)
            model.retryFromVisibleControl(deviceID: phone); model.retryFromVisibleControl(deviceID: phone)
            await model.phonePrivacyUpdates[phone]?.value
            precondition(backend.retireCalls == 2 && interaction.status == .idle,
                         "Repeated clicks must coalesce rather than duplicate panel ownership")
        }
        do {
            let phone = "retry-replaced", model = AppModel(), backend = CompositeOwner()
            let interaction = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            model.shellProviders[phone] = ShellProvider(interaction)
            let lease = UUID(); try interaction.reserve(lease); try await interaction.prepare(lease)
            backend.retirementFailures = 1; try? await interaction.release(lease)
            let gate = RetryGate()
            model.primaryCleanup = { _ in await gate.wait(); return true }
            model.retryFromVisibleControl(deviceID: phone)
            for _ in 0..<1000 where !gate.entered { await Task.yield() }
            precondition(gate.entered)
            let replacementBackend = CompositeOwner()
            let replacement = PhoneDisplayInteractionCoordinator(makeOwner: { replacementBackend }, heartbeat: nil)
            model.shellProviders[phone] = ShellProvider(replacement)
            gate.release(); await model.phonePrivacyUpdates[phone]?.value
            precondition(backend.retireCalls == 1 && replacementBackend.retireCalls == 0 && replacementBackend.pollCalls == 0,
                         "Suspended retry must not operate through a replacement provider")
            try await interaction.release(lease)
        }

        do {
            let phone = "modern", model = AppModel(), session = ScrcpySession()
            session.usesCompositeDisplayInteraction = true
            model.scrcpySessions[phone] = session
            model.primaryPhonePrivacyLeases[ObjectIdentifier(session)] = UUID()
            model.publishPrimaryReadiness(true, session: session)
            model.publishApplicationReadiness(true, session: session, deviceID: phone, lease: UUID())
            await model.phonePrivacyUpdates[phone]?.value
            precondition(model.phonePrivacyLeases.isEmpty && model.owner.starts == 0,
                         "Modern primary/app readiness must not create a second legacy panel owner")
        }
        do {
            let phone = "modern-settings", model = AppModel(), backend = CompositeOwner()
            let interaction = PhoneDisplayInteractionCoordinator(makeOwner: { backend }, heartbeat: nil)
            model.phonePrivacyPreferences[phone] = false
            model.shellProviders[phone] = ShellProvider(interaction)
            model.configurePhoneDisplayInteraction(interaction, deviceID: phone)
            await interaction.waitForSettlement()
            precondition(model.phoneDisplayPrivacyStatuses[phone] == .disabled)
            let lease = UUID()
            try interaction.reserve(lease); try await interaction.prepare(lease)
            interaction.ready(lease); await interaction.waitForSettlement()
            precondition(backend.writes == [.preserve, .show] && model.phoneDisplayPrivacyStatuses[phone] == .visible,
                         "Saved OFF must apply before the first producer becomes ready")
            model.setPhoneDisplayPrivacy(true, deviceID: phone)
            await interaction.waitForSettlement()
            precondition(backend.writes.last == .hide && model.phoneDisplayPrivacyStatuses[phone] == .hidden)
            model.setDisplayPower(deviceID: phone, on: true)
            await interaction.waitForSettlement()
            precondition(backend.writes.last == .show && model.phoneDisplayPrivacyStatuses[phone] == .visible)
            model.setDisplayPower(deviceID: phone, on: false)
            await interaction.waitForSettlement()
            precondition(backend.writes.last == .hide && interaction.hasOutstandingOwnership)
            model.setPhoneDisplayPrivacy(false, deviceID: phone)
            await interaction.waitForSettlement()
            precondition(backend.writes.last == .show && interaction.hasOutstandingOwnership && !backend.retired,
                         "Privacy OFF cannot retire the shared logical interaction owner")
            precondition(model.owner.starts == 0 && model.owner.writes.isEmpty && model.phonePrivacyLeases.isEmpty,
                         "Settings and manual power must never open a competing legacy owner")
            interaction.cancelAdmission(lease); try await interaction.release(lease)
            precondition(backend.retired && model.phoneDisplayPrivacyStatuses[phone] == .disabled)
            model.setPhoneDisplayPrivacy(true, deviceID: phone)
            await model.phonePrivacyUpdates[phone]?.value
            let manualLease = UUID()
            try interaction.reserve(manualLease); try await interaction.prepare(manualLease)
            interaction.ready(manualLease); await interaction.waitForSettlement()
            model.setDisplayPower(deviceID: phone, on: true); await interaction.waitForSettlement()
            precondition(backend.writes.last == .show && model.phonePrivacyManualPower[phone] == true)
            interaction.cancelAdmission(manualLease); try await interaction.release(manualLease)
            precondition(model.phonePrivacyManualPower[phone] == nil,
                         "Last confirmed composite cleanup must clear the root manual override")
            let reopened = UUID()
            try interaction.reserve(reopened); try await interaction.prepare(reopened)
            interaction.ready(reopened); await interaction.waitForSettlement()
            precondition(backend.writes.last == .hide,
                         "Reopening after manual SHOW must honor default privacy ON")
            interaction.cancelAdmission(reopened); try await interaction.release(reopened)
            let replacement = PhoneDisplayInteractionCoordinator(makeOwner: { CompositeOwner() }, heartbeat: nil)
            model.shellProviders[phone] = ShellProvider(replacement)
            model.phoneDisplayPrivacyStatuses[phone] = .hidden
            interaction.statusHandler?(.failed)
            precondition(model.phoneDisplayPrivacyStatuses[phone] == .hidden,
                         "A retired provider cannot overwrite replacement-device UI state")
        }
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
        print("PASS actual privacy entry points: visible cleanup retry, producer settlement fence, independent phones, coalescing, provider replacement, readiness, default ON, folded restoration and respectful physical wake")
    }
}
