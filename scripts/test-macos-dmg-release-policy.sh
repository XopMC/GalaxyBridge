#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-dmg-policy-spec.XXXXXX")
trap '/bin/rm -rf -- "$GB_TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
GB_APP="$GB_TMP/Galaxy Bridge.app"
GB_OUTPUT="$GB_TMP/release.dmg"
/bin/mkdir -p "$GB_APP/Contents/MacOS"
/bin/cp /usr/bin/true "$GB_APP/Contents/MacOS/GalaxyBridgeMac"
/usr/bin/plutil -create xml1 "$GB_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.xopmc.GalaxyBridge.internal "$GB_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string GalaxyBridgeMac "$GB_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$GB_APP/Contents/Info.plist"
/usr/bin/plutil -insert GalaxyBridgeDistribution -string internal "$GB_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$GB_APP" >/dev/null 2>&1

/bin/ln -s "$GB_APP/Contents" "$GB_TMP/source-alias"
for GB_NESTED in "$GB_APP/nested.dmg" "$GB_APP/Contents/nested.dmg" "$GB_TMP/source-alias/nested.dmg"; do
  if sh "$GB_ROOT/scripts/package-macos-dmg.sh" "$GB_APP" "$GB_NESTED" > "$GB_TMP/nested.log" 2>&1; then
    printf 'Release staging inside the source was accepted\n' >&2
    exit 1
  fi
  /usr/bin/grep -Fq 'output cannot be inside the source app bundle' "$GB_TMP/nested.log"
  test ! -e "$GB_NESTED"
done
if [ -d "$GB_TMP/gALAXY bRIDGE.app" ]; then
  if sh "$GB_ROOT/scripts/package-macos-dmg.sh" "$GB_APP" "$GB_TMP/gALAXY bRIDGE.app/Contents/case-alias.dmg" > "$GB_TMP/case-alias.log" 2>&1; then
    printf 'Case alias bypassed release nested output rejection\n' >&2
    exit 1
  fi
  /usr/bin/grep -Fq 'output cannot be inside the source app bundle' "$GB_TMP/case-alias.log"
  test ! -e "$GB_APP/Contents/case-alias.dmg"
fi
/usr/bin/codesign --verify --deep --strict "$GB_APP"

if sh "$GB_ROOT/scripts/package-macos-dmg.sh" "$GB_APP" "$GB_OUTPUT" > "$GB_TMP/internal.log" 2>&1; then
  printf 'Internal app was accepted for release\n' >&2
  exit 1
fi
/usr/bin/grep -Fq 'Internal/debug builds are not installers' "$GB_TMP/internal.log"
test ! -e "$GB_OUTPUT"
/usr/bin/plutil -replace CFBundleIdentifier -string com.xopmc.GalaxyBridge "$GB_APP/Contents/Info.plist"
/usr/bin/plutil -replace GalaxyBridgeDistribution -string developer-id "$GB_APP/Contents/Info.plist"
/usr/bin/codesign --force --options runtime --sign - "$GB_APP" >/dev/null 2>&1
GB_SOURCE_HASH=$(/usr/bin/shasum -a 256 "$GB_APP/Contents/MacOS/GalaxyBridgeMac")
# Legacy flags from the source-app fixture must NOT disable DMG release policy.
if GB_DEVELOPER_ID_ADHOC_SIGNING_FOR_TESTS=1 GB_DEVELOPER_ID_SKIP_NOTARIZATION_FOR_TESTS=1 \
    sh "$GB_ROOT/scripts/package-macos-dmg.sh" "$GB_APP" "$GB_OUTPUT" > "$GB_TMP/adhoc.log" 2>&1; then
  printf 'Ad-hoc fixture was accepted for release\n' >&2
  exit 1
fi
/usr/bin/grep -Fq 'a real Developer ID Application signature is required' "$GB_TMP/adhoc.log"
test ! -e "$GB_OUTPUT"
test "$GB_SOURCE_HASH" = "$(/usr/bin/shasum -a 256 "$GB_APP/Contents/MacOS/GalaxyBridgeMac")"
/usr/bin/codesign --verify --deep --strict "$GB_APP"
printf 'DMG release rejection spec passed: Internal and ad-hoc refused, legacy test bypass ignored, source unchanged. No submission to Apple.\n'
