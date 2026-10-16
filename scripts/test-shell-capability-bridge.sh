#!/bin/bash
set -euo pipefail
bridge_root=$(cd "$(dirname "$0")/.." && pwd)
bridge_jdk=${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}
bridge_sdk=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
bridge_classes=${GB_SCRCPY_CLASS_DIR:-}
if [[ -z "$bridge_classes" ]]; then
  for candidate in "$bridge_root/out/clipboard-agent-build"/source-build.*/4.1/classes/com/genymobile/scrcpy/ClipboardAgent.class \
      "$bridge_root/out/macos-arm64-release/native-build/scrcpy"/source-build.*/4.1/classes/com/genymobile/scrcpy/ClipboardAgent.class; do
    if [[ -f "$candidate" ]]; then bridge_classes=${candidate%/com/genymobile/scrcpy/ClipboardAgent.class}; break; fi
  done
fi
[[ -n "$bridge_classes" ]] || { echo 'Set GB_SCRCPY_CLASS_DIR to cached compiled pinned server classes' >&2; exit 2; }
bridge_tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-shell-bridge.XXXXXX")
bridge_socket_tmp=$(mktemp -d /tmp/gb-shell-sockets.XXXXXX)
trap 'rm -rf -- "$bridge_tmp" "$bridge_socket_tmp"' EXIT
bridge_platform="$bridge_sdk/platforms/${GB_ANDROID_PLATFORM:-android-37.0}/android.jar"
bridge_lambda="$bridge_sdk/build-tools/${GB_ANDROID_BUILD_TOOLS:-37.0.0}/core-lambda-stubs.jar"
# Compile the real runtime against Android's bootclasspath, not JDK-only APIs.
"$bridge_jdk/bin/javac" -source 8 -target 8 -Xlint:-options -bootclasspath "$bridge_platform" \
  -cp "$bridge_classes:$bridge_lambda" -d "$bridge_tmp" "$bridge_root/third_party/scrcpy-gb-sync/ShellCapabilityBridge.java"
"$bridge_jdk/bin/javac" -source 8 -target 8 -Xlint:-options \
  -cp "$bridge_tmp:$bridge_platform:$bridge_classes" -d "$bridge_tmp" \
  "$bridge_root/third_party/scrcpy-gb-sync/ShellCapabilityBridgePolicyTest.java"
cc -std=c11 -Wall -Wextra -Werror -pthread "$bridge_root/scripts/fixtures/shell-broker-socket-retirement.c" -o "$bridge_tmp/socket-retirement"
GB_SHELL_SOCKET_RETIREMENT_FIXTURE="$bridge_tmp/socket-retirement" \
GB_SHELL_SOCKET_FIXTURE_DIRECTORY="$bridge_socket_tmp" \
  "$bridge_jdk/bin/java" -ea -cp "$bridge_tmp:$bridge_platform:$bridge_classes" com.genymobile.scrcpy.ShellCapabilityBridgePolicyTest
swiftc -swift-version 6 "$bridge_root/macos/GalaxyBridgeMac/Transport/ShellCapabilityBridgeActivationState.swift" \
  "$bridge_root/macos/GalaxyBridgeMacTests/ShellCapabilityBridgeActivationSpec.swift" -o "$bridge_tmp/activation-spec"
"$bridge_tmp/activation-spec"
