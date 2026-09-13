#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_GRADLE="${GALAXYBRIDGE_GRADLE:-}"
# shellcheck source=select-java-runtime.sh
source "$GB_ROOT/scripts/select-java-runtime.sh"

galaxybridge_verify_local_gradle_checks() {
  local root="$1"
  local gradle="$2"
  local java_home="$3"

  env GALAXYBRIDGE_GRADLE="$gradle" \
    GALAXYBRIDGE_JAVA_HOME="$java_home" \
    JAVA_HOME="$java_home" \
    "$root/scripts/test-protobuf-golden-fixture.sh"

  env JAVA_HOME="$java_home" "$gradle" -p "$root/android" \
    :app:testInternalDebugUnitTest \
    :app:testDirectDebugUnitTest \
    :app:testPlayDebugUnitTest \
    :companion-core:testDebugUnitTest \
    :app:assembleInternalDebug \
    :app:assembleDirectDebug \
    :app:assemblePlayDebug \
    :app:lintInternalDebug \
    :app:lintDirectDebug \
    :app:lintPlayDebug

  env JAVA_HOME="$java_home" sh "$root/scripts/test-android-outgoing-files.sh"
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

# Public execution delegates to the supported CMake check target. Keep the
# sourced Gradle helper above for the Java-selection regression tests.
export JAVA_HOME="$(galaxybridge_select_java_home)"
GB_CMAKE="${CMAKE:-$(command -v cmake || true)}"
if [[ -z "$GB_CMAKE" && -x "$GB_ROOT/out/macos-arm64-release/tools/bin/cmake" ]]; then
  GB_CMAKE="$GB_ROOT/out/macos-arm64-release/tools/bin/cmake"
fi
[[ -x "$GB_CMAKE" ]] || { printf 'Install CMake or run scripts/bootstrap-build-tools.py first.\n' >&2; exit 2; }
cd "$GB_ROOT"
exec "$GB_CMAKE" --build --preset macos-arm64-release --target check
