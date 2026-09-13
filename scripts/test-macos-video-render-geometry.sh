#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-video-geometry-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/Media/VideoRenderGeometry.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/VideoRenderGeometrySpec.swift" \
    -o "$GB_TMP/VideoRenderGeometrySpec"

"$GB_TMP/VideoRenderGeometrySpec"
