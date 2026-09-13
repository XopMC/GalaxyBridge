#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_PACKAGE_SCRIPT="$GB_ROOT/scripts/package-macos-internal.sh"

if ! /usr/bin/grep -F -- '--configuration release' "$GB_PACKAGE_SCRIPT" >/dev/null; then
  echo "Internal package must build the optimized release product." >&2
  exit 1
fi
if ! /usr/bin/grep -F -- '"$GB_SWIFT_SCRATCH/release/GalaxyBridgeMac"' "$GB_PACKAGE_SCRIPT" >/dev/null; then
  echo "Internal package must copy the optimized release executable." >&2
  exit 1
fi
if ! /usr/bin/grep -F -- 'GB_RESOURCE_BUNDLE="$GB_SWIFT_SCRATCH/release/GalaxyBridge_GalaxyBridgeMac.bundle"' "$GB_PACKAGE_SCRIPT" >/dev/null; then
  echo "Internal package must copy the release resource bundle." >&2
  exit 1
fi
if /usr/bin/grep -F -- '.build/debug/GalaxyBridgeMac' "$GB_PACKAGE_SCRIPT" >/dev/null; then
  echo "Internal package still references a debug executable." >&2
  exit 1
fi

echo "macOS internal optimized package contract passed."
