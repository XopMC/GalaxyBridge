#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-camera-extension-policy.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraExtensionPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/CameraExtensionPolicySpec.swift" \
  -o "$GB_TMP/CameraExtensionPolicySpec"
"$GB_TMP/CameraExtensionPolicySpec"
