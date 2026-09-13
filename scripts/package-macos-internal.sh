#!/usr/bin/env bash
# Public source export: portable ad-hoc build, no private developer keychain.
set -euo pipefail
GB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GB_BUILD_DIR="${GB_BUILD_DIR:-$GB_ROOT/out/macos-arm64-release}"
python3 "$GB_ROOT/scripts/public-build.py" native --build-dir "$GB_BUILD_DIR"
python3 "$GB_ROOT/scripts/public-build.py" macos-app --build-dir "$GB_BUILD_DIR"
