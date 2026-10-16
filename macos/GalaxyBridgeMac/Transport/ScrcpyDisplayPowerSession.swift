#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeEnhancedCore
import OSLog

/// Dedicated capture-free control owner. No clipboard polling, IME changes,
/// encoders, UHID, brightness changes, wake keys, or keyguard operations.
@MainActor
final class ScrcpyDisplayPowerSession: PhoneDisplayPowerOwner {
    private static let logger = Logger(subsystem: "com.xopmc.GalaxyBridge", category: "phone-display-privacy")
    var failureHandler: ((String) -> Void)?
    private var serial: String
    private let adb: ADBClient
    private var socket: ScrcpyControlSocket?
    private var process: Process?
    private var scid: UInt32?
    private var port: UInt16?
    private var forwardOwnerSerial: String?
    private var forwardSocketName: String?
    private var ready = false
    private var failure: String?
    private var generation = UUID()
    private var ownership: PhonePrivacyServerOwnership?
    private var cleanupIdentity: PhonePrivacyCleanupIdentity?
    private var cleanupEnabled = true

    init(serial: String, adb: ADBClient) { self.serial = serial; self.adb = adb }

    func useRoute(serial: String) async throws {
        // Repeating a route after failed retirement must retry settlement.
        guard PhonePrivacyServerOwnership.requiresRouteSettlement(current: self.serial, requested: serial, controlReady: ready) else { return }
        // The new route is already verified to belong to this logical phone.
        // Retire and inspect old process identities through the reachable route.
        self.serial = serial
        try await stop()
    }

