#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/galaxybridge-signing-probe.XXXXXX")"
trap '/bin/rm -rf -- "$GB_TMP_DIR"' EXIT
GB_SIGN_DIR="$GB_ROOT/.build/internal-signing"

GB_ORIGINAL_SEARCH_LIST=$(/usr/bin/security list-keychains -d user)

package_and_read_requirement() {
  local GB_APP="$1"
  GALAXYBRIDGE_INTERNAL_APP_OUTPUT="$GB_APP" "$GB_ROOT/scripts/package-macos-internal.sh" >/dev/null || return $?
  /usr/bin/codesign --verify --deep --strict "$GB_APP" >/dev/null || return $?
  # The executable path intentionally differs between isolated rebuilds.
  # Compare the actual signing requirement, not codesign's path header.
  /usr/bin/codesign -d -r- "$GB_APP" 2>&1 | /usr/bin/sed -n '/^designated => /p'
}

GB_FIRST_REQUIREMENT="$(package_and_read_requirement "$GB_TMP_DIR/First.app")"
GB_AFTER_FIRST_SEARCH_LIST=$(/usr/bin/security list-keychains -d user)
GB_SECOND_REQUIREMENT="$(package_and_read_requirement "$GB_TMP_DIR/Second.app")"
GB_AFTER_SECOND_SEARCH_LIST=$(/usr/bin/security list-keychains -d user)

if [[ "$GB_AFTER_FIRST_SEARCH_LIST" != "$GB_ORIGINAL_SEARCH_LIST" ||
      "$GB_AFTER_SECOND_SEARCH_LIST" != "$GB_ORIGINAL_SEARCH_LIST" ]]; then
  echo "Internal packaging changed the user Keychain search list." >&2
  exit 1
fi

if [[ -z "$GB_FIRST_REQUIREMENT" || "$GB_FIRST_REQUIREMENT" != "$GB_SECOND_REQUIREMENT" ]]; then
  echo "Internal signing requirement changed between rebuilds." >&2
  exit 1
fi

for GB_SENSITIVE_FILE in \
  "$GB_SIGN_DIR/private-key.pem" \
  "$GB_SIGN_DIR/identity.p12" \
  "$GB_SIGN_DIR/GalaxyBridgeInternalSigning-v2.keychain-db"; do
  GB_MODE=$(/usr/bin/stat -f '%Lp' "$GB_SENSITIVE_FILE")
  if (( (8#$GB_MODE & 8#077) != 0 )); then
    echo "Internal signing material is readable outside its owner." >&2
    exit 1
  fi
done

echo "macOS internal signing regression passed."
