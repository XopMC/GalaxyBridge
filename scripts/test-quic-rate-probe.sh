#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_NATIVE_COMPONENT=rate-probe-tests
source "$GB_ROOT/scripts/native-build-env.sh"
GB_MANIFEST="$GB_ROOT/native/galaxybridge-quic/Cargo.toml"
[[ $# == 0 || ( $# == 1 && "$1" == unit-only ) ]] || exit 1
"${RUSTFMT:-$(command -v rustfmt)}" --edition 2021 --check "$GB_ROOT/native/galaxybridge-quic/src/rate_probe.rs" "$GB_ROOT/native/galaxybridge-quic/tests/rate_probe_contract.rs"
"$GB_CARGO" test "${GB_CARGO_NETWORK[@]}" --manifest-path "$GB_MANIFEST" --target aarch64-apple-darwin --lib rate_probe:: -- --test-threads=1 --nocapture
if [[ $# == 0 ]]; then
    source "$GB_ROOT/scripts/prepare-quic-test-library.sh"
    "$GB_CARGO" test "${GB_CARGO_NETWORK[@]}" --manifest-path "$GB_MANIFEST" --target aarch64-apple-darwin --test rate_probe_contract -- --test-threads=1 --nocapture
fi
