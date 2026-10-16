import Foundation
import GalaxyBridgeCore

@MainActor
private final class PrivacyPowerFixture: PhoneDisplayPowerOwner {
    var panel: PhonePanelPowerState = .on
    var writes: [Bool] = []
    var starts = 0
    var stops = 0
    var beforeOff: (() async -> Void)?
    var failOff = false
    var failOn = false
    var failStop = false
    var routes: [String] = []
    var restorations: [Bool] = []
    var failureHandler: ((String) -> Void)?
    var beforeStop: (() -> Void)?
    func start() async throws { starts += 1 }
    func panelPower() async throws -> PhonePanelPowerState { panel }
    func setPanelPower(on: Bool) async throws {
        writes.append(on)
        if !on { await beforeOff?() }
        panel = on ? .on : .off
        if !on, failOff { throw NSError(domain: "failure after applied OFF", code: 1) }
        if on, failOn { throw NSError(domain: "failure restoring panel", code: 1) }
    }
    func restorePanelPower(on: Bool) async throws { restorations.append(on); try await setPanelPower(on: on) }
    func stop() async throws {
        stops += 1
        beforeStop?()
        if failStop { throw NSError(domain: "cleanup child not settled", code: 1) }
    }
    func useRoute(serial: String) async { routes.append(serial) }
}

