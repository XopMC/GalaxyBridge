#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ANDROID="$ROOT/android"
GRADLE="$ANDROID/gradlew"

fail() {
  echo "android direct release contract failed: $*" >&2
  exit 1
}

run_without_signing() {
  env -u GB_ANDROID_DIRECT_KEYSTORE \
    -u GB_ANDROID_DIRECT_KEYSTORE_PASSWORD \
    -u GB_ANDROID_DIRECT_KEY_ALIAS \
    -u GB_ANDROID_DIRECT_KEY_PASSWORD \
    "$GRADLE" --no-daemon "$@"
}

cd "$ANDROID"

run_without_signing :app:tasks --all >/dev/null ||
  fail "Gradle model does not configure without direct release credentials"

run_without_signing :app:compileDirectDebugKotlin :app:testDirectDebugUnitTest ||
  fail "direct debug compilation or unit tests failed"

failure_log=$(mktemp "${TMPDIR:-/tmp}/galaxybridge-direct-release.XXXXXX")
trap 'rm -f "$failure_log"' EXIT HUP INT TERM

if run_without_signing :app:assembleDirectRelease >"$failure_log" 2>&1; then
  fail "qualified direct release unexpectedly succeeded without signing credentials"
fi
grep -q "GB_ANDROID_DIRECT_KEYSTORE" "$failure_log" ||
  fail "qualified direct release failure did not explain the required signing inputs"

if run_without_signing aDR >"$failure_log" 2>&1; then
  fail "abbreviated direct release unexpectedly succeeded without signing credentials"
fi
grep -q "GB_ANDROID_DIRECT_KEYSTORE" "$failure_log" ||
  fail "abbreviated direct release failure did not explain the required signing inputs"

echo "Android direct release contract passed"
