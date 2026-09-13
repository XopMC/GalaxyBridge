#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-notification-auth.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
  -framework CryptoKit \
  -framework UserNotifications \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/MacNotificationBridgeModelsStub.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Notifications/MacNotificationBridge.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Notifications/MacNotificationAuthorizationPresentation.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/MacNotificationAuthorizationPresentationSpec.swift" \
  -o "$GB_TMP/MacNotificationAuthorizationPresentationSpec"

"$GB_TMP/MacNotificationAuthorizationPresentationSpec"
