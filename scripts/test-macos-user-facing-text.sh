#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-copy-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

gb_make_bundle() {
    GB_LANGUAGE=$1
    GB_BUNDLE=$2
    /bin/mkdir -p "$GB_BUNDLE/Contents/Resources"
    /bin/cp "$GB_ROOT/macos/GalaxyBridgeMac/Resources/$GB_LANGUAGE.lproj/Localizable.strings" \
        "$GB_BUNDLE/Contents/Resources/Localizable.strings"
    /usr/bin/plutil -create xml1 "$GB_BUNDLE/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "com.xopmc.GalaxyBridge.TextSpec.$GB_LANGUAGE" \
        "$GB_BUNDLE/Contents/Info.plist"
}

gb_make_bundle en "$GB_TMP/English.bundle"
gb_make_bundle ru "$GB_TMP/Russian.bundle"

xcrun swiftc \
    "$GB_ROOT/macos/GalaxyBridgeMac/UserFacingTextResolver.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/UserFacingTextSpec.swift" \
    -o "$GB_TMP/UserFacingTextSpec"

"$GB_TMP/UserFacingTextSpec" "$GB_TMP/English.bundle" "$GB_TMP/Russian.bundle"
