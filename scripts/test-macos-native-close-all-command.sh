#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_RUN_NATIVE_GUI_TESTS=${GALAXYBRIDGE_RUN_NATIVE_GUI_TESTS:-0}
case "$GB_RUN_NATIVE_GUI_TESTS" in
  0|1) ;;
  *)
    printf 'GALAXYBRIDGE_RUN_NATIVE_GUI_TESTS must be 0 or 1.\n' >&2
    exit 2
    ;;
esac

GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-native-close-all.XXXXXX")
GB_APP="$GB_TMP/GalaxyBridgeMacAppWiringCloseAllSpec.app"
GB_APP_EXEC="$GB_APP/Contents/MacOS/GalaxyBridgeMacAppWiringCloseAllSpec"
GB_RESULT="$GB_TMP/result.tsv"
GB_PID_FILE="$GB_TMP/pid.tsv"
GB_RUN_ID=$(basename "$GB_TMP")
GB_HOST_PID=""

owned_host_is_running() {
  [ -n "$GB_HOST_PID" ] || return 1
  kill -0 "$GB_HOST_PID" 2>/dev/null || return 1
  GB_HOST_COMMAND=$(ps -ww -p "$GB_HOST_PID" -o command= 2>/dev/null || true)
  case "$GB_HOST_COMMAND" in
    "$GB_APP_EXEC"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  if owned_host_is_running; then
    kill -TERM "$GB_HOST_PID" 2>/dev/null || true
    GB_STOP_TICKS=0
    while owned_host_is_running && [ "$GB_STOP_TICKS" -lt 20 ]; do
      sleep 0.05
      GB_STOP_TICKS=$((GB_STOP_TICKS + 1))
    done
    if owned_host_is_running; then
      kill -KILL "$GB_HOST_PID" 2>/dev/null || true
    fi
  fi
  rm -rf -- "$GB_TMP"
}
trap cleanup EXIT HUP INT TERM

run_app_wiring_host() {
  mkdir -p "$GB_APP/Contents/MacOS"
  xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -framework AppKit \
    -framework SwiftUI \
    "$GB_ROOT/macos/GalaxyBridgeMac/MirrorWindowGeometry.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/NativePrimaryCloseCommandRouter.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/NativeCloseAllCommandRouter.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/DeviceMirrorWindowPresenter.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationLanguageLayout.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/GalaxyBridgeMacApp.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/RecordingRegistry.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/GalaxyBridgeMacAppWiringCloseAllSpec.swift" \
    -o "$GB_APP_EXEC"

  cat > "$GB_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>GalaxyBridgeMacAppWiringCloseAllSpec</string>
  <key>CFBundleIdentifier</key>
  <string>com.galaxybridge.tests.native-close-all-app-wiring</string>
  <key>CFBundleName</key>
  <string>Native Close All App Wiring Test</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  /usr/bin/open -n "$GB_APP" --args \
    --task5k-run-id "$GB_RUN_ID" \
    --task5k-result "$GB_RESULT" \
    --task5k-pid "$GB_PID_FILE"

  GB_WAIT_TICKS=0
  while [ "$GB_WAIT_TICKS" -lt 400 ]; do
    if [ -f "$GB_PID_FILE" ] && [ -z "$GB_HOST_PID" ]; then
      IFS="$(printf '\t')" read -r GB_PID_TOKEN GB_PID_VALUE < "$GB_PID_FILE" || true
      case "$GB_PID_VALUE" in
        ''|*[!0-9]*) ;;
        *)
          if [ "$GB_PID_TOKEN" = "$GB_RUN_ID" ]; then
            GB_HOST_PID=$GB_PID_VALUE
          fi
          ;;
      esac
    fi
    [ -f "$GB_RESULT" ] && break
    if [ -n "$GB_HOST_PID" ] && ! kill -0 "$GB_HOST_PID" 2>/dev/null; then
      printf 'native Close All app host exited without a complete result for %s\n' "$GB_RUN_ID" >&2
      exit 1
    fi
    sleep 0.05
    GB_WAIT_TICKS=$((GB_WAIT_TICKS + 1))
  done

  [ -n "$GB_HOST_PID" ] || {
    printf 'native Close All app host did not publish its unique PID for %s\n' "$GB_RUN_ID" >&2
    exit 1
  }
  [ -f "$GB_RESULT" ] || {
    printf 'native Close All app host timed out without a complete result for %s\n' "$GB_RUN_ID" >&2
    exit 1
  }

  IFS="$(printf '\t')" read -r GB_RESULT_TOKEN GB_RESULT_STATUS GB_RESULT_MESSAGE < "$GB_RESULT" || {
    printf 'native Close All app host published an unreadable result for %s\n' "$GB_RUN_ID" >&2
    exit 1
  }
  [ "$GB_RESULT_TOKEN" = "$GB_RUN_ID" ] || {
    printf 'native Close All app host published a stale result identity\n' >&2
    exit 1
  }
  case "$GB_RESULT_STATUS" in
    PASS) printf '%s\n' "$GB_RESULT_MESSAGE" ;;
    FAIL)
      printf '%s\n' "$GB_RESULT_MESSAGE" >&2
      exit 1
      ;;
    *)
      printf 'native Close All app host published an incomplete result status\n' >&2
      exit 1
      ;;
  esac
}

if [ "$GB_RUN_NATIVE_GUI_TESTS" = 1 ]; then
  run_app_wiring_host
else
  printf 'SKIP foreground native Close All app-wiring integration; set GALAXYBRIDGE_RUN_NATIVE_GUI_TESTS=1 in an interactive macOS session.\n'
fi

set -- -D TASK5K_PRESENTER_STANDINS
if [ "${TASK5K_FORCE_RED:-0}" = "1" ]; then
  set -- "$@" -D TASK5K_RED
fi
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -framework AppKit \
  -framework SwiftUI \
  "$GB_ROOT/macos/GalaxyBridgeMac/MirrorWindowGeometry.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/NativeCloseAllCommandRouter.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/DeviceMirrorWindowPresenter.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationLanguageLayout.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/PrimaryScreenDemandRegistry.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/NativeCloseAllCommandSpec.swift" \
  "$@" \
  -o "$GB_TMP/NativeCloseAllCommandSpec"

"$GB_TMP/NativeCloseAllCommandSpec"
