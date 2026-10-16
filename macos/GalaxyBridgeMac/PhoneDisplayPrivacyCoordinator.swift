#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeCore

@MainActor
protocol PhoneDisplayPowerOwner: AnyObject {
    var failureHandler: ((String) -> Void)? { get set }
    func start() async throws
    func panelPower() async throws -> PhonePanelPowerState
    /// Returns only after physical panel state has been verified.
    func setPanelPower(on: Bool) async throws
    func restorePanelPower(on: Bool) async throws
    func stop() async throws
    /// Called only for another verified ADB route of the same logical phone.
    func useRoute(serial: String) async throws
}

extension PhoneDisplayPowerOwner {
    func useRoute(serial: String) async throws {}
    func restorePanelPower(on: Bool) async throws { try await setPanelPower(on: on) }
}

enum PhoneDisplayPrivacyStatus: Equatable {
    case disabled, waitingForSession, preparing, hidden, visible, restoring
    case failed(String)
}

/// One physical panel owner for all primary/application windows on a device.
/// The feature starts enabled. It never changes brightness or keyguard.
/// Callers must suspend any legacy display management before enabling it.
@MainActor
final class PhoneDisplayPrivacyCoordinator {
    private final class Device {
        var enabled = true
        var serial: String?
        var leases = Set<UUID>()
        var status: PhoneDisplayPrivacyStatus = .waitingForSession
        var owner: (any PhoneDisplayPowerOwner)?
        var ownerSerial: String?
        var changedPanel = false
        var initialPanel: PhonePanelPowerState?
        var appliedPower: Bool?
        var manualPower: Bool?
        var task: Task<Void, Never>?
        var ownerGeneration = UUID()
        var ownerFailure: String?
        var ownerNeedsRetirement = false
    }
    private var devices: [String: Device] = [:]
    private let makeOwner: (String) throws -> any PhoneDisplayPowerOwner
    var statusHandler: ((String, PhoneDisplayPrivacyStatus) -> Void)?

    init(makeOwner: @escaping (String) throws -> any PhoneDisplayPowerOwner) {
        self.makeOwner = makeOwner
    }

    func status(deviceID: String) -> PhoneDisplayPrivacyStatus {
        devices[deviceID]?.status ?? .waitingForSession
    }

    func setEnabled(_ enabled: Bool, deviceID: String, serial: String) {
        let device = entry(deviceID)
        device.enabled = enabled
        device.manualPower = nil
        device.serial = serial
        device.ownerFailure = nil
        if !enabled, let owner = device.owner {
            detachFailureHandler(owner, device)
            device.ownerNeedsRetirement = true
        }
        enqueue(deviceID, device)
    }

    func setManualPower(on: Bool, deviceID: String, serial: String) {
        let device = entry(deviceID)
        device.serial = serial
        device.manualPower = on
        device.ownerFailure = nil
        enqueue(deviceID, device)
    }

    func acquireLease(deviceID: String, leaseID: UUID) {
        let device = entry(deviceID)
        guard device.leases.insert(leaseID).inserted else { return }
        device.ownerFailure = nil
        enqueue(deviceID, device)
    }

    func releaseLease(deviceID: String, leaseID: UUID) {
        guard let device = devices[deviceID], device.leases.remove(leaseID) != nil else { return }
        if device.leases.isEmpty {
            device.manualPower = nil
            if let owner = device.owner {
                detachFailureHandler(owner, device)
                device.ownerNeedsRetirement = true
            }
        }
        enqueue(deviceID, device)
    }

    func waitForSettlement(deviceID: String) async {
        // Reentrant requests can append work while the previous task awaits I/O.
        // Await until the latest tail has also completed.
        while let device = devices[deviceID], let task = device.task {
            await task.value
            if device.task == nil { return }
        }
    }

    func stopAndWait() async {
        for (id, device) in devices {
            device.enabled = false
            device.manualPower = nil
            device.leases.removeAll()
            if let owner = device.owner {
                detachFailureHandler(owner, device)
                device.ownerNeedsRetirement = true
            }
            enqueue(id, device)
        }
        for id in Array(devices.keys) { await waitForSettlement(deviceID: id) }
    }

    private func entry(_ id: String) -> Device {
        if let device = devices[id] { return device }
        let device = Device(); devices[id] = device; return device
    }

    private func publish(_ status: PhoneDisplayPrivacyStatus, _ id: String, _ device: Device) {
        guard device.status != status else { return }
        device.status = status
        statusHandler?(id, status)
    }

