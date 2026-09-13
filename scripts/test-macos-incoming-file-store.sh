#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-incoming-store.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionFileIngressGate.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/IncomingFileTransferStore.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/IncomingFileTransferStoreSpec.swift" \
    -o "$GB_TMP/spec"
"$GB_TMP/spec"