@main
private enum PhoneDisplayPrivacySpec {
    @MainActor static func main() async throws {
        func expect(_ value: @autoclosure () -> Bool, _ reason: String) throws {
            if !value() { throw NSError(domain: reason, code: 1) }
        }
        try expect(PhonePanelPowerParser.parse("Display 1\n  connectionType=Internal\n  powerMode=OFF\nVirtual Display 2\n  name=\"scrcpy\"\n  powerMode=ON") == .off, "virtual ON cannot hide physical OFF")
        try expect(PhonePanelPowerParser.parse("Display 1 (HWC display 0)\n  powerMode=ON\nVirtual Display 2\n powerMode=OFF") == .on, "physical HWC ON")
        try expect(PhonePanelPowerParser.parse("mWakefulness=Awake\nVirtual Display 2\n  powerMode=ON") == .unknown, "global wakefulness is not panel evidence")
        try expect(PhonePanelPowerParser.parse("Display 1 (HWC display 0): inventory only\nVirtual Display 2: inventory\nDisplays (2 entries)\nDisplay 1\n connectionType=Internal\n powerMode=OFF\nVirtual Display 2\n name=\"scrcpy\"\n powerMode=ON") == .off, "HWC inventory and actual state merge by display ID")
        try expect(PhonePanelPowerParser.parse("Display 1 (HWC display 0): inventory only\nDisplay 3\n connectionType=Internal\n powerMode=ON") == .unknown, "identified physical display without state stays unknown")
        try expect(PhonePanelPowerParser.parse("Display 1\n connectionType=Internal\n powerMode=ON\nDisplay 2\n connectionType=Internal\n powerMode=OFF") == .unknown, "mixed physical panels require per-panel restoration")
        let fixture = PrivacyPowerFixture()
        let coordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in fixture })
        try expect(coordinator.status(deviceID: "phone") == .waitingForSession, "default enabled waits for a media session")
        let first = UUID(), second = UUID()
        coordinator.setEnabled(false, deviceID: "phone", serial: "usb")
        coordinator.acquireLease(deviceID: "phone", leaseID: first)
        await coordinator.waitForSettlement(deviceID: "phone")
        try expect(fixture.starts == 0, "disabled option leaves panel alone")
        coordinator.setEnabled(true, deviceID: "phone", serial: "usb")
        await coordinator.waitForSettlement(deviceID: "phone")
        try expect(fixture.writes == [false], "enabled active device hides once")
        try expect(coordinator.status(deviceID: "phone") == .hidden, "verified hidden status")
        coordinator.acquireLease(deviceID: "phone", leaseID: second)
        coordinator.releaseLease(deviceID: "phone", leaseID: first)
        await coordinator.waitForSettlement(deviceID: "phone")
        try expect(fixture.writes == [false], "remaining application lease retains privacy")
        coordinator.releaseLease(deviceID: "phone", leaseID: second)
        await coordinator.waitForSettlement(deviceID: "phone")
        try expect(fixture.writes == [false, true], "last lease restores owned panel")
        try expect(fixture.stops == 1, "last lease retires dedicated owner")

        let alreadyOff = PrivacyPowerFixture(); alreadyOff.panel = .off
        let offCoordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in alreadyOff })
        offCoordinator.setEnabled(true, deviceID: "off", serial: "usb")
        offCoordinator.acquireLease(deviceID: "off", leaseID: first)
        await offCoordinator.waitForSettlement(deviceID: "off")
        offCoordinator.setEnabled(false, deviceID: "off", serial: "usb")
        await offCoordinator.waitForSettlement(deviceID: "off")
        try expect(alreadyOff.writes.isEmpty, "preexisting OFF must not be woken")

        let initiallyOff = PrivacyPowerFixture(); initiallyOff.panel = .off
        let offThenSun = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in initiallyOff })
        offThenSun.acquireLease(deviceID: "off-sun", leaseID: first)
        offThenSun.setEnabled(true, deviceID: "off-sun", serial: "usb")
        await offThenSun.waitForSettlement(deviceID: "off-sun")
        offThenSun.setManualPower(on: true, deviceID: "off-sun", serial: "usb")
        await offThenSun.waitForSettlement(deviceID: "off-sun")
        offThenSun.releaseLease(deviceID: "off-sun", leaseID: first)
        await offThenSun.waitForSettlement(deviceID: "off-sun")
        try expect(initiallyOff.writes == [true, false], "sun on initially-OFF device restores OFF")
        try expect(initiallyOff.restorations == [false], "OFF restoration uses cleanup-safe special operation")

        let manual = PrivacyPowerFixture()
        let manualCoordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in manual })
        manualCoordinator.acquireLease(deviceID: "manual", leaseID: first)
        manualCoordinator.setEnabled(true, deviceID: "manual", serial: "usb")
        await manualCoordinator.waitForSettlement(deviceID: "manual")
        manualCoordinator.setManualPower(on: true, deviceID: "manual", serial: "usb")
        await manualCoordinator.waitForSettlement(deviceID: "manual")
        try expect(manual.writes == [false, true], "sun reveals without automatic OFF fighting it")
        try expect(manualCoordinator.status(deviceID: "manual") == .visible, "sun reports visible")
        manualCoordinator.setEnabled(true, deviceID: "manual", serial: "wifi")
        await manualCoordinator.waitForSettlement(deviceID: "manual")
        try expect(manual.routes == ["wifi"], "verified alternate route retains one physical owner")
        try expect(manual.writes == [false, true, false], "explicit setting clears manual override")
        manualCoordinator.releaseLease(deviceID: "manual", leaseID: first)
        await manualCoordinator.waitForSettlement(deviceID: "manual")
        try expect(manual.writes == [false, true, false, true], "route handoff retains original restoration snapshot")

        let restoreFailure = PrivacyPowerFixture()
        let restoring = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in restoreFailure })
        restoring.acquireLease(deviceID: "restore", leaseID: first)
        restoring.setEnabled(true, deviceID: "restore", serial: "usb")
        await restoring.waitForSettlement(deviceID: "restore")
        restoreFailure.failOn = true
        restoring.releaseLease(deviceID: "restore", leaseID: first)
        await restoring.waitForSettlement(deviceID: "restore")
        if case .failed = restoring.status(deviceID: "restore") {} else {
            throw NSError(domain: "failed restoration cannot report disabled", code: 1)
        }
        try expect(restoreFailure.stops == 0, "failed restoration retains owner for retry")
        restoreFailure.failOn = false
        restoring.setEnabled(false, deviceID: "restore", serial: "usb")
        await restoring.waitForSettlement(deviceID: "restore")
        try expect(restoring.status(deviceID: "restore") == .disabled && restoreFailure.stops == 1, "retry settles restoration")

        let unsettled = PrivacyPowerFixture()
        let childCoordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in unsettled })
        childCoordinator.acquireLease(deviceID: "child", leaseID: first)
        childCoordinator.setEnabled(true, deviceID: "child", serial: "usb")
        await childCoordinator.waitForSettlement(deviceID: "child")
        unsettled.failStop = true
        childCoordinator.setEnabled(false, deviceID: "child", serial: "usb")
        await childCoordinator.waitForSettlement(deviceID: "child")
        if case .failed = childCoordinator.status(deviceID: "child") {} else {
            throw NSError(domain: "live cleanup child cannot report disabled", code: 1)
        }
        unsettled.failStop = false
        childCoordinator.setEnabled(false, deviceID: "child", serial: "usb")
        await childCoordinator.waitForSettlement(deviceID: "child")
        try expect(childCoordinator.status(deviceID: "child") == .disabled, "child-settlement retry gates owner release")

        let crashed = PrivacyPowerFixture()
        let crashCoordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in crashed })
        crashCoordinator.acquireLease(deviceID: "crash", leaseID: first)
        crashCoordinator.setEnabled(true, deviceID: "crash", serial: "usb")
        await crashCoordinator.waitForSettlement(deviceID: "crash")
        let staleFailure = crashed.failureHandler
        crashed.failureHandler?("dedicated server died")
        try expect(crashCoordinator.status(deviceID: "crash") == .failed("dedicated server died"), "owner failure invalidates hidden immediately")
        await crashCoordinator.waitForSettlement(deviceID: "crash")
        try expect(crashed.writes == [false, true], "owner failure restores without automatic OFF retry")
        try expect(crashCoordinator.status(deviceID: "crash") == .failed("dedicated server died"), "failure remains visible after safe retirement")
        crashCoordinator.setEnabled(true, deviceID: "crash", serial: "usb")
        await crashCoordinator.waitForSettlement(deviceID: "crash")
        try expect(crashed.writes == [false, true, false], "explicit request permits privacy retry")
        staleFailure?("stale retired generation")
        try expect(crashCoordinator.status(deviceID: "crash") == .hidden, "old owner generation cannot fail replacement")
        let closingFailure = crashed.failureHandler
        crashed.beforeStop = { closingFailure?("failure during intentional stop") }
        crashCoordinator.setEnabled(false, deviceID: "crash", serial: "usb")
        closingFailure?("socket close before retirement task starts")
        await crashCoordinator.waitForSettlement(deviceID: "crash")
        try expect(crashCoordinator.status(deviceID: "crash") == .disabled, "intentional close rejects retired callbacks")
        crashCoordinator.setEnabled(true, deviceID: "crash", serial: "usb")
        await crashCoordinator.waitForSettlement(deviceID: "crash")
        let shutdownFailure = crashed.failureHandler
        crashed.beforeStop = { shutdownFailure?("default stop callback") }
        await crashCoordinator.stopAndWait()
        try expect(crashCoordinator.status(deviceID: "crash") == .disabled, "default shutdown rejects intentional socket failure")

        let failedDuringOff = PrivacyPowerFixture()
        let writeFailureCoordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in failedDuringOff })
        failedDuringOff.beforeOff = { failedDuringOff.failureHandler?("failed during OFF") }
        writeFailureCoordinator.acquireLease(deviceID: "write-failure", leaseID: first)
        writeFailureCoordinator.setEnabled(true, deviceID: "write-failure", serial: "usb")
        await writeFailureCoordinator.waitForSettlement(deviceID: "write-failure")
        try expect(writeFailureCoordinator.status(deviceID: "write-failure") == .failed("failed during OFF"), "failure during write cannot republish hidden")
        try expect(failedDuringOff.writes == [false, true], "in-flight OFF failure drains before ON recovery")

        let racing = PrivacyPowerFixture()
        let raceCoordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in racing })
        racing.beforeOff = { raceCoordinator.setEnabled(false, deviceID: "race", serial: "usb") }
        raceCoordinator.acquireLease(deviceID: "race", leaseID: first)
        raceCoordinator.setEnabled(true, deviceID: "race", serial: "usb")
        await raceCoordinator.waitForSettlement(deviceID: "race")
        try expect(racing.writes == [false, true], "disable waits for in-flight OFF then restores")

        let failing = PrivacyPowerFixture(); failing.failOff = true
        let failureCoordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in failing })
        failureCoordinator.acquireLease(deviceID: "failure", leaseID: first)
        failureCoordinator.setEnabled(true, deviceID: "failure", serial: "usb")
        await failureCoordinator.waitForSettlement(deviceID: "failure")
        try expect(failing.writes == [false, true], "failed OFF still restores possibly-applied change")
        if case .failed = failureCoordinator.status(deviceID: "failure") {} else {
            throw NSError(domain: "failed OFF must not publish hidden", code: 1)
        }

        let unknown = PrivacyPowerFixture(); unknown.panel = .unknown
        let unknownCoordinator = PhoneDisplayPrivacyCoordinator(makeOwner: { _ in unknown })
        unknownCoordinator.acquireLease(deviceID: "unknown", leaseID: first)
        unknownCoordinator.setEnabled(true, deviceID: "unknown", serial: "usb")
        await unknownCoordinator.waitForSettlement(deviceID: "unknown")
        try expect(unknown.writes.isEmpty, "unknown initial panel state must not mutate")
        if case .failed = unknownCoordinator.status(deviceID: "unknown") {} else {
            throw NSError(domain: "unknown state must expose error", code: 1)
        }
        print("PhoneDisplayPrivacySpec passed")
    }
}
