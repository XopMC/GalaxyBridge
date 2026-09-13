#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_SECURITY="$GB_ROOT/macos/GalaxyBridgeMac/Security"

for GB_FILE in \
  "$GB_SECURITY/KeychainIdentityStore.swift" \
  "$GB_SECURITY/PairedPeerStore.swift" \
  "$GB_SECURITY/ADBBindingStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Storage/EncryptedContentCache.swift"; do
  /usr/bin/grep -Fq 'SecureRecordBackendFactory.make' "$GB_FILE" || {
    echo "Secure record caller bypasses flavor routing: $GB_FILE" >&2
    exit 1
  }
done

for GB_FILE in \
  "$GB_SECURITY/KeychainIdentityStore.swift" \
  "$GB_SECURITY/PairedPeerStore.swift" \
  "$GB_SECURITY/ADBBindingStore.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMac/Storage/EncryptedContentCache.swift"; do
  if /usr/bin/grep -Eq 'SecItem(Add|Update|Delete|CopyMatching)' "$GB_FILE"; then
    echo "Store owns a direct Keychain call instead of the distribution-only backend: $GB_FILE" >&2
    exit 1
  fi
done

/usr/bin/grep -Fq 'KeychainSecureRecordPersistenceBackend' \
  "$GB_SECURITY/KeychainSecureRecordPersistence.swift"
/usr/bin/grep -Fq 'dataProtectionKeychain' \
  "$GB_SECURITY/SecureRecordPersistence.swift"

echo "Internal local-file and distribution Keychain routing source contract passed."
