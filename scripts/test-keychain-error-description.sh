#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-keychain-error-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework Security \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainSecureRecordPersistence.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/KeychainIdentityErrorSpec.swift" \
    -o "$GB_TMP/KeychainIdentityErrorSpec"

"$GB_TMP/KeychainIdentityErrorSpec"
