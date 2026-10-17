#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-input-marker.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 6 -parse-as-library \
  "$root/macos/GalaxyBridgeMac/Media/PrimaryMediaDiagnostics.swift" \
  "$root/macos/GalaxyBridgeMacTests/PrimaryInputMarkerSpec.swift" \
  -framework CoreVideo -o "$tmp/spec"
"$tmp/spec" --primary-media-diagnostics --primary-input-marker-nonce=270544960
"$tmp/spec" --primary-media-diagnostics --expect-marker-disabled
"$tmp/spec" --primary-media-diagnostics --primary-input-marker-nonce=0 --expect-marker-invalid
"$tmp/spec" --primary-media-diagnostics --primary-input-marker-nonce=nope --expect-marker-invalid
"$tmp/spec" --primary-media-diagnostics --primary-input-marker-nonce=270544960 --primary-input-marker-nonce=270544960 --expect-marker-invalid
java_home=$(bash -c 'source "$1"; galaxybridge_select_java_home' bash "$root/scripts/select-java-runtime.sh")
"$java_home/bin/javac" -d "$tmp/java" \
  "$root/tests/android/gesture-marker/src/com/xopmc/galaxybridge/qa/gestureresponse/InputMarkerBits.java" \
  "$root/tests/android/gesture-marker/InputMarkerBitsSpec.java"
"$java_home/bin/java" -ea -cp "$tmp/java" com.xopmc.galaxybridge.qa.gestureresponse.InputMarkerBitsSpec
