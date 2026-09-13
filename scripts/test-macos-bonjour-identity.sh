#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-bonjour-identity.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -framework CryptoKit \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/PairedPeerStub.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/BonjourCompanionIdentity.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/BonjourIdentityMatchingSpec.swift" \
    -o "$GB_TMP/BonjourIdentityMatchingSpec"

"$GB_TMP/BonjourIdentityMatchingSpec"
