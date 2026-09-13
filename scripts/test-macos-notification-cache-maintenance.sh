#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-encrypted-cache-spec.XXXXXX")
trap 'rm -rf -- "$GB_TMP"' EXIT HUP INT TERM

xcrun swiftc \
    -emit-library \
    -emit-module \
    -module-name GalaxyBridgeCore \
    "$GB_ROOT/Sources/GalaxyBridgeCore/EncryptedPayload.swift" \
    -o "$GB_TMP/libGalaxyBridgeCore.dylib"

xcrun swiftc \
    -I "$GB_TMP" \
    -L "$GB_TMP" \
    -lGalaxyBridgeCore \
    -I "$GB_ROOT/Sources/CSQLite" \
    -lsqlite3 \
    -framework Security \
    -framework LocalAuthentication \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/SecureRecordPersistence.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainSecureRecordPersistence.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Storage/EncryptedContentCache.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Storage/NotificationCacheRemovalAttempt.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMac/Storage/ContentCacheMaintenanceCoordinator.swift" \
    "$GB_ROOT/macos/GalaxyBridgeMacTests/ContentCacheMaintenanceCoordinatorSpec.swift" \
    -o "$GB_TMP/EncryptedContentCacheEnumerationSpec"

DYLD_LIBRARY_PATH="$GB_TMP" "$GB_TMP/EncryptedContentCacheEnumerationSpec"
