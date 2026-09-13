#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d)"
trap '/bin/rm -rf -- "$GB_TMP"' EXIT

/usr/bin/xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainSecureRecordPersistence.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/PairedPeerStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/ADBBindingStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/InternalStoreWiringSpec.swift" \
  -o "$GB_TMP/InternalStoreWiringSpec"

"$GB_TMP/InternalStoreWiringSpec"
