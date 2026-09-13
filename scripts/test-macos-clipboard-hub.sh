#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-clipboard-hub.XXXXXX")
trap 'rm -rf "$GB_TMP"' EXIT INT TERM

swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/ClipboardHubState.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ClipboardHubStateSpec.swift" \
  -o "$GB_TMP/ClipboardHubStateSpec"

"$GB_TMP/ClipboardHubStateSpec"
