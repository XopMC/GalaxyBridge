#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_AOSP_ADB_ROOT=${GB_AOSP_ADB_ROOT:-"$GB_ROOT/third_party/aosp-adb"}
GB_SOURCE_APP=${1:-${GB_DEVELOPER_ID_SOURCE_APP:-}}
GB_OUTPUT_APP=${2:-"$GB_ROOT/.build/GalaxyBridgeDeveloperID.app"}
GB_IDENTITY=${GB_DEVELOPER_ID_IDENTITY:-}
GB_NOTARY_PROFILE=${GB_DEVELOPER_ID_NOTARY_PROFILE:-}
GB_ADHOC_TEST_SIGNING=${GB_DEVELOPER_ID_ADHOC_SIGNING_FOR_TESTS:-0}
GB_SKIP_NOTARIZATION=${GB_DEVELOPER_ID_SKIP_NOTARIZATION_FOR_TESTS:-0}

gb_fail() {
  printf 'Developer ID package error: %s\n' "$1" >&2
  exit 2
}

# Check the pinned AOSP output before any source-app or signing work. This
# intentionally never searches Android SDK or Homebrew locations: SDK adb is
# licensed for SDK use and must not be redistributed by GalaxyBridge.
if [ ! -x "$GB_AOSP_ADB_ROOT/adb" ] || \
   [ ! -f "$GB_AOSP_ADB_ROOT/NOTICE" ] || \
   [ ! -f "$GB_AOSP_ADB_ROOT/SHA256SUMS" ]; then
  gb_fail "pinned AOSP adb is absent. Produce it with scripts/build-aosp-adb.sh from android-17.0.0_r1. Android SDK adb is not an allowed substitute."
fi

GB_AOSP_ADB_CANONICAL=$(CDPATH= cd -- "$GB_AOSP_ADB_ROOT" && pwd -P)
GB_ANDROID_HOME=${ANDROID_HOME:-}
GB_ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-}
for GB_SDK_ROOT in \
  "$HOME/Library/Android/sdk" \
  "$GB_ANDROID_HOME" \
  "$GB_ANDROID_SDK_ROOT"
do
  [ -n "$GB_SDK_ROOT" ] || continue
  [ -d "$GB_SDK_ROOT/platform-tools" ] || continue
  GB_SDK_PLATFORM_TOOLS=$(CDPATH= cd -- "$GB_SDK_ROOT/platform-tools" && pwd -P)
  if [ "$GB_AOSP_ADB_CANONICAL" = "$GB_SDK_PLATFORM_TOOLS" ]; then
    gb_fail "Android SDK adb cannot be redistributed. Use the output of scripts/build-aosp-adb.sh instead."
  fi
done

GB_MANIFEST_NAMES=$(
  /usr/bin/awk 'NF == 2 { sub(/^\*/, "", $2); print $2 }' "$GB_AOSP_ADB_ROOT/SHA256SUMS" |
    LC_ALL=C /usr/bin/sort
)
if [ "$GB_MANIFEST_NAMES" != "NOTICE
adb" ]; then
  gb_fail "AOSP SHA256SUMS must contain exactly the relative entries adb and NOTICE."
fi
if ! (
  cd "$GB_AOSP_ADB_ROOT"
  /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
); then
  gb_fail "AOSP adb checksum verification failed. Rebuild it with scripts/build-aosp-adb.sh."
fi
if ! /usr/bin/file "$GB_AOSP_ADB_ROOT/adb" | /usr/bin/grep -Fq 'Mach-O'; then
  gb_fail "pinned AOSP adb is not a macOS Mach-O executable. Build it from android-17.0.0_r1 before packaging."
fi

[ -n "$GB_SOURCE_APP" ] || gb_fail "source .app is required as the first argument or GB_DEVELOPER_ID_SOURCE_APP."
[ -d "$GB_SOURCE_APP/Contents" ] || gb_fail "source app does not contain Contents: $GB_SOURCE_APP"
[ -f "$GB_SOURCE_APP/Contents/Info.plist" ] || gb_fail "source app has no Contents/Info.plist: $GB_SOURCE_APP"

GB_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$GB_SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$GB_BUNDLE_ID" = "com.xopmc.GalaxyBridge" ] || \
  gb_fail "source app bundle identifier must be com.xopmc.GalaxyBridge (found: ${GB_BUNDLE_ID:-missing})."

case "$GB_OUTPUT_APP" in
  ''|/|"$HOME") gb_fail "refusing unsafe output path: $GB_OUTPUT_APP" ;;
esac

