#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_BUILD="$GB_ROOT/.build/app-store-release-audit"
GB_BINARY="$GB_BUILD/arm64-apple-macosx/release/GalaxyBridgeMac"

/usr/bin/env GALAXYBRIDGE_APP_STORE=1 /usr/bin/swift build \
  --package-path "$GB_ROOT" \
  --scratch-path "$GB_BUILD" \
  --configuration release \
  --product GalaxyBridgeMac

test -x "$GB_BINARY"

GB_UNDEFINED_SYMBOLS="$GB_BUILD/app-store-undefined-symbols.txt"
GB_BINARY_STRINGS="$GB_BUILD/app-store-binary-strings.txt"
/usr/bin/nm -u "$GB_BINARY" > "$GB_UNDEFINED_SYMBOLS"
/usr/bin/strings "$GB_BINARY" > "$GB_BINARY_STRINGS"

# Do not combine grep -q with an upstream producer under pipefail: grep exits
# early after a match and can turn the producer's SIGPIPE into a false PASS.
if /usr/bin/grep -Eq '_OBJC_CLASS_\$_NSTask|_posix_spawn|_popen|_system' "$GB_UNDEFINED_SYMBOLS"; then
  echo "Mac App Store binary still links process-launch APIs." >&2
  exit 1
fi

if /usr/bin/grep -Eq \
  'com\.genymobile\.scrcpy\.Server|scrcpy-server-v4\.1|platform-tools/adb|ScrcpyServerLocator|list_apps=true|start_app=' \
  "$GB_BINARY_STRINGS"; then
  echo "Mac App Store binary still contains ADB/scrcpy launch implementation." >&2
  exit 1
fi

for GB_FILE in \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBClient.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBOwnedRuntime.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBCommandRunner.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ScrcpySession.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Transport/ADBIdentityBinder.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/ADBBindingStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationCatalogEnhancedClient.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationWindowSession.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/ApplicationWindowCoordinator.swift"; do
  /usr/bin/head -n 1 "$GB_FILE" | /usr/bin/grep -Fxq '#if !GALAXYBRIDGE_APP_STORE' || {
    echo "Enhanced-only source lacks its App Store compile gate: $GB_FILE" >&2
    exit 1
  }
done

if /usr/bin/grep -Fq 'com.genymobile.scrcpy.Server' \
  "$GB_ROOT/Sources/GalaxyBridgeCore/ScrcpyProtocol.swift"; then
  echo "Common core still contains the enhanced scrcpy launch contract." >&2
  exit 1
fi
/usr/bin/grep -Fq 'com.genymobile.scrcpy.Server' \
  "$GB_ROOT/Sources/GalaxyBridgeEnhancedCore/ScrcpyLaunchConfiguration.swift" || {
    echo "Enhanced scrcpy launch contract is missing from its isolated product." >&2
    exit 1
  }

GB_APPSTORE_BLOCK="$GB_BUILD/appstore-project-block.txt"
/usr/bin/awk '
  /^  GalaxyBridgeAppStore:/ { inside = 1 }
  /^  GalaxyBridgeCameraExtension:/ { inside = 0 }
  inside { print }
' "$GB_ROOT/macos/project.yml" > "$GB_APPSTORE_BLOCK"

for GB_PATH in \
  Transport/ADBClient.swift \
  Transport/ADBOwnedRuntime.swift \
  Transport/ADBCommandRunner.swift \
  Transport/ScrcpySession.swift \
  Transport/ADBIdentityBinder.swift \
  Security/ADBBindingStore.swift \
  ApplicationCatalogEnhancedClient.swift \
  ApplicationWindowSession.swift \
  ApplicationWindowCoordinator.swift; do
  /usr/bin/grep -Fq "$GB_PATH" "$GB_APPSTORE_BLOCK" || {
    echo "App Store Xcode target does not physically exclude $GB_PATH" >&2
    exit 1
  }
done

if /usr/bin/grep -Fq 'product: GalaxyBridgeEnhancedCore' "$GB_APPSTORE_BLOCK"; then
  echo "App Store Xcode target still depends on GalaxyBridgeEnhancedCore." >&2
  exit 1
fi

GB_INTERNAL_BLOCK="$GB_BUILD/internal-project-block.txt"
/usr/bin/awk '
  /^  GalaxyBridgeInternal:/ { inside = 1 }
  /^  GalaxyBridgeAppStore:/ { inside = 0 }
  inside { print }
' "$GB_ROOT/macos/project.yml" > "$GB_INTERNAL_BLOCK"
/usr/bin/grep -Fq 'product: GalaxyBridgeEnhancedCore' "$GB_INTERNAL_BLOCK" || {
  echo "Internal Xcode target lost GalaxyBridgeEnhancedCore." >&2
  exit 1
}

printf 'PASS Mac App Store binary excludes process launch and enhanced transport implementation\n'
