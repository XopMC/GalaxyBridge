#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-panel-owner.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
cat > "$tmp/Boundaries.swift" <<'SWIFT'
import Foundation
import GalaxyBridgeCore
struct ADBClient: Sendable {
    func push(serial: String, localURL: URL, remotePath: String) throws {}
    func run(arguments: [String], timeout: TimeInterval) throws -> String { "" }
    func launch(serial: String, arguments: [String], inputPipe: Pipe?, outputPipe: Pipe?) throws -> Process { Process() }
}
enum ScrcpyServerLocator { static func locate() throws -> URL { URL(fileURLWithPath: "/synthetic-pinned-producer.jar") } }
@MainActor final class ShellCapabilityBridgeLease {}
@MainActor final class ShellCapabilityBridgeProvider {
    func beginPanelOwnership() async throws -> ShellCapabilityBridgeLease { .init() }
    func panelPower() async throws -> PhonePanelPowerState { .off }
    func setPanelPower(on: Bool, lease: ShellCapabilityBridgeLease?) async throws -> ShellCapabilityBridgeLease { .init() }
    func retire(_ lease: ShellCapabilityBridgeLease) async throws {}
}
SWIFT
swiftc -swift-version 6 -emit-module -module-name GalaxyBridgeCore "$root/Sources/GalaxyBridgeCore/PhoneDisplayPrivacy.swift" -emit-module-path "$tmp/GalaxyBridgeCore.swiftmodule"
swiftc -swift-version 6 -typecheck -I "$tmp" "$tmp/Boundaries.swift" \
  "$root/macos/GalaxyBridgeMac/PhoneDisplayPrivacyCoordinator.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/PhonePrivacyServerOwnership.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayPowerControllerProtocol.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/DisplayPowerControllerProcess.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/ADBCommandRunner.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/ScrcpyDisplayPowerSession.swift"
printf '%s\n' 'PASS actual snapshot owner/protocol/serial pipe I/O source typecheck with inert ADB and shell boundaries'
