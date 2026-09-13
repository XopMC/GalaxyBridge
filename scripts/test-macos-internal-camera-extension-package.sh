#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/galaxybridge-camera-package.XXXXXX")"
GB_LAUNCH_PID=""
gb_cleanup() {
  if [[ -n "$GB_LAUNCH_PID" ]] && /bin/kill -0 "$GB_LAUNCH_PID" 2>/dev/null; then
    /bin/kill -TERM "$GB_LAUNCH_PID" 2>/dev/null || true
    wait "$GB_LAUNCH_PID" 2>/dev/null || true
  fi
  /bin/rm -rf -- "$GB_TMP_DIR"
}
trap gb_cleanup EXIT
GB_APP="${GALAXYBRIDGE_PACKAGE_TEST_APP:-$GB_TMP_DIR/GalaxyBridgeInternal.app}"
[[ "$GB_APP" == /* && "$GB_APP" == *.app && "$GB_APP" != "$GB_ROOT/.build/GalaxyBridgeInternal.app" && ! "$GB_APP" -ef "$GB_ROOT/.build/GalaxyBridgeInternal.app" ]] || {
  echo "Package tests require an isolated absolute .app output." >&2
  exit 2
}
GB_EXTENSION_BUNDLE_ID="com.xopmc.GalaxyBridge.CameraExtension"
GB_EXTENSION="$GB_APP/Contents/Library/SystemExtensions/$GB_EXTENSION_BUNDLE_ID.systemextension"
GB_EXTENSION_EXECUTABLE="$GB_EXTENSION/Contents/MacOS/GalaxyBridgeCameraExtension"
GB_EXPECTED_MACH_SERVICE="group.com.xopmc.GalaxyBridge.CameraExtension"

assert_equal() {
  local GB_ACTUAL="$1"
  local GB_EXPECTED="$2"
  local GB_LABEL="$3"
  if [[ "$GB_ACTUAL" != "$GB_EXPECTED" ]]; then
    echo "$GB_LABEL: expected '$GB_EXPECTED', got '$GB_ACTUAL'." >&2
    exit 1
  fi
}

GALAXYBRIDGE_INTERNAL_APP_OUTPUT="$GB_APP" "$GB_ROOT/scripts/package-macos-internal.sh" >/dev/null

if [[ ! -d "$GB_EXTENSION" ]]; then
  echo "Internal package is missing the embedded Camera system extension." >&2
  exit 1
fi
if [[ ! -x "$GB_EXTENSION_EXECUTABLE" ]]; then
  echo "Embedded Camera system extension has no executable." >&2
  exit 1
fi
test -s "$GB_APP/Contents/Resources/GalaxyBridge.icns"
test -s "$GB_APP/Contents/Resources/PrivacyInfo.xcprivacy"
/usr/bin/plutil -lint "$GB_APP/Contents/Resources/PrivacyInfo.xcprivacy" >/dev/null

GB_EXTENSION_INFO="$GB_EXTENSION/Contents/Info.plist"
assert_equal \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$GB_EXTENSION_INFO")" \
  "$GB_EXTENSION_BUNDLE_ID" \
  "Camera Extension bundle identifier"
assert_equal \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$GB_EXTENSION_INFO")" \
  "SYSX" \
  "Camera Extension package type"
assert_equal \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$GB_EXTENSION_INFO")" \
  "GalaxyBridgeCameraExtension" \
  "Camera Extension executable"
assert_equal \
  "$(/usr/libexec/PlistBuddy -c 'Print :CMIOExtensionMachServiceName' "$GB_EXTENSION_INFO")" \
  "$GB_EXPECTED_MACH_SERVICE" \
  "Camera Extension Mach service"

/usr/bin/codesign -d --entitlements :- "$GB_APP" \
  >"$GB_TMP_DIR/app-entitlements.plist" 2>/dev/null
/usr/bin/codesign -d --entitlements :- "$GB_EXTENSION" \
  >"$GB_TMP_DIR/extension-entitlements.plist" 2>/dev/null

# The default internal identity is self-signed. Restricted distribution
# entitlements must not be attached to it: launchd rejects such a host before
# main(). Their exact host/extension match is verified on the provisioned
# Xcode archive instead.
if /usr/libexec/PlistBuddy -c \
  'Print :com.apple.developer.system-extension.install' \
  "$GB_TMP_DIR/app-entitlements.plist" >/dev/null 2>&1; then
  echo "Self-signed internal host unexpectedly has a restricted system-extension entitlement." >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.application-groups' \
  "$GB_TMP_DIR/app-entitlements.plist" >/dev/null 2>&1; then
  echo "Self-signed internal host unexpectedly has a restricted App Group entitlement." >&2
  exit 1
fi

/usr/bin/codesign --verify --strict --verbose=2 "$GB_EXTENSION"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$GB_APP"

if [[ "${GALAXYBRIDGE_SKIP_PACKAGE_LAUNCH:-0}" != "1" ]]; then
  GALAXYBRIDGE_INTERNAL_RECORD_STORE_ROOT="$GB_TMP_DIR/records" \
    "$GB_APP/Contents/MacOS/GalaxyBridgeMac" >/dev/null 2>&1 &
  GB_LAUNCH_PID=$!
  /bin/sleep 1
  if ! /bin/kill -0 "$GB_LAUNCH_PID" 2>/dev/null; then
    wait "$GB_LAUNCH_PID" || true
    echo "Self-signed internal host was rejected before reaching its run loop." >&2
    exit 1
  fi
  /bin/kill -TERM "$GB_LAUNCH_PID" 2>/dev/null || true
  wait "$GB_LAUNCH_PID" 2>/dev/null || true
  GB_LAUNCH_PID=""
fi

echo "macOS internal Camera Extension package contract passed."
