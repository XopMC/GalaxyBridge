#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d)"
trap '/bin/rm -rf -- "$GB_TMP"' EXIT

/usr/bin/xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/InternalSecureRecordStoreSpec.swift" \
  -o "$GB_TMP/InternalSecureRecordStoreSpec"

"$GB_TMP/InternalSecureRecordStoreSpec"
