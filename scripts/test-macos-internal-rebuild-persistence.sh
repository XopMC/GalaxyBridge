#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d)"
trap '/bin/rm -rf -- "$GB_TMP"' EXIT

GB_SOURCES=(
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift"
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift"
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainSecureRecordPersistence.swift"
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift"
  "$GB_ROOT/macos/GalaxyBridgeMacTests/InternalStoreRebuildProbe.swift"
)

/usr/bin/xcrun swiftc -D GALAXYBRIDGE_REBUILD_ONE "${GB_SOURCES[@]}" -o "$GB_TMP/probe-one"
/usr/bin/xcrun swiftc -D GALAXYBRIDGE_REBUILD_TWO "${GB_SOURCES[@]}" -o "$GB_TMP/probe-two"

if [[ "$(/usr/bin/shasum -a 256 "$GB_TMP/probe-one" | /usr/bin/awk '{print $1}')" == \
      "$(/usr/bin/shasum -a 256 "$GB_TMP/probe-two" | /usr/bin/awk '{print $1}')" ]]; then
  echo "Rebuild probes unexpectedly have identical binaries." >&2
  exit 1
fi

GB_FIRST="$($GB_TMP/probe-one "$GB_TMP/records" 2>"$GB_TMP/one.log")"
GB_SECOND="$($GB_TMP/probe-two "$GB_TMP/records" 2>"$GB_TMP/two.log")"
[[ "$GB_FIRST" == "$GB_SECOND" ]]
[[ "${#GB_FIRST}" == 64 ]]
[[ "$(/usr/bin/stat -f '%Lp' "$GB_TMP/records")" == "700" ]]

echo "Internal identity persisted across two different rebuilt binaries without Keychain access."
