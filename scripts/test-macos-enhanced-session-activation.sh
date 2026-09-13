#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_CONTENT="$GB_ROOT/macos/GalaxyBridgeMac/ContentView.swift"

if /usr/bin/grep -Fq '.task(id: device.id) { model.ensureEnhancedSession(for: device) }' "$GB_CONTENT"; then
  printf 'FAIL enhanced activation remains keyed only by stable device ID\n' >&2
  exit 1
fi

/usr/bin/grep -Fq '.task(id: device) { model.ensureEnhancedSessionForPrimaryDemand(for: device) }' "$GB_CONTENT"
printf 'PASS demanded enhanced session reacts to live transport and readiness changes\n'
