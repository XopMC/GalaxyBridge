#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-camera-app-group.XXXXXX")"
trap '/bin/rm -rf -- "$GB_TMP"' EXIT

xcrun swiftc \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraAppGroupIdentifier.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/CameraAppGroupIdentifierSpec.swift" \
  -o "$GB_TMP/CameraAppGroupIdentifierSpec"

"$GB_TMP/CameraAppGroupIdentifierSpec"

if ! /usr/bin/cmp -s \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/CameraAppGroupIdentifier.swift" \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtension/CameraAppGroupIdentifier.swift"; then
  echo "Host and Camera Extension App Group resolvers have drifted." >&2
  exit 1
fi

GB_EXPECTED='$(TeamIdentifierPrefix)group.com.xopmc.GalaxyBridge'
GB_EXPECTED_MACH_SERVICE="${GB_EXPECTED}.CameraExtension"
GB_HOST=$(/usr/libexec/PlistBuddy -c 'Print :GalaxyBridgeAppGroupIdentifier' "$GB_ROOT/macos/GalaxyBridgeMac/Info.plist")
GB_EXTENSION=$(/usr/libexec/PlistBuddy -c 'Print :GalaxyBridgeAppGroupIdentifier' "$GB_ROOT/macos/GalaxyBridgeCameraExtension/Info.plist")

if [[ "$GB_HOST" != "$GB_EXPECTED" || "$GB_EXTENSION" != "$GB_EXPECTED" ]]; then
  echo "Host and Camera Extension must carry the same expandable App Group identifier." >&2
  exit 1
fi

for GB_ENTITLEMENTS in \
  "$GB_ROOT/macos/Entitlements/GalaxyBridge-Internal.entitlements" \
  "$GB_ROOT/macos/Entitlements/GalaxyBridge-AppStore.entitlements" \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtension/GalaxyBridgeCameraExtension.entitlements"; do
  GB_GROUP=$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:0' "$GB_ENTITLEMENTS")
  if [[ "$GB_GROUP" != "$GB_EXPECTED" ]]; then
    echo "$GB_ENTITLEMENTS does not share the Camera App Group identifier." >&2
    exit 1
  fi
done

for GB_HOST_ENTITLEMENTS in \
  "$GB_ROOT/macos/Entitlements/GalaxyBridge-Internal.entitlements" \
  "$GB_ROOT/macos/Entitlements/GalaxyBridge-AppStore.entitlements"; do
  if [[ "$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.developer.system-extension.install' "$GB_HOST_ENTITLEMENTS")" != "true" ]]; then
    echo "$GB_HOST_ENTITLEMENTS cannot install the Camera system extension." >&2
    exit 1
  fi
done

if [[ "$(/usr/libexec/PlistBuddy -c \
  'Print :com.apple.security.app-sandbox' \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtension/GalaxyBridgeCameraExtension.entitlements")" != "true" ]]; then
  echo "Camera Extension must be sandboxed." >&2
  exit 1
fi

GB_MACH_SERVICE=$(/usr/libexec/PlistBuddy -c \
  'Print :CMIOExtensionMachServiceName' \
  "$GB_ROOT/macos/GalaxyBridgeCameraExtension/Info.plist")
if [[ "$GB_MACH_SERVICE" != "$GB_EXPECTED_MACH_SERVICE" ]]; then
  echo "Camera Extension Mach service must derive from the shared App Group." >&2
  exit 1
fi

GB_EMBED_COUNT=$(/usr/bin/grep -c -- '- target: GalaxyBridgeCameraExtension' \
  "$GB_ROOT/macos/project.yml")
if [[ "$GB_EMBED_COUNT" -ne 2 ]] || \
   ! /usr/bin/grep -q 'type: system-extension' "$GB_ROOT/macos/project.yml" || \
   ! /usr/bin/grep -q \
     'path: GalaxyBridgeCameraExtension/GalaxyBridgeCameraExtension.entitlements' \
     "$GB_ROOT/macos/project.yml"; then
  echo "Both macOS products must embed the entitlement-backed Camera system extension." >&2
  exit 1
fi

if /usr/bin/grep -R -n -F \
  'containerURL(forSecurityApplicationGroupIdentifier: "group.com.xopmc.GalaxyBridge")' \
  "$GB_ROOT/macos/GalaxyBridgeMac" "$GB_ROOT/macos/GalaxyBridgeCameraExtension"; then
  echo "Camera ring code still passes an identifier that cannot match the expanded macOS entitlement." >&2
  exit 1
fi

echo "Camera App Group identifier contract passed."
