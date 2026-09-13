import Foundation
import GalaxyBridgeCore
import GameController

enum GamepadBridgeEvent: Sendable {
    case connected(id: UInt16, name: String)
    case report(id: UInt16, report: ScrcpyUHIDGamepadReport)
    case disconnected(id: UInt16)
}

final class GamepadBridge: @unchecked Sendable {
    struct Snapshot: Sendable {
        let id: UInt16
        let report: ScrcpyUHIDGamepadReport
    }

    var eventHandler: (@Sendable (GamepadBridgeEvent) -> Void)?

    private struct ControllerState {
        let id: UInt16
        var report: ScrcpyUHIDGamepadReport
    }

    private let lock = NSLock()
    private var states: [ObjectIdentifier: ControllerState] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                self?.attach(controller)
            }
        )
        observers.append(
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                self?.detach(controller)
            }
        )
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        GCController.stopWirelessControllerDiscovery()
    }

    func snapshots() -> [Snapshot] {
        lock.lock()
        let snapshots = states.values.map { Snapshot(id: $0.id, report: $0.report) }
        lock.unlock()
        return snapshots.sorted { $0.id < $1.id }
    }

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        let key = ObjectIdentifier(controller)
        lock.lock()
        guard states[key] == nil,
              let id = (UInt16(3) ... UInt16(10)).first(where: { candidate in
                  !states.values.contains(where: { $0.id == candidate })
              })
        else {
            lock.unlock()
            return
        }
        let report = Self.report(from: gamepad)
        states[key] = ControllerState(id: id, report: report)
        lock.unlock()

        gamepad.valueChangedHandler = { [weak self] profile, _ in
            self?.update(key: key, id: id, gamepad: profile)
        }
        eventHandler?(.connected(id: id, name: controller.vendorName ?? "Game Controller"))
        eventHandler?(.report(id: id, report: report))
    }

    private func detach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        controller.extendedGamepad?.valueChangedHandler = nil
        lock.lock()
        let state = states.removeValue(forKey: key)
        lock.unlock()
        if let state { eventHandler?(.disconnected(id: state.id)) }
    }

    private func update(key: ObjectIdentifier, id: UInt16, gamepad: GCExtendedGamepad) {
        let report = Self.report(from: gamepad)
        lock.lock()
        guard states[key]?.id == id else {
            lock.unlock()
            return
        }
        states[key]?.report = report
        lock.unlock()
        eventHandler?(.report(id: id, report: report))
    }

    private static func report(from gamepad: GCExtendedGamepad) -> ScrcpyUHIDGamepadReport {
        var buttons: ScrcpyUHIDGamepadButtons = []
        if gamepad.buttonA.isPressed { buttons.insert(.south) }
        if gamepad.buttonB.isPressed { buttons.insert(.east) }
        if gamepad.buttonX.isPressed { buttons.insert(.west) }
        if gamepad.buttonY.isPressed { buttons.insert(.north) }
        if gamepad.leftShoulder.isPressed { buttons.insert(.leftShoulder) }
        if gamepad.rightShoulder.isPressed { buttons.insert(.rightShoulder) }
        if gamepad.buttonOptions?.isPressed == true { buttons.insert(.back) }
        if gamepad.buttonMenu.isPressed { buttons.insert(.start) }
        if gamepad.buttonHome?.isPressed == true { buttons.insert(.guide) }
        if gamepad.leftThumbstickButton?.isPressed == true { buttons.insert(.leftStick) }
        if gamepad.rightThumbstickButton?.isPressed == true { buttons.insert(.rightStick) }

        return ScrcpyUHIDGamepadReport(
            leftX: Double(gamepad.leftThumbstick.xAxis.value),
            leftY: -Double(gamepad.leftThumbstick.yAxis.value),
            rightX: Double(gamepad.rightThumbstick.xAxis.value),
            rightY: -Double(gamepad.rightThumbstick.yAxis.value),
            leftTrigger: Double(gamepad.leftTrigger.value),
            rightTrigger: Double(gamepad.rightTrigger.value),
            buttons: buttons,
            dpad: dpad(from: gamepad.dpad)
        )
    }

    private static func dpad(from pad: GCControllerDirectionPad) -> ScrcpyUHIDGamepadDPad {
        let up = pad.up.isPressed
        let down = pad.down.isPressed
        let left = pad.left.isPressed
        let right = pad.right.isPressed
        return switch (up, down, left, right) {
        case (true, false, false, true): .upRight
        case (false, true, false, true): .downRight
        case (false, true, true, false): .downLeft
        case (true, false, true, false): .upLeft
        case (true, false, false, false): .up
        case (false, true, false, false): .down
        case (false, false, true, false): .left
        case (false, false, false, true): .right
        default: .neutral
        }
    }
}
