#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

GALAXYBRIDGE_PROBE_SKIP_FINALIZE=1 \
GALAXYBRIDGE_PROBE_RECOVER_PARTITION=1 \
  "$GB_ROOT/scripts/test-internal-keychain-rebuild.sh"

echo "Internal Keychain partition recovery regression passed."
