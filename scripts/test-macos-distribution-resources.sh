#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_RESOURCES="$GB_ROOT/macos/GalaxyBridgeMac/Resources"
GB_PRIVACY="$GB_RESOURCES/PrivacyInfo.xcprivacy"
GB_ICON="$GB_RESOURCES/GalaxyBridge.icns"
GB_APPICON="$GB_ROOT/macos/GalaxyBridgeMac/Assets.xcassets/AppIcon.appiconset"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-resources.XXXXXX")"
trap '/bin/rm -rf -- "$GB_TMP"' EXIT

/usr/bin/plutil -lint "$GB_PRIVACY" "$GB_ROOT/macos/GalaxyBridgeMac/Info.plist"
[[ "$(/usr/bin/plutil -extract NSPrivacyTracking raw "$GB_PRIVACY")" == "false" ]]
[[ "$(/usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw "$GB_PRIVACY")" == \
  "NSPrivacyAccessedAPICategoryUserDefaults" ]]
[[ "$(/usr/bin/plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 raw "$GB_PRIVACY")" == \
  "CA92.1" ]]

for GB_LOCALE_DIR in "$GB_RESOURCES"/*.lproj; do
  GB_INFO_STRINGS="$GB_LOCALE_DIR/InfoPlist.strings"
  /usr/bin/plutil -lint "$GB_INFO_STRINGS"
  /usr/bin/plutil -extract CFBundleDisplayName raw "$GB_INFO_STRINGS" | /usr/bin/grep -Fq 'Galaxy Bridge'
  /usr/bin/plutil -extract NSLocalNetworkUsageDescription raw "$GB_INFO_STRINGS" | /usr/bin/grep -q '[^[:space:]]'
done

/usr/bin/jq -e '.info.version == 1 and ([.images[].filename] | length == 10)' \
  "$GB_APPICON/Contents.json" >/dev/null
for GB_SIZE in 16 32 128 256 512 1024; do
  GB_PNG="$GB_APPICON/AppIcon-${GB_SIZE}.png"
  test -s "$GB_PNG"
  [[ "$(/usr/bin/sips -g pixelWidth "$GB_PNG" | /usr/bin/awk '/pixelWidth/{print $2}')" == "$GB_SIZE" ]]
  [[ "$(/usr/bin/sips -g pixelHeight "$GB_PNG" | /usr/bin/awk '/pixelHeight/{print $2}')" == "$GB_SIZE" ]]
done

test -s "$GB_ICON"
/usr/bin/iconutil --convert iconset --output "$GB_TMP/GalaxyBridge.iconset" "$GB_ICON"
test -s "$GB_TMP/GalaxyBridge.iconset/icon_512x512@2x.png"

/usr/bin/swift build --package-path "$GB_ROOT" --product GalaxyBridgeMac
GB_BUNDLE="$GB_ROOT/.build/debug/GalaxyBridge_GalaxyBridgeMac.bundle"
test -s "$GB_BUNDLE/PrivacyInfo.xcprivacy"
test -s "$GB_BUNDLE/GalaxyBridge.icns"
for GB_LOCALE_DIR in "$GB_RESOURCES"/*.lproj; do
  GB_LOCALE_NAME=$(basename "$GB_LOCALE_DIR")
  /usr/bin/cmp "$GB_LOCALE_DIR/InfoPlist.strings" "$GB_BUNDLE/$GB_LOCALE_NAME/InfoPlist.strings"
  /usr/bin/cmp "$GB_LOCALE_DIR/Localizable.strings" "$GB_BUNDLE/$GB_LOCALE_NAME/Localizable.strings"
done

for GB_TARGET in GalaxyBridgeInternal GalaxyBridgeAppStore; do
  GB_TARGET_BLOCK="$GB_TMP/$GB_TARGET.yml"
  /usr/bin/awk -v target="  $GB_TARGET:" '
    $0 == target { inside = 1; next }
    inside && /^  [A-Za-z].*:$/ { inside = 0 }
    inside { print }
  ' "$GB_ROOT/macos/project.yml" > "$GB_TARGET_BLOCK"
  /usr/bin/grep -Fq 'path: GalaxyBridgeMac/Resources' "$GB_TARGET_BLOCK"
  /usr/bin/grep -Fq 'path: GalaxyBridgeMac/Assets.xcassets' "$GB_TARGET_BLOCK"
  /usr/bin/grep -Fq 'ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon' "$GB_TARGET_BLOCK"
done

printf 'PASS macOS distribution privacy, icon, and localized plist resources\n'
