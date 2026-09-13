#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-keychain-policy-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework Security \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/KeychainBackendPolicySpec.swift" \
    -o "$GB_TMP/KeychainBackendPolicySpec"

"$GB_TMP/KeychainBackendPolicySpec"
