#!/bin/sh
# Internal layout primitive only. It does not sign, notarize, or approve a
# release. Use package-macos-dmg.sh for a distributable installer.
set -eu

gb_fail() { printf 'DMG layout error: %s\n' "$1" >&2; exit 2; }
[ "$#" = 2 ] || gb_fail 'usage: create-macos-dmg-layout.sh SOURCE.app OUTPUT.dmg'
GB_APP=$1
GB_OUTPUT=$2
[ -f "$GB_APP/Contents/Info.plist" ] || gb_fail 'source must be an app bundle with Contents/Info.plist.'
GB_TYPE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$GB_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$GB_TYPE" = APPL ] || gb_fail 'source bundle must declare CFBundlePackageType APPL.'
GB_EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$GB_APP/Contents/Info.plist" 2>/dev/null || true)
case "$GB_EXECUTABLE" in ''|.|..|*/*) gb_fail 'invalid bundle executable name.' ;; esac
[ -x "$GB_APP/Contents/MacOS/$GB_EXECUTABLE" ] || gb_fail 'source bundle executable is missing.'
case "$GB_OUTPUT" in *.dmg) ;; *) gb_fail 'output must end with .dmg.' ;; esac
if [ -e "$GB_OUTPUT" ] || [ -L "$GB_OUTPUT" ]; then gb_fail 'output already exists; choose a new path.'; fi
GB_PARENT=$(CDPATH= cd -- "$(/usr/bin/dirname "$GB_OUTPUT")" && pwd -P)
GB_SOURCE_CANONICAL=$(CDPATH= cd -- "$GB_APP" && pwd -P)
# Compare filesystem identities, not path spelling: default APFS also resolves
# case and Unicode-normalization aliases that pwd -P does not normalize.
GB_ANCESTOR=$GB_PARENT
while :; do
  [ ! "$GB_ANCESTOR" -ef "$GB_SOURCE_CANONICAL" ] || gb_fail 'output cannot be inside the source app bundle.'
  [ "$GB_ANCESTOR" != / ] || break
  GB_ANCESTOR=$(/usr/bin/dirname "$GB_ANCESTOR")
done
GB_OUTPUT="$GB_PARENT/$(/usr/bin/basename "$GB_OUTPUT")"
# A same-filesystem staging directory permits atomic, no-clobber publication
# with link(2), even if another producer creates the output during packaging.
GB_TMP=$(mktemp -d "$GB_PARENT/.galaxybridge-dmg-layout.XXXXXX")
trap '/bin/rm -rf -- "$GB_TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
/bin/mkdir "$GB_TMP/content"
/usr/bin/ditto "$GB_APP" "$GB_TMP/content/Galaxy Bridge.app"
/bin/ln -s /Applications "$GB_TMP/content/Applications"
/usr/bin/hdiutil create -srcfolder "$GB_TMP/content" -volname 'Galaxy Bridge' \
  -fs HFS+ -format UDZO -nospotlight -quiet "$GB_TMP/installer.dmg"
/usr/bin/hdiutil verify "$GB_TMP/installer.dmg" -quiet
/bin/link "$GB_TMP/installer.dmg" "$GB_OUTPUT" || gb_fail 'could not publish image without overwriting an existing output.'
printf 'Created unsigned DMG layout (not release-approved): %s\n' "$GB_OUTPUT"
