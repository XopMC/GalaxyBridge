#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-device-row-merge.XXXXXX")
trap 'rm -rf -- "$GB_TEST_DIR"' EXIT HUP INT TERM

xcrun swiftc -emit-library -emit-module -module-name GalaxyBridgeCore \
    "$GB_ROOT/Sources/GalaxyBridgeCore/TransportKind.swift" \
    "$GB_ROOT/Sources/GalaxyBridgeCore/Capability.swift" \
    "$GB_ROOT/Sources/GalaxyBridgeCore/ScrcpyProtocol.swift" \
    -o "$GB_TEST_DIR/libGalaxyBridgeCore.dylib"

GB_ROW_SOURCE="$GB_ROOT/macos/GalaxyBridgeMac/DeviceRow.swift"
if [ -n "${GB_DEVICE_ROW_BASELINE_APP_MODEL:-}" ]; then
    # Reproduce the actual pre-extraction boundary, without maintaining a second
    # implementation of route selection in the test. Only method visibility and
    # its enclosing type change; the source body is untouched.
    GB_ROW_SOURCE="$GB_TEST_DIR/DeviceRowBaseline.swift"
    {
        printf 'import Foundation\nimport GalaxyBridgeCore\n'
        sed -n '/^struct DeviceRow: /,/^}/p' "$GB_DEVICE_ROW_BASELINE_APP_MODEL"
        printf '\nenum DeviceRowMerger {\n'
        sed -n '/^    private func merge(_ left: DeviceRow,/,/^    }/p' "$GB_DEVICE_ROW_BASELINE_APP_MODEL" \
            | sed 's/private func merge/static func merge/'
        printf '}\n'
    } > "$GB_ROW_SOURCE"
fi

xcrun swiftc -I "$GB_TEST_DIR" -L "$GB_TEST_DIR" -lGalaxyBridgeCore \
    "$GB_ROW_SOURCE" \
    "$GB_ROOT/macos/GalaxyBridgeMac/UserFacingText.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/UserFacingTextResolver.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/DeviceRowMergeSpec.swift" \
    -o "$GB_TEST_DIR/DeviceRowMergeSpec"

GB_ROW_TEST_RESOURCES="$GB_ROOT/macos/GalaxyBridgeMac/Resources/en.lproj" \
    DYLD_LIBRARY_PATH="$GB_TEST_DIR" "$GB_TEST_DIR/DeviceRowMergeSpec"
