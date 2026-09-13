#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_NATIVE_COMPONENT=media-tests
source "$GB_ROOT/scripts/native-build-env.sh"
if [[ -z "${GB_QUIC_TEST_FIXTURES:-}" ]]; then
    GB_QUIC_TEST_FIXTURES=$(mktemp -d "$GB_BUILD_DIR/media-fixtures.XXXXXX")
    export GB_QUIC_TEST_FIXTURES
    bash "$GB_ROOT/scripts/test-quic-backend.sh" --export-fixtures "$GB_QUIC_TEST_FIXTURES"
fi
for fixture in h264 hevc aac; do
    [[ -f "$GB_QUIC_TEST_FIXTURES/$fixture.stock" ]] || fail "Missing generated fixture: $fixture.stock"
    [[ "$(shasum -a 256 "$GB_QUIC_TEST_FIXTURES/$fixture.stock" | awk '{print $1}')" == "$(cat "$GB_QUIC_TEST_FIXTURES/$fixture.stock.sha256")" ]] || fail "Generated fixture integrity mismatch: $fixture"
done
"$GB_CARGO" test "${GB_CARGO_NETWORK[@]}" --manifest-path "$GB_ROOT/native/galaxybridge-quic-media/Cargo.toml" --target aarch64-apple-darwin "$@" -- --test-threads=1