GB_STAGE="$GB_OUTPUT_APP.staging.$$"
GB_BACKUP="$GB_OUTPUT_APP.previous.$$"
gb_cleanup() {
  /bin/rm -rf -- "$GB_STAGE"
  /bin/rm -f -- "$GB_STAGE.notary.zip"
  if [ -e "$GB_BACKUP" ] && [ ! -e "$GB_OUTPUT_APP" ]; then
    /bin/mv -- "$GB_BACKUP" "$GB_OUTPUT_APP"
  fi
}
trap gb_cleanup EXIT HUP INT TERM

/bin/rm -rf -- "$GB_STAGE" "$GB_BACKUP"
/bin/mkdir -p "$(/usr/bin/dirname "$GB_OUTPUT_APP")"
/usr/bin/ditto "$GB_SOURCE_APP" "$GB_STAGE"
/bin/mkdir -p "$GB_STAGE/Contents/Resources/platform-tools"
/usr/bin/install -m 0755 "$GB_AOSP_ADB_ROOT/adb" \
  "$GB_STAGE/Contents/Resources/platform-tools/adb"
/bin/cp "$GB_AOSP_ADB_ROOT/NOTICE" "$GB_STAGE/Contents/Resources/platform-tools/NOTICE"
/bin/cp "$GB_AOSP_ADB_ROOT/SHA256SUMS" "$GB_STAGE/Contents/Resources/platform-tools/AOSP-SHA256SUMS"
/usr/bin/plutil -replace GalaxyBridgeDistribution -string developer-id "$GB_STAGE/Contents/Info.plist" 2>/dev/null || \
  /usr/bin/plutil -insert GalaxyBridgeDistribution -string developer-id "$GB_STAGE/Contents/Info.plist"

if [ "$GB_ADHOC_TEST_SIGNING" = 1 ]; then
  GB_CODESIGN_IDENTITY=-
  GB_CODESIGN_TIMESTAMP=--timestamp=none
else
  [ -n "$GB_IDENTITY" ] || \
    gb_fail "GB_DEVELOPER_ID_IDENTITY is required (for example: Developer ID Application: Organization (TEAMID))."
  GB_CODESIGN_IDENTITY=$GB_IDENTITY
  GB_CODESIGN_TIMESTAMP=--timestamp
fi

# The injected AOSP adb is nested executable code. Sign it before the outer
# app so the sealed resources and the hardened-runtime signature agree.
/usr/bin/codesign --force --options runtime "$GB_CODESIGN_TIMESTAMP" \
  --sign "$GB_CODESIGN_IDENTITY" "$GB_STAGE/Contents/Resources/platform-tools/adb"
/usr/bin/codesign --verify --strict --verbose=2 \
  "$GB_STAGE/Contents/Resources/platform-tools/adb"
(
  cd "$GB_STAGE/Contents/Resources/platform-tools"
  /usr/bin/shasum -a 256 adb NOTICE > SHA256SUMS
)

# Preserve the resolved entitlements from the provisioned source app (including
# Camera Extension installation and App Group access). Do not replace them with
# the build-time template, whose TeamIdentifierPrefix is unresolved here.
/usr/bin/codesign --force --options runtime "$GB_CODESIGN_TIMESTAMP" \
  --preserve-metadata=entitlements --sign "$GB_CODESIGN_IDENTITY" "$GB_STAGE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$GB_STAGE"

if [ "$GB_SKIP_NOTARIZATION" != 1 ]; then
  [ -n "$GB_NOTARY_PROFILE" ] || \
    gb_fail "GB_DEVELOPER_ID_NOTARY_PROFILE is required for notarytool submission."
  GB_NOTARY_ARCHIVE="$GB_STAGE.notary.zip"
  /bin/rm -f -- "$GB_NOTARY_ARCHIVE"
  /usr/bin/ditto -c -k --keepParent "$GB_STAGE" "$GB_NOTARY_ARCHIVE"
  /usr/bin/xcrun notarytool submit "$GB_NOTARY_ARCHIVE" \
    --keychain-profile "$GB_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$GB_STAGE"
  /usr/bin/xcrun stapler validate "$GB_STAGE"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$GB_STAGE"
  /bin/rm -f -- "$GB_NOTARY_ARCHIVE"
fi

if [ -e "$GB_OUTPUT_APP" ]; then
  /bin/mv -- "$GB_OUTPUT_APP" "$GB_BACKUP"
fi
/bin/mv -- "$GB_STAGE" "$GB_OUTPUT_APP"
/bin/rm -rf -- "$GB_BACKUP"
trap - EXIT HUP INT TERM

printf 'Created signed Developer ID artifact %s with pinned AOSP adb, Apache NOTICE, and notarization policy.\n' "$GB_OUTPUT_APP"
