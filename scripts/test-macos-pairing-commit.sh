#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-pairing-commit.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/PairingExchangeRetryState.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/PairingExchangeRetrySpec.swift" \
  -o "$GB_TMP/PairingExchangeRetrySpec"

"$GB_TMP/PairingExchangeRetrySpec"
