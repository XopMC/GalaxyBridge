#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_PROTOC="${PROTOC_PATH:-/opt/homebrew/bin/protoc}"

mkdir -p "$GB_ROOT/android/companion-protocol/src/main/java"
"$GB_PROTOC" \
  --proto_path="$GB_ROOT/protocol" \
  --java_out="lite:$GB_ROOT/android/companion-protocol/src/main/java" \
  "$GB_ROOT/protocol/galaxybridge.proto"

"$GB_PROTOC" \
  --proto_path="$GB_ROOT/protocol" \
  --descriptor_set_out=/tmp/galaxybridge-protocol.pb \
  "$GB_ROOT/protocol/galaxybridge.proto"
