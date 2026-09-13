#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_OUTPUT="${1:-$GB_ROOT/GalaxyBridge-Diagnostics.zip}"
GB_TEMP_ROOT="$(/usr/bin/mktemp -d -t galaxybridge-diagnostics)"
trap '/bin/rm -rf "$GB_TEMP_ROOT"' EXIT

redact() {
  /usr/bin/sed -E \
    -e 's#/Users/[^/[:space:]]+#/Users/<redacted>#g' \
    -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<email>/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g' \
    -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid>/g' \
    -e 's/[0-9A-Fa-f]{64}/<sha256>/g'
}

{
  printf 'GalaxyBridge diagnostic snapshot\n'
  /usr/bin/sw_vers
  printf 'architecture: '
  /usr/bin/uname -m
  printf 'swift: '
  /usr/bin/swift --version 2>&1 | /usr/bin/head -1
  printf 'xcode-select: '
  /usr/bin/xcode-select -p 2>&1 || true
  printf 'java: '
  /usr/bin/java -version 2>&1 | /usr/bin/head -1 || true
  if [[ -x "$GB_ROOT/third_party/aosp-adb/adb" ]]; then
    "$GB_ROOT/third_party/aosp-adb/adb" version 2>&1 || true
  elif [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
    "$HOME/Library/Android/sdk/platform-tools/adb" version 2>&1 || true
  fi
} | redact > "$GB_TEMP_ROOT/environment.txt"

(
  cd "$GB_ROOT"
  git status --short 2>&1 || true
) | redact > "$GB_TEMP_ROOT/repository-status.txt"

(
  cd "$GB_ROOT/third_party/scrcpy"
  /usr/bin/shasum -a 256 -c SHA256SUMS 2>&1 || true
) | redact > "$GB_TEMP_ROOT/scrcpy-integrity.txt"

COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$GB_TEMP_ROOT" "$GB_OUTPUT"
printf 'Created redacted diagnostic archive: %s\n' "$GB_OUTPUT"
