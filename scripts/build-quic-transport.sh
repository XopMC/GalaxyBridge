#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_NATIVE_COMPONENT=transport
source "$GB_ROOT/scripts/native-build-env.sh"
GB_OUT="${GB_OUTPUT_DIR:-$GB_BUILD_DIR/quic-transport}"
GB_MANIFEST="$GB_ROOT/native/galaxybridge-quic/Cargo.toml"
mkdir -p "$GB_OUT"
for target in aarch64-apple-darwin aarch64-linux-android; do
    suffix=macos-arm64
    if [[ "$target" == aarch64-linux-android ]]; then prepare_android; suffix=android-arm64; fi
    "$GB_CARGO" build "${GB_CARGO_NETWORK[@]}" --release --manifest-path "$GB_MANIFEST" --target "$target" --lib --bin gb-quic-probe
    cp "$CARGO_TARGET_DIR/$target/release/gb-quic-probe" "$GB_OUT/gb-quic-probe-$suffix"
    cp "$CARGO_TARGET_DIR/$target/release/libgalaxybridge_quic.a" "$GB_OUT/libgalaxybridge_quic-$suffix.a"
done
inspect_android "$GB_OUT/gb-quic-probe-android-arm64" "$GB_OUT/android-elf.txt"
(cd "$GB_OUT" && shasum -a 256 gb-quic-probe-* libgalaxybridge_quic-*.a > SHA256SUMS)
printf 'BUILD_DIR=%s\n' "$GB_OUT"
