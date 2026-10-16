#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-clipboard-conversion.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -module-cache-path "$GB_TMP/modules" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ClipboardPayloadPolicy.swift" \
  "${GB_CLIPBOARD_CONVERSION_SOURCE:-$GB_ROOT/macos/GalaxyBridgeMac/ClipboardConversionWorker.swift}" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ClipboardConversionWorkerSpec.swift" \
  -o "$GB_TMP/ClipboardConversionWorkerSpec"
"$GB_TMP/ClipboardConversionWorkerSpec"
