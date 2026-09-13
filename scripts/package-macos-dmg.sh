#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
gb_fail() { printf 'Release DMG error: %s\n' "$1" >&2; exit 2; }
[ "$#" = 2 ] || gb_fail 'usage: package-macos-dmg.sh NOTARIZED_DEVELOPER_ID.app OUTPUT.dmg'
GB_APP=$1
GB_OUTPUT=$2
[ -f "$GB_APP/Contents/Info.plist" ] || gb_fail 'source app is missing.'
case "$GB_OUTPUT" in *.dmg) ;; *) gb_fail 'output must end with .dmg.' ;; esac
if [ -e "$GB_OUTPUT" ] || [ -L "$GB_OUTPUT" ]; then gb_fail 'output already exists; choose a new path.'; fi
GB_PARENT=$(CDPATH= cd -- "$(/usr/bin/dirname "$GB_OUTPUT")" && pwd -P)
GB_SOURCE_CANONICAL=$(CDPATH= cd -- "$GB_APP" && pwd -P)
GB_ANCESTOR=$GB_PARENT
while :; do
  [ ! "$GB_ANCESTOR" -ef "$GB_SOURCE_CANONICAL" ] || gb_fail 'output cannot be inside the source app bundle.'
  [ "$GB_ANCESTOR" != / ] || break
  GB_ANCESTOR=$(/usr/bin/dirname "$GB_ANCESTOR")
done
GB_OUTPUT="$GB_PARENT/$(/usr/bin/basename "$GB_OUTPUT")"
GB_TMP=$(mktemp -d "$GB_PARENT/.galaxybridge-release-dmg.XXXXXX")
trap '/bin/rm -rf -- "$GB_TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
# Validate an owned snapshot, not a mutable build directory. Neither the input
# app nor an installed application is re-signed or changed by this command.
/usr/bin/ditto "$GB_APP" "$GB_TMP/Galaxy Bridge.app"
GB_STAGED_APP="$GB_TMP/Galaxy Bridge.app"
GB_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$GB_STAGED_APP/Contents/Info.plist" 2>/dev/null || true)
GB_DISTRIBUTION=$(/usr/libexec/PlistBuddy -c 'Print :GalaxyBridgeDistribution' "$GB_STAGED_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$GB_ID" = com.xopmc.GalaxyBridge ] && [ "$GB_DISTRIBUTION" = developer-id ] || \
  gb_fail 'only com.xopmc.GalaxyBridge Developer ID builds are accepted; Internal/debug builds are not installers.'
/usr/bin/codesign --verify --deep --strict "$GB_STAGED_APP"
GB_SIGNATURE=$(/usr/bin/codesign --display --verbose=4 "$GB_STAGED_APP" 2>&1)
printf '%s\n' "$GB_SIGNATURE" | /usr/bin/grep -q '^Authority=Developer ID Application:' || \
  gb_fail 'a real Developer ID Application signature is required; ad-hoc/test signing is never accepted.'
printf '%s\n' "$GB_SIGNATURE" | /usr/bin/grep -q 'flags=.*runtime' || gb_fail 'hardened runtime is required.'
GB_ADB_DIR="$GB_STAGED_APP/Contents/Resources/platform-tools"
[ -x "$GB_ADB_DIR/adb" ] && [ -s "$GB_ADB_DIR/NOTICE" ] && \
  [ -s "$GB_ADB_DIR/AOSP-SHA256SUMS" ] && [ -s "$GB_ADB_DIR/SHA256SUMS" ] || \
  gb_fail 'embedded AOSP adb, NOTICE, source checksums and signed checksums are required. Clients must not install adb.'
GB_NAMES=$(/usr/bin/awk 'NF == 2 { sub(/^\*/, "", $2); print $2 }' "$GB_ADB_DIR/SHA256SUMS" | LC_ALL=C /usr/bin/sort)
[ "$GB_NAMES" = "NOTICE
adb" ] || gb_fail 'embedded signed checksum manifest must contain exactly adb and NOTICE.'
(cd "$GB_ADB_DIR" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null) || gb_fail 'embedded adb checksums failed.'
/usr/bin/lipo "$GB_ADB_DIR/adb" -verify_arch arm64
/usr/bin/codesign --verify --strict "$GB_ADB_DIR/adb"
/usr/bin/xcrun stapler validate "$GB_STAGED_APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$GB_STAGED_APP"
case "${GB_DEVELOPER_ID_IDENTITY:-}" in
  'Developer ID Application: '*) ;;
  *) gb_fail 'GB_DEVELOPER_ID_IDENTITY must name a Developer ID Application identity.' ;;
esac
[ -n "${GB_DEVELOPER_ID_NOTARY_PROFILE:-}" ] || gb_fail 'GB_DEVELOPER_ID_NOTARY_PROFILE is required to notarize the DMG.'

sh "$GB_ROOT/scripts/create-macos-dmg-layout.sh" "$GB_STAGED_APP" "$GB_TMP/installer.dmg"
/usr/bin/codesign --force --timestamp --identifier com.xopmc.GalaxyBridge.installer \
  --sign "$GB_DEVELOPER_ID_IDENTITY" "$GB_TMP/installer.dmg"
/usr/bin/codesign --verify --strict "$GB_TMP/installer.dmg"
/usr/bin/xcrun notarytool submit "$GB_TMP/installer.dmg" --keychain-profile "$GB_DEVELOPER_ID_NOTARY_PROFILE" --wait
/usr/bin/xcrun stapler staple "$GB_TMP/installer.dmg"
/usr/bin/xcrun stapler validate "$GB_TMP/installer.dmg"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$GB_TMP/installer.dmg"
/usr/bin/hdiutil verify "$GB_TMP/installer.dmg" -quiet
/bin/link "$GB_TMP/installer.dmg" "$GB_OUTPUT" || gb_fail 'output appeared while packaging; existing artifact was not replaced.'
printf 'Created signed and notarized drag-to-Applications installer: %s\n' "$GB_OUTPUT"
printf 'This packaging result does not replace functional, hardware, upgrade, or clean-Mac release gates.\n'
