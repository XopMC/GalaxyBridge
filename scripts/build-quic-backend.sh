#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_NATIVE_COMPONENT=backend
source "$GB_ROOT/scripts/native-build-env.sh"
case "${1:-all}" in all|android|mac) GB_MODE="${1:-all}";; *) fail 'Usage: build-quic-backend.sh [all|android|mac] [--qa]';; esac
GB_FEATURES=(--no-default-features)
GB_SUFFIX=""
if [[ "${2:-}" == --qa ]]; then GB_FEATURES=(--features qa); GB_SUFFIX=-qa; elif [[ $# -gt 1 ]]; then fail 'Unknown option'; fi
[[ $# -le 2 ]] || fail 'Too many arguments'
GB_OUT="${GB_OUTPUT_DIR:-$GB_BUILD_DIR/quic-backend}"
mkdir -p "$GB_OUT"
GB_MANIFEST="$GB_ROOT/native/galaxybridge-quic-backend/Cargo.toml"
GB_PRODUCER_JAR="${GB_PRODUCER_JAR:-$GB_ROOT/build/native/scrcpy/scrcpy-server-4.1-gb-sync.1}"
[[ -f "$GB_PRODUCER_JAR" ]] || fail 'Build scrcpy first, then set GB_PRODUCER_JAR to its enhanced source-built server.'
export GB_PRODUCER_SHA256="$(shasum -a 256 "$GB_PRODUCER_JAR" | awk '{print $1}')"
printf '%s\n' "$GB_PRODUCER_SHA256" > "$GB_OUT/PRODUCER_SHA256.txt"

if [[ "$GB_MODE" != android ]]; then
    "$GB_CARGO" build "${GB_CARGO_NETWORK[@]}" --release "${GB_FEATURES[@]}" --manifest-path "$GB_MANIFEST" --target aarch64-apple-darwin
    cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/gb-quic-backend" "$GB_OUT/gb-quic-backend-macos-arm64$GB_SUFFIX"
    cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/libgalaxybridge_quic_backend.a" "$GB_OUT/libgalaxybridge_quic_backend-macos-arm64$GB_SUFFIX.a"
    "$GB_OUT/gb-quic-backend-macos-arm64$GB_SUFFIX" --version
    otool -L "$GB_OUT/gb-quic-backend-macos-arm64$GB_SUFFIX" > "$GB_OUT/macos-libraries$GB_SUFFIX.txt"
fi
if [[ "$GB_MODE" != mac ]]; then
    prepare_android
    "$GB_CARGO" build "${GB_CARGO_NETWORK[@]}" --release "${GB_FEATURES[@]}" --manifest-path "$GB_MANIFEST" --target aarch64-linux-android
    cp "$CARGO_TARGET_DIR/aarch64-linux-android/release/gb-quic-backend" "$GB_OUT/gb-quic-backend-android-arm64$GB_SUFFIX"
    inspect_android "$GB_OUT/gb-quic-backend-android-arm64$GB_SUFFIX" "$GB_OUT/android-elf$GB_SUFFIX.txt"
fi
printf 'BUILD_DIR=%s\n' "$GB_OUT"
