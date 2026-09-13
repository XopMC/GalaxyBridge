#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_GRADLE="${GALAXYBRIDGE_GRADLE:-$GB_ROOT/android/gradlew}"
# shellcheck source=select-java-runtime.sh
source "$GB_ROOT/scripts/select-java-runtime.sh"
GB_JAVA_HOME="$(galaxybridge_select_java_home)"

(
  cd "$GB_ROOT"
  /usr/bin/swift run GalaxyBridgeProtocolSpec
)

env JAVA_HOME="$GB_JAVA_HOME" \
  "$GB_GRADLE" -p "$GB_ROOT/android" :companion-protocol:testDebugUnitTest
