#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(/usr/bin/xcode-select -p 2>/dev/null || true)" == *CommandLineTools* ]]; then
  echo "Full Xcode is required to generate and build the Camera Extension project." >&2
  exit 2
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Install XcodeGen from its official release or Homebrew, then rerun this script." >&2
  exit 3
fi

cd "$GB_ROOT/macos"
xcodegen generate --spec project.yml
