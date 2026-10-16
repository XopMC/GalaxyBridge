#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_PROTOC="${PROTOC_PATH:-/opt/homebrew/bin/protoc}"

mkdir -p "$GB_ROOT/android/companion-protocol/src/main/java"
"$GB_PROTOC" \
  --proto_path="$GB_ROOT/protocol" \
  --java_out="lite:$GB_ROOT/android/companion-protocol/src/main/java" \
  "$GB_ROOT/protocol/galaxybridge.proto"

# protoc emits spaces on otherwise empty lines for some message accessors.
# Keep checked-in generated output deterministic and diff-check clean.
python3 - "$GB_ROOT/android/companion-protocol/src/main/java" <<'PY_NORMALIZE'
from pathlib import Path
import sys
for generated in Path(sys.argv[1]).rglob("*.java"):
    source = generated.read_text()
    normalized = "\n".join(line.rstrip() for line in source.splitlines()).rstrip() + "\n"
    if normalized != source:
        generated.write_text(normalized)
PY_NORMALIZE

"$GB_PROTOC" \
  --proto_path="$GB_ROOT/protocol" \
  --descriptor_set_out=/tmp/galaxybridge-protocol.pb \
  "$GB_ROOT/protocol/galaxybridge.proto"
