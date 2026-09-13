#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-dmg-layout-spec.XXXXXX")
GB_MOUNT="$GB_TMP/mounted"
GB_ATTACHED=0
gb_cleanup() {
  if [ "$GB_ATTACHED" = 1 ]; then
    /usr/bin/hdiutil detach "$GB_MOUNT" -quiet || {
      printf 'Could not detach test image; retained %s\n' "$GB_TMP" >&2
      return
    }
  fi
  /bin/rm -rf -- "$GB_TMP"
}
trap gb_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

GB_SOURCE="$GB_TMP/Source with spaces.app"
GB_DMG="$GB_TMP/Installer with spaces.dmg"
/bin/mkdir -p "$GB_SOURCE/Contents/MacOS" "$GB_SOURCE/Contents/Resources" "$GB_MOUNT"
/bin/cp /usr/bin/true "$GB_SOURCE/Contents/MacOS/GalaxyBridgeMac"
/bin/cp "$GB_ROOT/macos/GalaxyBridgeMac/Resources/GalaxyBridge.icns" "$GB_SOURCE/Contents/Resources/"
/usr/bin/plutil -create xml1 "$GB_SOURCE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.xopmc.GalaxyBridge "$GB_SOURCE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string GalaxyBridgeMac "$GB_SOURCE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$GB_SOURCE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIconFile -string GalaxyBridge.icns "$GB_SOURCE/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$GB_SOURCE" >/dev/null 2>&1

# These must fail before staging/copying. A nested destination otherwise lets
# ditto recursively copy the input into itself; a symlink must not bypass it.
/bin/ln -s "$GB_SOURCE/Contents/Resources" "$GB_TMP/source-alias"
for GB_NESTED in "$GB_SOURCE/nested.dmg" "$GB_SOURCE/Contents/Resources/nested.dmg" "$GB_TMP/source-alias/nested.dmg"; do
  if sh "$GB_ROOT/scripts/create-macos-dmg-layout.sh" "$GB_SOURCE" "$GB_NESTED" > "$GB_TMP/nested.log" 2>&1; then
    printf 'Nested source/output paths were accepted\n' >&2
    exit 1
  fi
  /usr/bin/grep -Fq 'output cannot be inside the source app bundle' "$GB_TMP/nested.log"
  test ! -e "$GB_NESTED"
done
if [ -d "$GB_TMP/source WITH SPACES.app" ]; then
  if sh "$GB_ROOT/scripts/create-macos-dmg-layout.sh" "$GB_SOURCE" "$GB_TMP/source WITH SPACES.app/Contents/Resources/case-alias.dmg" > "$GB_TMP/case-alias.log" 2>&1; then
    printf 'Case alias bypassed nested output rejection\n' >&2
    exit 1
  fi
  /usr/bin/grep -Fq 'output cannot be inside the source app bundle' "$GB_TMP/case-alias.log"
  test ! -e "$GB_SOURCE/Contents/Resources/case-alias.dmg"
fi
/usr/bin/codesign --verify --deep --strict "$GB_SOURCE"

sh "$GB_ROOT/scripts/create-macos-dmg-layout.sh" "$GB_SOURCE" "$GB_DMG"
/usr/bin/hdiutil verify "$GB_DMG" -quiet
/usr/bin/hdiutil attach "$GB_DMG" -readonly -nobrowse -mountpoint "$GB_MOUNT" -quiet
GB_ATTACHED=1
test "$(/usr/bin/readlink "$GB_MOUNT/Applications")" = /Applications
test -d "$GB_MOUNT/Galaxy Bridge.app/Contents"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$GB_MOUNT/Galaxy Bridge.app/Contents/Info.plist")" = com.xopmc.GalaxyBridge
/usr/bin/codesign --verify --deep --strict "$GB_MOUNT/Galaxy Bridge.app"
/usr/bin/cmp "$GB_SOURCE/Contents/MacOS/GalaxyBridgeMac" "$GB_MOUNT/Galaxy Bridge.app/Contents/MacOS/GalaxyBridgeMac"
/usr/bin/cmp "$GB_SOURCE/Contents/Resources/GalaxyBridge.icns" "$GB_MOUNT/Galaxy Bridge.app/Contents/Resources/GalaxyBridge.icns"
if /usr/bin/touch "$GB_MOUNT/must-not-be-writable" 2>/dev/null; then
  printf 'Installer image is writable\n' >&2
  exit 1
fi
# Exercise the same bundle copy as dragging to Applications, without installing
# a fixture into the user's real /Applications or executing its code.
/usr/bin/ditto "$GB_MOUNT/Galaxy Bridge.app" "$GB_TMP/Test Applications/Galaxy Bridge.app"
/usr/bin/codesign --verify --deep --strict "$GB_TMP/Test Applications/Galaxy Bridge.app"
/usr/bin/hdiutil detach "$GB_MOUNT" -quiet
GB_ATTACHED=0

GB_ORIGINAL_HASH=$(/usr/bin/shasum -a 256 "$GB_DMG")
if sh "$GB_ROOT/scripts/create-macos-dmg-layout.sh" "$GB_SOURCE" "$GB_DMG" > "$GB_TMP/existing.log" 2>&1; then
  printf 'Existing installer was overwritten\n' >&2
  exit 1
fi
/usr/bin/grep -Fq 'already exists' "$GB_TMP/existing.log"
test "$GB_ORIGINAL_HASH" = "$(/usr/bin/shasum -a 256 "$GB_DMG")"
/bin/ln -s "$GB_TMP/nonexistent-target" "$GB_TMP/dangling.dmg"
if sh "$GB_ROOT/scripts/create-macos-dmg-layout.sh" "$GB_SOURCE" "$GB_TMP/dangling.dmg" > "$GB_TMP/symlink.log" 2>&1; then
  printf 'Output symlink was accepted\n' >&2
  exit 1
fi
test -L "$GB_TMP/dangling.dmg"
test ! -e "$GB_TMP/nonexistent-target"
if sh "$GB_ROOT/scripts/create-macos-dmg-layout.sh" "$GB_TMP" "$GB_TMP/invalid.dmg" > "$GB_TMP/invalid.log" 2>&1; then
  printf 'A non-app folder was accepted\n' >&2
  exit 1
fi
test ! -e "$GB_TMP/invalid.dmg"
printf 'DMG layout spec passed: real read-only image, Applications link, signed bundle copy, icon, safe output. Not a release/signing acceptance.\n'
