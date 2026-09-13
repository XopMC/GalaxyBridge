#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-recorder-audio.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/RecordingAACConfiguration.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Media/ScreenRecorder.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/ScreenRecorderAudioSpec.swift" -o "$GB_TMP/spec"
"$GB_TMP/spec"
# Compile the unchanged legacy real-writer tests against only these production sources.
# This avoids rebuilding or exercising unrelated application/transport components.
mkdir -p "$GB_TMP/legacy/Sources/GalaxyBridgeMac" "$GB_TMP/legacy/Tests/RecorderTests"
cp "$GB_ROOT/macos/GalaxyBridgeMac/Media/ScreenRecorder.swift" "$GB_TMP/legacy/Sources/GalaxyBridgeMac/"
cp "$GB_ROOT/macos/GalaxyBridgeMac/Media/RecordingAACConfiguration.swift" "$GB_TMP/legacy/Sources/GalaxyBridgeMac/"
cp "$GB_ROOT/macos/GalaxyBridgeMacKeyboardTests/ScreenRecorderFinalizationTests.swift" "$GB_TMP/legacy/Tests/RecorderTests/"
cat > "$GB_TMP/legacy/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "RecorderCompatibility", platforms: [.macOS(.v14)], targets: [
    .target(name: "GalaxyBridgeMac"),
    .testTarget(name: "RecorderTests", dependencies: ["GalaxyBridgeMac"]),
])
PACKAGE
GB_DEVELOPER_DIR=$(xcode-select -p)
GB_FRAMEWORKS="$GB_DEVELOPER_DIR/Library/Developer/Frameworks"
GB_LIBRARIES="$GB_DEVELOPER_DIR/Library/Developer/usr/lib"
set -- xcrun swift test --package-path "$GB_TMP/legacy" --filter ScreenRecorderFinalizationTests
if [ -d "$GB_FRAMEWORKS/Testing.framework" ]; then
  set -- "$@" -Xswiftc -F -Xswiftc "$GB_FRAMEWORKS" -Xlinker -F -Xlinker "$GB_FRAMEWORKS" -Xlinker -rpath -Xlinker "$GB_FRAMEWORKS"
fi
if [ -d "$GB_LIBRARIES" ]; then
  set -- "$@" -Xlinker -rpath -Xlinker "$GB_LIBRARIES"
fi
"$@"
