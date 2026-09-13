#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_NATIVE_COMPONENT=transport-tests
source "$GB_ROOT/scripts/native-build-env.sh"
GB_QUIC_RUSTFMT="${RUSTFMT:-$(command -v rustfmt || true)}"
[[ -x "$GB_QUIC_RUSTFMT" ]] || fail 'Install rustfmt or set RUSTFMT.'
GB_MANIFEST="$GB_ROOT/native/galaxybridge-quic/Cargo.toml"
mkdir -p "$GB_BUILD_DIR/quic-evidence"
"$GB_QUIC_RUSTFMT" --edition 2021 --check "$GB_ROOT"/native/galaxybridge-quic/src/*.rs "$GB_ROOT"/native/galaxybridge-quic/src/bin/*.rs "$GB_ROOT"/native/galaxybridge-quic/tests/*.rs
"$GB_CARGO" metadata "${GB_CARGO_NETWORK[@]}" --format-version 1 --manifest-path "$GB_MANIFEST" > "$GB_BUILD_DIR/quic-evidence/dependencies.json"
"$GB_CARGO" tree "${GB_CARGO_NETWORK[@]}" --manifest-path "$GB_MANIFEST" > "$GB_BUILD_DIR/quic-evidence/dependency-tree.txt"
source "$GB_ROOT/scripts/prepare-quic-test-library.sh"
"$GB_CARGO" test "${GB_CARGO_NETWORK[@]}" --manifest-path "$GB_MANIFEST" --target aarch64-apple-darwin -- --test-threads=1
"$CARGO_TARGET_DIR/aarch64-apple-darwin/debug/gb-quic-probe" --self-test
printf '%s\n' 'PASS QUIC locked graph, formatting, codecs, real authenticated UDP, negative TLS, lifecycle and admission tests.'