    func start() async throws {
        if ready, failure == nil { return }
        try await stop()
        failure = nil
        let request = UUID()
        generation = request
        var operation = "locate-server"
        do {
            let server = try ScrcpyServerLocator.locate()
            let ownership = PhonePrivacyServerOwnership()
            self.ownership = ownership
            operation = "stage-owned-jar"
            try await Task.detached(priority: .utility) { [adb, serial] in
                try adb.push(serial: serial, localURL: server, remotePath: ownership.remoteJarPath)
            }.value
            let identifier = UInt32.random(in: 1 ... 0x7FFF_FFFF)
            let configuration = ScrcpyLaunchConfiguration(
                scid: identifier, videoEnabled: false, audioEnabled: false,
                sendDeviceMeta: false, keepActive: false, hideDeviceIME: false,
                uhidKeyboardEnabled: false, cleanup: cleanupEnabled
            )
            scid = identifier
            operation = "forward-control"
            port = try await Task.detached(priority: .utility) { [adb, serial] in
                try adb.forwardAutomatically(serial: serial, socketName: configuration.socketName)
            }.value
            forwardOwnerSerial = serial
            forwardSocketName = configuration.socketName
            let arguments = try ownership.serverArguments(replacingSharedClasspath: configuration.serverArguments, cleanupEnabled: cleanupEnabled)
            operation = "launch-server"
            process = try adb.launch(serial: serial, arguments: arguments)
            operation = "wait-server-socket"
            try await Task.detached(priority: .utility) { [adb, serial] in
                try adb.waitForAbstractSocket(serial: serial, socketName: configuration.socketName)
            }.value
            guard let port else { throw PowerError.notReady }
            let socket = ScrcpyControlSocket(port: port, initialPreambleLength: 1,
                readyHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == request else { return }
                        self.ready = true
                    }
                },
                messageHandler: { _ in },
                failureHandler: { [weak self] error in
                    let message = String(describing: error)
                    Task { @MainActor in
                        guard let self, self.generation == request else { return }
                        self.failure = message
                        Self.logger.error("Display privacy owner failed: control-disconnected")
                        self.failureHandler?(message)
                    }
                })
            self.socket = socket
            socket.start()
            let deadline = ContinuousClock.now + .seconds(8)
            operation = "wait-control-ready"
            while !ready {
                if let failure { throw PowerError.control(failure) }
                guard ContinuousClock.now < deadline else { throw PowerError.notReady }
                try await Task.sleep(for: .milliseconds(40))
            }
            // Do not issue OFF until the independently surviving cleanup child
            // can be identified exactly and later awaited without blind kills.
            if cleanupEnabled {
                operation = "identify-owned-cleanup-child"
                cleanupIdentity = try await identifyCleanupChild(scid: identifier, ownership: ownership)
            }
        } catch {
            let preparationError = error
            Self.logFailure(preparationError, operation: operation)
            try await stop()
            throw preparationError
        }
    }

    func panelPower() async throws -> PhonePanelPowerState {
        let output = try await Task.detached(priority: .utility) { [adb, serial] in
            try adb.run(arguments: ["-s", serial, "shell", "dumpsys", "SurfaceFlinger"])
        }.value
        return PhonePanelPowerParser.parse(output)
    }

    func setPanelPower(on: Bool) async throws {
        if !cleanupEnabled {
            try await stop()
            cleanupEnabled = true
        }
        if !ready || failure != nil { try await start() }
        try await sendPanelPower(on: on)
    }

    func restorePanelPower(on: Bool) async throws {
        if on { try await setPanelPower(on: true); return }
        // Stock crash cleanup can only restore ON. Let that child settle
        // first, then restore an originally-OFF panel using an owner with no
        // crash cleanup, so a delayed child cannot undo the final OFF.
        try await stop()
        cleanupEnabled = false
        try await start()
        try await sendPanelPower(on: false)
    }

    private func sendPanelPower(on: Bool) async throws {
        guard ready, let socket else { throw PowerError.notReady }
        socket.send(ScrcpyControlMessage.setDisplayPower(on: on))
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            if let failure { throw PowerError.control(failure) }
            if try await panelPower() == (on ? .on : .off) { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        Self.logFailure(PowerError.panelNotConfirmed, operation: "verify-panel-power")
        throw PowerError.panelNotConfirmed
    }

    func stop() async throws {
        do { try await retireOwnedResources() }
        catch { Self.logFailure(error, operation: "retire-owned-resources"); throw error }
    }

    private func retireOwnedResources() async throws {
        generation = UUID()
        ready = false
        socket?.cancel(); socket = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        if let scid {
            try await Task.detached(priority: .utility) { [adb, serial] in
                try adb.retireScrcpyServer(serial: serial, scid: scid)
            }.value
        }
        if let cleanupIdentity, let ownership {
            let deadline = ContinuousClock.now + .seconds(5)
            var settled = false
            repeat {
                let probe = try await probeCleanup(cleanupIdentity.pid, ownership: ownership)
                if (try? probe.settled(expected: cleanupIdentity)) == true { settled = true; break }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            guard settled else { throw PowerError.cleanupNotSettled }
        }
        if let port {
            try await retireForward(port)
        }
        if let ownership {
            // The child normally unlinks this at launch. A failed early launch
            // can leave it behind; remove only the UUID-owned path.
            _ = try await shell("rm -f '\(ownership.remoteJarPath)'")
        }
        scid = nil; port = nil; cleanupIdentity = nil; ownership = nil
        forwardOwnerSerial = nil; forwardSocketName = nil
    }

    private func retireForward(_ port: UInt16) async throws {
        guard let ownerSerial = forwardOwnerSerial, let socketName = forwardSocketName else {
            throw PowerError.forwardOwnershipUnavailable
        }
        let before = try await forwardState(port: port, ownerSerial: ownerSerial, socketName: socketName)
        if before == .absent { return }
        guard before == .owned else { throw PowerError.forwardOwnershipUnavailable }
        do {
            try await Task.detached(priority: .utility) { [adb] in
                try adb.removeForward(serial: ownerSerial, port: port)
            }.value
        } catch {
            // USB disconnect may already have removed the forward. Ignore a
            // removal error only when the server's list proves it absent.
            if try await forwardState(port: port, ownerSerial: ownerSerial, socketName: socketName) == .absent { return }
            throw PowerError.forwardNotRetired
        }
        guard try await forwardState(port: port, ownerSerial: ownerSerial, socketName: socketName) == .absent else {
            throw PowerError.forwardNotRetired
        }
    }

    private func forwardState(port: UInt16, ownerSerial: String, socketName: String) async throws -> PhonePrivacyServerOwnership.ForwardState {
        let listing = try await Task.detached(priority: .utility) { [adb] in
            try adb.run(arguments: ["forward", "--list"])
        }.value
        return PhonePrivacyServerOwnership.forwardState(listing, serial: ownerSerial, port: port, socketName: socketName)
    }

    private func identifyCleanupChild(scid: UInt32, ownership: PhonePrivacyServerOwnership) async throws -> PhonePrivacyCleanupIdentity {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            let processes = try await shell("ps -A -o PID,PPID,ARGS")
            let parents = ADBScrcpyServerProcessParser.processIDs(processes, scid: scid)
            if !parents.isEmpty {
                let children = PhonePrivacyServerOwnership.cleanupChildren(processes, parentPIDs: parents)
                var ownedChildren: [PhonePrivacyCleanupIdentity] = []
                for child in children {
                    if case let .process(identity, owned, zombie) = try await probeCleanup(child, ownership: ownership),
                       owned, !zombie { ownedChildren.append(identity) }
                }
                if ownedChildren.count == 1 { return ownedChildren[0] }
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw PowerError.cleanupIdentityUnavailable
    }

    private func probeCleanup(_ pid: Int32, ownership: PhonePrivacyServerOwnership) async throws -> PhonePrivacyCleanupProbe {
        let script = #"""
        if [ ! -d /proc/\#(pid) ]; then printf 'GONE\n'; exit 0; fi
        if tr '\000' '\n' </proc/\#(pid)/environ 2>/dev/null | grep -F -x 'CLASSPATH=\#(ownership.remoteJarPath)' >/dev/null; then printf 'OWNED\n'; else printf 'UNOWNED\n'; fi
        tr '\000' ' ' </proc/\#(pid)/cmdline 2>/dev/null
        printf '\n'
        cat /proc/\#(pid)/stat 2>/dev/null
        exit 0
        """#
        return PhonePrivacyCleanupProbe.parse(try await shell(script))
    }

    private func shell(_ script: String) async throws -> String {
        let remote = ["sh", "-c", script].map {
            "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }.joined(separator: " ")
        return try await Task.detached(priority: .utility) { [adb, serial] in
            try adb.run(arguments: ["-s", serial, "shell", remote], timeout: 6)
        }.value
    }

    private enum PowerError: Error {
        case notReady, panelNotConfirmed, cleanupNotSettled, cleanupIdentityUnavailable
        case forwardOwnershipUnavailable, forwardNotRetired
        case control(String)
    }

    private static func logFailure(_ error: Error, operation: String) {
        let code: String
        switch error {
        case PowerError.cleanupIdentityUnavailable: code = "cleanup-identity-unavailable"
        case PowerError.cleanupNotSettled: code = "cleanup-not-settled"
        case PowerError.panelNotConfirmed: code = "panel-power-unconfirmed"
        case PowerError.notReady: code = "control-not-ready"
        case PowerError.forwardOwnershipUnavailable: code = "forward-ownership-unavailable"
        case PowerError.forwardNotRetired: code = "forward-not-retired"
        case PowerError.control(_): code = "control-disconnected"
        default: code = "adb-or-resource-failure"
        }
        // Do not log serials, remote paths, process output, or raw error text.
        logger.error("Display privacy failure operation=\(operation, privacy: .public) code=\(code, privacy: .public)")
    }
}
#endif
