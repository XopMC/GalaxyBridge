#!/usr/bin/env bash
# Compile both sides of the ABI contract from this checkout and exercise real FFI.
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$GB_ROOT/scripts/test-quic-backend.sh" --ffi
