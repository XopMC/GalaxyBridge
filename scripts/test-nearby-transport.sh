#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-transport.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 6 "$root/macos/GalaxyBridgeMac/Transport/NearbyTransportPrimitives.swift" \
  "$root/macos/GalaxyBridgeMacTests/NearbyTransportSpec.swift" -o "$tmp/spec"
"$tmp/spec"
swiftc -swift-version 6 "$root/macos/GalaxyBridgeMac/Transport/NearbyGroupAdmission.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyGroupOwnership.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyTransportPrimitives.swift" \
  "$root/macos/GalaxyBridgeMacTests/NearbyGroupAdmissionSpec.swift" -o "$tmp/group-spec"
"$tmp/group-spec"

# Typecheck actual coordinator + actual identity/persistence and current schema.
# Reuse cached compiler dependencies; never start a shared SwiftPM/native build.
cache="$root/.build/$(uname -m)-apple-macosx/debug"
modules=${GB_NEARBY_SWIFT_MODULES:-$cache/Modules}
plugin=${GB_NEARBY_PROTOC_PLUGIN:-$cache/protoc-gen-swift-tool}
protoc=${GB_NEARBY_PROTOC:-$cache/protoc-tool}
[ -d "$modules" ] && [ -x "$plugin" ] && [ -x "$protoc" ] || {
  printf '%s\n' 'Set GB_NEARBY_SWIFT_MODULES, GB_NEARBY_PROTOC_PLUGIN, and GB_NEARBY_PROTOC to current checkout build outputs' >&2; exit 2;
}
"$protoc" --plugin="protoc-gen-swift=$plugin" --swift_out="Visibility=Public:$tmp" \
  --proto_path="$root/protocol" "$root/protocol/galaxybridge.proto"
swiftc -swift-version 6 -emit-module -module-name GalaxyBridgeCore \
  "$root/Sources/GalaxyBridgeCore/NearbyBootstrapCrypto.swift" "$root/Sources/GalaxyBridgeCore/PairingTranscript.swift" \
  -emit-module-path "$tmp/GalaxyBridgeCore.swiftmodule"
swiftc -swift-version 6 -emit-module -module-name GalaxyBridgeProtocol -I "$modules" \
  "$tmp/galaxybridge.pb.swift" -emit-module-path "$tmp/GalaxyBridgeProtocol.swiftmodule"
swiftc -swift-version 6 -typecheck -I "$tmp" -I "$modules" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyConnectionCoordinator.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyGroupAdmission.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyGroupOwnership.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyTransportPrimitives.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyWiFiAssociation.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/NearbyTLSProbe.swift" \
  "$root/macos/GalaxyBridgeMac/Transport/CompanionLifecycleEvents.swift" \
  "$root/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift" \
  "$root/macos/GalaxyBridgeMac/Security/PairedPeerStore.swift" \
  "$root/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift" \
  "$root/macos/GalaxyBridgeMac/Security/KeychainSecureRecordPersistence.swift" \
  "$root/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift"
printf '%s\n' 'PASS actual Nearby coordinator SDK/protocol/identity source typecheck (no radio calls)'
