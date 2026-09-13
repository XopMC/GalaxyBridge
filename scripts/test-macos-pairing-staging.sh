#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-pairing-staging.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainSecureRecordPersistence.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/PairedPeerStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/PairedPeerStagingSpec.swift" \
  -framework LocalAuthentication \
  -framework Security \
  -o "$GB_TMP/PairedPeerStagingSpec"

"$GB_TMP/PairedPeerStagingSpec"

grep -q 'peerStore.stage' "$GB_ROOT/macos/GalaxyBridgeMac/Transport/PairingCoordinator.swift"
grep -q 'peerStore.promote' "$GB_ROOT/macos/GalaxyBridgeMac/Transport/PairingCoordinator.swift"
if grep -q 'peerStore.save' "$GB_ROOT/macos/GalaxyBridgeMac/Transport/PairingCoordinator.swift"; then
  echo "PairingCoordinator must not expose active trust before Ack" >&2
  exit 1
fi
