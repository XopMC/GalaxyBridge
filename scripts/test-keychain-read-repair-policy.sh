#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-keychain-read-policy.XXXXXX")"
trap '/bin/rm -rf -- "$GB_TMP"' EXIT

xcrun swiftc -framework Security -framework LocalAuthentication \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/KeychainReadRepairPolicySpec.swift" \
  -o "$GB_TMP/keychain-read-policy-spec"
"$GB_TMP/keychain-read-policy-spec"

for GB_FILE in \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/PairedPeerStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/ADBBindingStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Storage/EncryptedContentCache.swift"; do
  if /usr/bin/grep -Fq 'let repairStatus = GalaxyKeychainPolicy.finalizeInsertion(matching:' "$GB_FILE"; then
    echo "Ordinary reads still mutate the legacy ACL before CopyMatching: $GB_FILE" >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq 'GalaxyKeychainPolicy.copyMatchingWithLegacyRepair' "$GB_FILE"; then
    echo "Keychain read does not use the bounded repair-on-failure path: $GB_FILE" >&2
    exit 1
  fi
done

echo "Keychain ordinary-read source contract passed."
