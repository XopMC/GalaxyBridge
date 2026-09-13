#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-native-miniaturize.XXXXXX")
GB_APP="$GB_TMP/NativeMiniaturizeCommandSpec.app"
GB_APP_EXEC="$GB_APP/Contents/MacOS/NativeMiniaturizeCommandSpec"
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

set --
case "${TASK5L_NEGATIVE_ORACLE:-}" in
    "") ;;
    key-window) set -- -D TASK5L_FORCE_WRONG_KEY_WINDOW ;;
    delayed-callback) set -- -D TASK5L_INJECT_DELAYED_DUPLICATE_CALLBACK ;;
    *)
        echo "unknown TASK5L_NEGATIVE_ORACLE: $TASK5L_NEGATIVE_ORACLE" >&2
        exit 2
        ;;
esac

GB_GEOMETRY_SOURCE=${TASK5L_GEOMETRY_SOURCE:-$GB_ROOT/macos/GalaxyBridgeMac/MirrorWindowGeometry.swift}
[ -f "$GB_GEOMETRY_SOURCE" ] || {
    echo "missing Task5l geometry source: $GB_GEOMETRY_SOURCE" >&2
    exit 2
}

mkdir -p "$GB_APP/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -framework AppKit \
    -framework SwiftUI \
    "$GB_GEOMETRY_SOURCE" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/NativeMiniaturizeCommandSpec.swift" \
    "$@" \
    -o "$GB_APP_EXEC"

cat > "$GB_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NativeMiniaturizeCommandSpec</string>
    <key>CFBundleIdentifier</key>
    <string>com.galaxybridge.tests.native-miniaturize</string>
    <key>CFBundleName</key>
    <string>Native Minimize Test</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/open -n "$GB_APP" --args \
    --task5l-run-id "$GB_RUN_ID" \
    --task5l-result "$GB_RESULT" \
    --task5l-pid "$GB_PID_FILE"

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
        echo "native Minimize host exited without a complete result for $GB_RUN_ID" >&2
        exit 1
    fi
    sleep 0.05
    GB_WAIT_TICKS=$((GB_WAIT_TICKS + 1))
done

[ -n "$GB_HOST_PID" ] || {
    echo "native Minimize host did not publish its unique PID for $GB_RUN_ID" >&2
    exit 1
}
[ -f "$GB_RESULT" ] || {
    echo "native Minimize host timed out without a complete result for $GB_RUN_ID" >&2
    exit 1
}

IFS="$(printf '\t')" read -r GB_RESULT_TOKEN GB_RESULT_STATUS GB_RESULT_MESSAGE < "$GB_RESULT" || {
    echo "native Minimize host published an unreadable result for $GB_RUN_ID" >&2
    exit 1
}
[ "$GB_RESULT_TOKEN" = "$GB_RUN_ID" ] || {
    echo "native Minimize host published a stale result identity" >&2
    exit 1
}
case "$GB_RESULT_STATUS" in
    PASS)
        echo "$GB_RESULT_MESSAGE"
        ;;
    FAIL)
        echo "$GB_RESULT_MESSAGE" >&2
        exit 1
        ;;
    *)
        echo "native Minimize host published an incomplete result status" >&2
        exit 1
        ;;
esac
