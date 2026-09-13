#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_SERIAL="${1:?usage: hardware-smoke.sh ADB_SERIAL [APK]}"
GB_APK="${2:-$GB_ROOT/android/app/build/outputs/apk/internal/debug/app-internal-debug.apk}"
GB_ADB="${ADB_PATH:-$HOME/Library/Android/sdk/platform-tools/adb}"

if [[ ! -x "$GB_ADB" || ! -f "$GB_APK" ]]; then
  echo "adb or internal APK is missing; run local verification before the hardware gate." >&2
  exit 2
fi
if ! "$GB_ADB" devices | /usr/bin/awk 'NR > 1 && $2 == "device" { print $1 }' | /usr/bin/grep -Fxq "$GB_SERIAL"; then
  echo "Authorized device $GB_SERIAL is not connected." >&2
  exit 3
fi

"$GB_ADB" -s "$GB_SERIAL" install -r "$GB_APK"
"$GB_ADB" -s "$GB_SERIAL" shell am force-stop com.xopmc.galaxybridge.internal
"$GB_ADB" -s "$GB_SERIAL" logcat -c
"$GB_ADB" -s "$GB_SERIAL" shell am start -W -n com.xopmc.galaxybridge.internal/com.xopmc.galaxybridge.MainActivity

GB_TARGET_SDK="$("$GB_ADB" -s "$GB_SERIAL" shell dumpsys package com.xopmc.galaxybridge.internal \
  | /usr/bin/sed -n 's/.*targetSdk=\([0-9][0-9]*\).*/\1/p' \
  | /usr/bin/head -1 \
  | /usr/bin/tr -d '\r')"
if [[ "${GB_TARGET_SDK:-0}" -ge 37 ]]; then
  if ! "$GB_ADB" -s "$GB_SERIAL" shell dumpsys package com.xopmc.galaxybridge.internal \
    | /usr/bin/grep -Fq 'android.permission.ACCESS_LOCAL_NETWORK'; then
    echo "API 37 build does not declare android.permission.ACCESS_LOCAL_NETWORK." >&2
    exit 4
  fi
fi

GB_PROCESS="$("$GB_ADB" -s "$GB_SERIAL" shell pidof com.xopmc.galaxybridge.internal | /usr/bin/tr -d '\r')"
if [[ -z "$GB_PROCESS" ]]; then
  echo "GalaxyBridge process exited during cold launch." >&2
  exit 5
fi
if "$GB_ADB" -s "$GB_SERIAL" logcat -d -v brief --pid="$GB_PROCESS" \
  | /usr/bin/grep -Fq 'SecurityException: Missing local network permission'; then
  echo "GalaxyBridge attempted LAN access before Android granted local-network access." >&2
  exit 6
fi
printf 'APK installed and launched. Complete Android consent steps manually; system approvals are intentionally not automated.\n'
