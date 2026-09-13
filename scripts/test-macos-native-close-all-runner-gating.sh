#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-close-all-gating.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

GB_RUNNER="$GB_ROOT/scripts/test-macos-native-close-all-command.sh"
GB_SKIP='SKIP foreground native Close All app-wiring integration; set GALAXYBRIDGE_RUN_NATIVE_GUI_TESTS=1 in an interactive macOS session.'
GB_DIRECT_PASS='PASS native SwiftUI-generated Close All routing, forwarding, ownership, veto, and rebinding'
GB_APP_PASS='PASS actual GalaxyBridgeMacApp lifecycle routes generated Close All to both primaries'

expect_contains() {
    GB_EXPECT_FILE=$1
    GB_EXPECT_TEXT=$2
    GB_EXPECT_MESSAGE=$3
    /usr/bin/grep -F "$GB_EXPECT_TEXT" "$GB_EXPECT_FILE" >/dev/null || {
        echo "$GB_EXPECT_MESSAGE" >&2
        exit 1
    }
}

run_success_case() {
    GB_CASE_NAME=$1
    GB_GUI_VALUE=$2
    GB_OUTPUT="$GB_TMP/$GB_CASE_NAME.out"
    if [ "$GB_GUI_VALUE" = unset ]; then
        env -u GALAXYBRIDGE_RUN_NATIVE_GUI_TESTS sh "$GB_RUNNER" >"$GB_OUTPUT" 2>&1
    else
        env GALAXYBRIDGE_RUN_NATIVE_GUI_TESTS="$GB_GUI_VALUE" sh "$GB_RUNNER" >"$GB_OUTPUT" 2>&1
    fi
    expect_contains "$GB_OUTPUT" "$GB_DIRECT_PASS" "$GB_CASE_NAME did not run the original non-activating matrix"
}

run_success_case default unset
expect_contains "$GB_TMP/default.out" "$GB_SKIP" 'default Close All runner did not report the foreground-host SKIP'
if /usr/bin/grep -F "$GB_APP_PASS" "$GB_TMP/default.out" >/dev/null; then
    echo "default Close All runner unexpectedly launched the foreground app host" >&2
    exit 1
fi

run_success_case explicit-zero 0
expect_contains "$GB_TMP/explicit-zero.out" "$GB_SKIP" 'explicit-zero Close All runner did not report the foreground-host SKIP'
if /usr/bin/grep -F "$GB_APP_PASS" "$GB_TMP/explicit-zero.out" >/dev/null; then
    echo "explicit-zero Close All runner unexpectedly launched the foreground app host" >&2
    exit 1
fi

run_success_case explicit-one 1
expect_contains "$GB_TMP/explicit-one.out" "$GB_APP_PASS" 'opted-in Close All runner did not execute the actual-app host'
if /usr/bin/grep -F "$GB_SKIP" "$GB_TMP/explicit-one.out" >/dev/null; then
    echo "opted-in Close All runner unexpectedly skipped the foreground app host" >&2
    exit 1
fi

GB_FAKE_BIN="$GB_TMP/fake-bin"
GB_COMPILER_MARKER="$GB_TMP/compiler-started"
mkdir -p "$GB_FAKE_BIN"
printf '%s\n' '#!/bin/sh' ": > '$GB_COMPILER_MARKER'" 'exit 99' >"$GB_FAKE_BIN/xcrun"
chmod +x "$GB_FAKE_BIN/xcrun"
set +e
PATH="$GB_FAKE_BIN:$PATH" GALAXYBRIDGE_RUN_NATIVE_GUI_TESTS=invalid \
    sh "$GB_RUNNER" >"$GB_TMP/invalid.out" 2>&1
GB_INVALID_STATUS=$?
set -e
[ "$GB_INVALID_STATUS" -eq 2 ] || {
    echo "invalid GUI opt-in must exit 2, got $GB_INVALID_STATUS" >&2
    exit 1
}
expect_contains "$GB_TMP/invalid.out" 'GALAXYBRIDGE_RUN_NATIVE_GUI_TESTS must be 0 or 1.' \
    'invalid GUI opt-in did not emit the required diagnostic'
[ ! -e "$GB_COMPILER_MARKER" ] || {
    echo "invalid GUI opt-in reached the compiler" >&2
    exit 1
}

printf '%s\n' 'PASS Close All runner preserves default/0 GUI skip, explicit-1 opt-in, and early invalid rejection'
