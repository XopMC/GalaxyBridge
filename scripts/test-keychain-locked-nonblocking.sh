#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-locked-keychain.XXXXXX")"
trap '/bin/rm -rf -- "$GB_TMP"' EXIT

xcrun swiftc -framework Security -framework LocalAuthentication \
  -suppress-warnings \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/LockedDisposableKeychainSpec.swift" \
  -o "$GB_TMP/locked-keychain-spec"

"$GB_TMP/locked-keychain-spec" "$GB_TMP/LockedProbe.keychain-db"
echo "Locked disposable Keychain nonblocking regression passed."
