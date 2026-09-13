#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-clipboard-policy.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library \
  "$GB_ROOT/macos/GalaxyBridgeMac/ClipboardPayloadPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/MacClipboardPayloadPolicySpec.swift" \
  -o "$GB_TMP/MacClipboardPayloadPolicySpec"

"$GB_TMP/MacClipboardPayloadPolicySpec"
