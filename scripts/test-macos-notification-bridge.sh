#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-notification-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
  -framework CryptoKit \
  -framework UserNotifications \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/MacNotificationBridgeModelsStub.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Notifications/MacNotificationBridge.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/MacNotificationBridgeSpec.swift" \
  -o "$GB_TMP/MacNotificationBridgeSpec"

"$GB_TMP/MacNotificationBridgeSpec"
