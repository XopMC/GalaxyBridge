#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-app-catalog-export.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationCatalogExportManifest.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ApplicationCatalogExportManifestSpec.swift" \
  -o "$GB_TMP/ApplicationCatalogExportManifestSpec"

"$GB_TMP/ApplicationCatalogExportManifestSpec"
