#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_AOSP_ROOT="${AOSP_ROOT:-${1:-}}"
GB_OUTPUT_ROOT="${2:-$GB_ROOT/third_party/aosp-adb}"
GB_AOSP_TAG="android-17.0.0_r1"

if [[ -z "$GB_AOSP_ROOT" || ! -f "$GB_AOSP_ROOT/build/envsetup.sh" ]]; then
  echo "usage: AOSP_ROOT=/path/to/aosp $0 [AOSP_ROOT] [OUTPUT_DIRECTORY]" >&2
  exit 2
fi
if [[ ! -d "$GB_AOSP_ROOT/.repo" ]]; then
  echo "A full repo checkout of AOSP is required; a standalone adb repository is insufficient." >&2
  exit 3
fi

GB_ADB_TAG="$(git -C "$GB_AOSP_ROOT/packages/modules/adb" describe --tags --exact-match 2>/dev/null || true)"
if [[ "$GB_ADB_TAG" != "$GB_AOSP_TAG" ]]; then
  echo "packages/modules/adb must be checked out at $GB_AOSP_TAG (found: ${GB_ADB_TAG:-unverified})." >&2
  exit 4
fi

(
  cd "$GB_AOSP_ROOT"
  source build/envsetup.sh >/dev/null
  m adb
)

GB_ADB_BINARY="$(find "$GB_AOSP_ROOT/out/host" -type f -path '*/bin/adb' -perm -111 -print -quit)"
if [[ -z "$GB_ADB_BINARY" ]]; then
  echo "AOSP build completed but no host adb executable was found." >&2
  exit 5
fi
if [[ "$(uname -m)" == "arm64" ]] && ! /usr/bin/file "$GB_ADB_BINARY" | /usr/bin/grep -q 'arm64'; then
  echo "The produced adb does not contain an arm64 slice." >&2
  exit 6
fi

/bin/mkdir -p "$GB_OUTPUT_ROOT"
/usr/bin/install -m 0755 "$GB_ADB_BINARY" "$GB_OUTPUT_ROOT/adb"
/bin/cp "$GB_AOSP_ROOT/packages/modules/adb/NOTICE" "$GB_OUTPUT_ROOT/NOTICE"
(
  cd "$GB_OUTPUT_ROOT"
  /usr/bin/shasum -a 256 adb NOTICE > SHA256SUMS
)
printf 'Built AOSP adb from %s\nArtifact: %s\n' "$GB_AOSP_TAG" "$GB_OUTPUT_ROOT/adb"