    private func enqueue(_ id: String, _ device: Device) {
        let previous = device.task
        // Never cancel physical I/O. Each successor waits for the preceding
        // command and restoration; no stale OFF can race a later ON.
        let ticket = UUID()
        tickets[id] = ticket
        device.task = Task { [self] in
            await previous?.value
            guard tickets[id] == ticket else { return }
            await reconcile(id, device)
            if tickets[id] == ticket { device.task = nil; tickets.removeValue(forKey: id) }
        }
    }
    private var tickets: [String: UUID] = [:]

    private func reconcile(_ id: String, _ device: Device) async {
        let wanted = device.ownerFailure == nil && (device.enabled || device.manualPower != nil) && !device.leases.isEmpty && device.serial != nil
        if let owner = device.owner, let serial = device.serial, device.ownerSerial != serial {
            do { try await owner.useRoute(serial: serial) }
            catch { publish(.failed(String(describing: error)), id, device); return }
            device.ownerSerial = serial
        }
        if let owner = device.owner, !wanted || device.ownerNeedsRetirement {
            detachFailureHandler(owner, device)
            device.ownerNeedsRetirement = true
            if device.changedPanel {
                if device.ownerFailure == nil { publish(.restoring, id, device) }
                do { try await owner.restorePanelPower(on: device.initialPanel == .on); device.changedPanel = false }
                catch { publish(.failed(String(describing: error)), id, device); return }
            }
            do { try await owner.stop() }
            catch { publish(.failed(String(describing: error)), id, device); return }
            device.owner = nil; device.ownerSerial = nil; device.initialPanel = nil; device.appliedPower = nil
            device.ownerNeedsRetirement = false
        }
        if let failure = device.ownerFailure { publish(.failed(failure), id, device); return }
        guard device.enabled || device.manualPower != nil else { publish(.disabled, id, device); return }
        guard !device.leases.isEmpty, let serial = device.serial else {
            publish(.waitingForSession, id, device); return
        }
        let isNew = device.owner == nil
        let owner: any PhoneDisplayPowerOwner
        do { owner = try device.owner ?? makeOwner(serial) }
        catch { publish(.failed(String(describing: error)), id, device); return }
        if isNew { publish(.preparing, id, device) }
        device.owner = owner; device.ownerSerial = serial
        if isNew { installFailureHandler(owner, id, device) }
        do {
            if isNew {
                let initial = try await owner.panelPower()
                guard initial != .unknown else { throw PrivacyError.unknownPanelState }
                device.initialPanel = initial
                device.appliedPower = initial == .on
                try await owner.start()
            }
            guard device.ownerFailure == nil, device.enabled || device.manualPower != nil, !device.leases.isEmpty, device.serial == serial else { return }
            let desiredOn = device.manualPower ?? false
            if !isNew {
                let observed = try await owner.panelPower()
                guard observed != .unknown else { throw PrivacyError.unknownPanelState }
                device.appliedPower = observed == .on
            }
            if device.appliedPower != desiredOn {
                // Record ownership BEFORE writing: an error may arrive after
                // Android applied OFF and therefore still requires restoration.
                device.changedPanel = true
                try await owner.setPanelPower(on: desiredOn)
                device.appliedPower = desiredOn
                device.changedPanel = desiredOn != (device.initialPanel == .on)
            }
            guard device.ownerFailure == nil else { return }
            publish(desiredOn ? .visible : .hidden, id, device)
        } catch {
            detachFailureHandler(owner, device)
            device.ownerNeedsRetirement = true
            if device.changedPanel {
                do { try await owner.restorePanelPower(on: device.initialPanel == .on); device.changedPanel = false }
                catch { publish(.failed(String(describing: error)), id, device); return }
            }
            do { try await owner.stop() }
            catch { publish(.failed(String(describing: error)), id, device); return }
            device.owner = nil; device.ownerSerial = nil; device.initialPanel = nil; device.appliedPower = nil
            device.ownerNeedsRetirement = false
            publish(.failed(device.ownerFailure ?? String(describing: error)), id, device)
        }
    }

    private func installFailureHandler(_ owner: any PhoneDisplayPowerOwner, _ id: String, _ device: Device) {
        let generation = UUID()
        device.ownerGeneration = generation
        owner.failureHandler = { [weak self, weak device] message in
            guard let self, let device, self.devices[id] === device,
                  device.ownerGeneration == generation, device.owner != nil else { return }
            device.ownerFailure = message
            device.ownerNeedsRetirement = true
            self.publish(.failed(message), id, device)
            self.enqueue(id, device)
        }
    }

    private func detachFailureHandler(_ owner: any PhoneDisplayPowerOwner, _ device: Device) {
        device.ownerGeneration = UUID()
        owner.failureHandler = nil
    }

    private enum PrivacyError: Error { case unknownPanelState }
}
#endif
