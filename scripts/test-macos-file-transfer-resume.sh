#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-file-transfer-resume.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/Transport/CompanionFileTransferResumeCoordinator.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/CompanionFileTransferResumeSpec.swift" \
    -o "$GB_TMP/CompanionFileTransferResumeSpec"

"$GB_TMP/CompanionFileTransferResumeSpec"
