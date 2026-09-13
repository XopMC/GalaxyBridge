#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_PREFIX='com.xopmc.GalaxyBridge.internal.stable-v6'

require_service() {
  GB_FILE=$1
  GB_SUFFIX=$2
  if ! /usr/bin/grep -Fq "${GB_PREFIX}.${GB_SUFFIX}" "$GB_FILE"; then
    echo "Internal Keychain namespace is not on the stable signing generation: $GB_SUFFIX" >&2
    exit 1
  fi
}

require_service "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift" identity
require_service "$GB_ROOT/macos/GalaxyBridgeMac/Security/PairedPeerStore.swift" paired-peer
require_service "$GB_ROOT/macos/GalaxyBridgeMac/Security/ADBBindingStore.swift" adb-binding
require_service "$GB_ROOT/macos/GalaxyBridgeMac/Storage/EncryptedContentCache.swift" cache

require_policy_usage() {
  GB_FILE=$1
  if ! /usr/bin/grep -Fq 'GalaxyKeychainPolicy.searchQuery' "$GB_FILE" ||
     ! /usr/bin/grep -Fq 'GalaxyKeychainPolicy.applyInsertionPolicy' "$GB_FILE"; then
    echo "macOS Keychain call site bypasses the internal/distribution backend policy: $GB_FILE" >&2
    exit 1
  fi
}

require_policy_usage "$GB_ROOT/macos/GalaxyBridgeMac/Security/KeychainIdentityStore.swift"
require_policy_usage "$GB_ROOT/macos/GalaxyBridgeMac/Security/PairedPeerStore.swift"
require_policy_usage "$GB_ROOT/macos/GalaxyBridgeMac/Security/ADBBindingStore.swift"
require_policy_usage "$GB_ROOT/macos/GalaxyBridgeMac/Storage/EncryptedContentCache.swift"

if /usr/bin/grep -R -E -q 'com\.xopmc\.GalaxyBridge\.internal\.v[0-9]+\.' \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Storage"; then
  echo "Legacy ad-hoc Keychain namespace remains in active production code." >&2
  exit 1
fi

if /usr/bin/grep -R -F -q 'com.xopmc.GalaxyBridge.internal.stable-v5.' \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Storage"; then
  echo "Quarantined stable-v5 Keychain namespace remains active." >&2
  exit 1
fi

echo "Internal stable Keychain namespace regression passed."
