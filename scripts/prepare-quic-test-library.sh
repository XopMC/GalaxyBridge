#!/usr/bin/env bash
# Sourced after native-build-env.sh. Use Cargo's current compiler-artifact event,
# never a directory glob: old profiles legitimately leave several rlibs in deps.
GB_TEST_ARTIFACTS=$(mktemp "$GB_BUILD_DIR/quic-test-artifacts.XXXXXX")
"$GB_CARGO" test "${GB_CARGO_NETWORK[@]}" --manifest-path "$GB_MANIFEST" \
    --target aarch64-apple-darwin --no-run --message-format=json > "$GB_TEST_ARTIFACTS"
GB_QUIC_TEST_RLIB=$(python3 - "$GB_TEST_ARTIFACTS" "$GB_MANIFEST" "$CARGO_TARGET_DIR" <<'PY'
import json
from pathlib import Path
import sys

messages, manifest, target = map(Path, sys.argv[1:])
manifest = manifest.resolve(strict=True)
deps = (target / 'aarch64-apple-darwin/debug/deps').resolve(strict=True)
artifacts = set()
for line in messages.read_text().splitlines():
    event = json.loads(line)
    if event.get('reason') != 'compiler-artifact':
        continue
    if Path(event['manifest_path']).resolve() != manifest:
        continue
    if event.get('target', {}).get('name') != 'galaxybridge_quic':
        continue
    for filename in event.get('filenames', []):
        path = Path(filename)
        if path.suffix != '.rlib':
            continue
        path = path.resolve(strict=True)
        if path.parent != deps or not path.is_file() or not path.name.startswith('libgalaxybridge_quic-'):
            sys.exit('Cargo reported an unexpected QUIC test library path')
        artifacts.add(path)
if len(artifacts) != 1:
    sys.exit(f'Expected one current Cargo QUIC rlib artifact, found {len(artifacts)}')
print(artifacts.pop())
PY
)
export GB_QUIC_TEST_RLIB
printf 'QUIC test library from current Cargo build: %s\n' "$GB_QUIC_TEST_RLIB"
