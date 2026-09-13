#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-developer-id-package-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

GB_MISSING_LOG="$GB_TMP/missing.log"
if GB_AOSP_ADB_ROOT="$GB_TMP/missing-aosp-adb" \
    GB_DEVELOPER_ID_ADHOC_SIGNING_FOR_TESTS=1 \
    GB_DEVELOPER_ID_SKIP_NOTARIZATION_FOR_TESTS=1 \
    "$GB_ROOT/scripts/package-macos-developer-id.sh" \
    "$GB_TMP/missing-source.app" "$GB_TMP/missing-output.app" \
    >"$GB_MISSING_LOG" 2>&1; then
  echo "Developer ID package unexpectedly accepted a missing AOSP adb artifact" >&2
  exit 1
fi
grep -Fq 'scripts/build-aosp-adb.sh' "$GB_MISSING_LOG"

GB_FAKE_HOME="$GB_TMP/home"
GB_SDK_PLATFORM_TOOLS="$GB_FAKE_HOME/Library/Android/sdk/platform-tools"
GB_SDK_LOG="$GB_TMP/sdk.log"
mkdir -p "$GB_SDK_PLATFORM_TOOLS"
printf '#!/bin/sh\nexit 0\n' > "$GB_SDK_PLATFORM_TOOLS/adb"
chmod 0755 "$GB_SDK_PLATFORM_TOOLS/adb"
printf 'SDK fixture must never be distributed\n' > "$GB_SDK_PLATFORM_TOOLS/NOTICE"
(
  cd "$GB_SDK_PLATFORM_TOOLS"
  shasum -a 256 adb NOTICE > SHA256SUMS
)
if ANDROID_SDK_ROOT="$GB_FAKE_HOME/Library/Android/sdk" \
    GB_AOSP_ADB_ROOT="$GB_SDK_PLATFORM_TOOLS" \
    GB_DEVELOPER_ID_ADHOC_SIGNING_FOR_TESTS=1 \
    GB_DEVELOPER_ID_SKIP_NOTARIZATION_FOR_TESTS=1 \
    "$GB_ROOT/scripts/package-macos-developer-id.sh" \
    "$GB_TMP/missing-source.app" "$GB_TMP/sdk-output.app" \
    >"$GB_SDK_LOG" 2>&1; then
  echo "Developer ID package unexpectedly accepted Android SDK platform-tools" >&2
  exit 1
fi
grep -Fq 'Android SDK adb cannot be redistributed' "$GB_SDK_LOG"
test ! -e "$GB_TMP/sdk-output.app"

GB_AOSP="$GB_TMP/aosp-adb"
GB_SOURCE="$GB_TMP/GalaxyBridge-source.app"
GB_OUTPUT="$GB_TMP/GalaxyBridge.app"
mkdir -p "$GB_AOSP" "$GB_SOURCE/Contents/MacOS" "$GB_SOURCE/Contents/Resources"
cp /usr/bin/true "$GB_AOSP/adb"
chmod 0755 "$GB_AOSP/adb"
printf 'Apache License 2.0 test fixture\n' > "$GB_AOSP/NOTICE"
(
  cd "$GB_AOSP"
  shasum -a 256 adb NOTICE > SHA256SUMS
)
cp /usr/bin/true "$GB_SOURCE/Contents/MacOS/GalaxyBridgeMac"
/usr/bin/plutil -create xml1 "$GB_SOURCE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.xopmc.GalaxyBridge "$GB_SOURCE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string GalaxyBridgeMac "$GB_SOURCE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$GB_SOURCE/Contents/Info.plist"
GB_ENTITLEMENTS="$GB_TMP/host-entitlements.plist"
/usr/bin/plutil -create xml1 "$GB_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.developer.system-extension.install bool true' "$GB_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$GB_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups:0 string TESTTEAM.group.com.xopmc.GalaxyBridge' "$GB_ENTITLEMENTS"
/usr/bin/codesign --force --sign - --entitlements "$GB_ENTITLEMENTS" "$GB_SOURCE" >/dev/null

GB_AOSP_ADB_ROOT="$GB_AOSP" \
GB_DEVELOPER_ID_ADHOC_SIGNING_FOR_TESTS=1 \
GB_DEVELOPER_ID_SKIP_NOTARIZATION_FOR_TESTS=1 \
  "$GB_ROOT/scripts/package-macos-developer-id.sh" "$GB_SOURCE" "$GB_OUTPUT"

test -x "$GB_OUTPUT/Contents/Resources/platform-tools/adb"
cmp "$GB_AOSP/NOTICE" "$GB_OUTPUT/Contents/Resources/platform-tools/NOTICE"
cmp "$GB_AOSP/SHA256SUMS" "$GB_OUTPUT/Contents/Resources/platform-tools/AOSP-SHA256SUMS"
test "$(/usr/libexec/PlistBuddy -c 'Print :GalaxyBridgeDistribution' "$GB_OUTPUT/Contents/Info.plist")" = developer-id
/usr/bin/file "$GB_OUTPUT/Contents/Resources/platform-tools/adb" | grep -Fq 'Mach-O'
/usr/bin/codesign --verify --strict "$GB_OUTPUT/Contents/Resources/platform-tools/adb"
/usr/bin/codesign --verify --deep --strict "$GB_OUTPUT"
GB_OUTPUT_ENTITLEMENTS="$GB_TMP/output-entitlements.plist"
/usr/bin/codesign --display --entitlements - --xml "$GB_OUTPUT" > "$GB_OUTPUT_ENTITLEMENTS" 2>/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.system-extension.install' "$GB_OUTPUT_ENTITLEMENTS")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$GB_OUTPUT_ENTITLEMENTS")" = TESTTEAM.group.com.xopmc.GalaxyBridge
(
  cd "$GB_OUTPUT/Contents/Resources/platform-tools"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

grep -Fq 'notarytool submit' "$GB_ROOT/scripts/package-macos-developer-id.sh"
grep -Fq 'stapler staple' "$GB_ROOT/scripts/package-macos-developer-id.sh"
grep -Fq 'stapler validate' "$GB_ROOT/scripts/package-macos-developer-id.sh"

printf 'Developer ID packaging contract spec passed\n'
