#!/usr/bin/env bash
# Shared source-build environment. Callers set GB_ROOT before sourcing.
fail() { printf 'Native build: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'macOS arm64 is required.'
GB_BUILD_DIR="${GB_BUILD_DIR:-$GB_ROOT/build/native}"
mkdir -p "$GB_BUILD_DIR"
GB_BUILD_DIR="$(cd "$GB_BUILD_DIR" && pwd)"
GB_CARGO="${CARGO:-$(command -v cargo || true)}"
[[ -x "$GB_CARGO" ]] || fail 'Install Rust 1.92 or newer (cargo and rustc), including aarch64-linux-android.'
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$GB_BUILD_DIR/cargo-target-${GB_NATIVE_COMPONENT:-native}}"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-2}"
export LIBCLANG_PATH="${LIBCLANG_PATH:-$(xcrun --find clang | sed 's|/bin/clang$|/lib|')}"
# Cargo.lock pins registry sources and checksums; vendored quiche is in this tree.
GB_CARGO_NETWORK=(--locked)
[[ "${GB_OFFLINE:-0}" != 1 ]] || GB_CARGO_NETWORK+=(--offline)
prepare_android() {
    local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
    export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$sdk/ndk/29.0.14206865}"
    GB_NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
    [[ -x "$GB_NDK_BIN/aarch64-linux-android31-clang" ]] || fail 'Set ANDROID_NDK_HOME to Android NDK r29 (SDK Manager: ndk;29.0.14206865).'
    grep -Eq '^Pkg.Revision = 29\.0\.14206865' "$ANDROID_NDK_HOME/source.properties" || fail 'NDK r29 29.0.14206865 is required.'
    local toolchain="$GB_BUILD_DIR/android-api31.cmake"
    printf '%s\n' 'set(ANDROID_ABI arm64-v8a)' 'set(ANDROID_PLATFORM android-31)' 'set(ANDROID_STL c++_static)' 'include("$ENV{ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake")' > "$toolchain"
    export CMAKE_TOOLCHAIN_FILE_aarch64_linux_android="$toolchain"
    export CC_aarch64_linux_android="$GB_NDK_BIN/aarch64-linux-android31-clang"
    export CXX_aarch64_linux_android="$GB_NDK_BIN/aarch64-linux-android31-clang++"
    export AR_aarch64_linux_android="$GB_NDK_BIN/llvm-ar"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$GB_NDK_BIN/aarch64-linux-android31-clang"
    export BORING_BSSL_RUST_CPPLIB_aarch64_linux_android=static=c++_static
    local link="$GB_BUILD_DIR/android-cxx-link"
    mkdir -p "$link"
    cp "$GB_NDK_BIN/../sysroot/usr/lib/aarch64-linux-android/"{libc++_static.a,libc++abi.a} "$link/"
    # Restrict -L to the two C++ archives: the NDK libc.a must not shadow Bionic.
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-Lnative=$link -lstatic=c++abi -Clink-arg=-Wl,-z,max-page-size=16384 -Clink-arg=-Wl,-z,common-page-size=16384"
}
inspect_android() {
    "$GB_NDK_BIN/llvm-readelf" -h -l -d --notes "$1" > "$2"
    grep -Eq 'Type:.*DYN' "$2" && grep -Eq 'Machine:.*AArch64' "$2" && grep -q '/system/bin/linker64' "$2" || fail 'Invalid Android ELF architecture or interpreter.'
    grep -Eq 'NEEDED.*\[libc\.so\]' "$2" || fail 'Missing shared Bionic libc.'
    awk '/ LOAD / { count++; if ($NF != "0x4000") bad=1 } END { exit(count == 0 || bad) }' "$2" || fail 'Android LOAD segments must be 16 KiB aligned.'
    if grep NEEDED "$2" | grep -Ev '\[(libc|libm|libdl|liblog)\.so\]'; then fail 'Unexpected Android dynamic dependency.'; fi
}
