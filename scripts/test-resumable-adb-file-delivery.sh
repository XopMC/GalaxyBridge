#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TARGET="$GB_ROOT/.build/file-receiver-fixture"
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-file-delivery.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
GB_CARGO=${GB_CARGO:-/opt/homebrew/bin/cargo}
"$GB_CARGO" test --locked --manifest-path "$GB_ROOT/native/galaxybridge-file-receiver/Cargo.toml" --target-dir "$GB_TARGET"
"$GB_CARGO" build --locked --manifest-path "$GB_ROOT/native/galaxybridge-file-receiver/Cargo.toml" --target-dir "$GB_TARGET"
xcrun swiftc "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ResumableADBFileDelivery.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ResumableADBFileDeliverySpec.swift" -o "$GB_TMP/spec"
"$GB_TMP/spec" "$GB_TARGET/debug/galaxybridge-file-receiver"
