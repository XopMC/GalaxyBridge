#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-keychain-rebuild.XXXXXX")"
GB_SIGN_DIR="$GB_ROOT/.build/internal-signing"
GB_SIGN_KEYCHAIN="$GB_SIGN_DIR/GalaxyBridgeInternalSigning-v2.keychain-db"
GB_SIGN_PASSWORD='GalaxyBridgeInternalBuildKeychain-v1'
GB_SIGN_CERT_NAME='GalaxyBridge Internal Development'
GB_DATA_KEYCHAIN="$GB_TMP/GalaxyBridgeProbeData.keychain-db"
GB_DATA_PASSWORD='GalaxyBridgeProbeData-v1'
GB_SERVICE="com.xopmc.GalaxyBridge.internal.integration.$(/usr/bin/uuidgen)"
GB_ORIGINAL_SEARCH_LIST="$(/usr/bin/security list-keychains -d user)"
GB_ORIGINAL_DEFAULT_KEYCHAIN="$(/usr/bin/security default-keychain -d user)"
GB_ORIGINAL_DEFAULT_KEYCHAIN="${GB_ORIGINAL_DEFAULT_KEYCHAIN#*\"}"
GB_ORIGINAL_DEFAULT_KEYCHAIN="${GB_ORIGINAL_DEFAULT_KEYCHAIN%\"*}"
GB_ORIGINAL_KEYCHAINS=()
GB_SEARCH_LIST_CHANGED=0
GB_FIRST_PROBE_READY=0

while IFS= read -r GB_KEYCHAIN_LINE; do
  GB_KEYCHAIN_LINE="${GB_KEYCHAIN_LINE#"${GB_KEYCHAIN_LINE%%[![:space:]]*}"}"
  GB_KEYCHAIN_LINE="${GB_KEYCHAIN_LINE%"${GB_KEYCHAIN_LINE##*[![:space:]]}"}"
  GB_KEYCHAIN_LINE="${GB_KEYCHAIN_LINE#\"}"
  GB_KEYCHAIN_LINE="${GB_KEYCHAIN_LINE%\"}"
  [[ -n "$GB_KEYCHAIN_LINE" ]] && GB_ORIGINAL_KEYCHAINS+=("$GB_KEYCHAIN_LINE")
done <<< "$GB_ORIGINAL_SEARCH_LIST"

gb_restore_search_list() {
  if [[ -n "$GB_ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
    /usr/bin/security default-keychain -d user -s "$GB_ORIGINAL_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  if (( ${#GB_ORIGINAL_KEYCHAINS[@]} > 0 )); then
    /usr/bin/security list-keychains -d user -s "${GB_ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  fi
}

gb_cleanup() {
  local GB_STATUS=$?
  trap - EXIT HUP INT TERM
  gb_restore_search_list
  if (( GB_FIRST_PROBE_READY == 1 )); then
    "$GB_TMP/probe-first" cleanup-delete "$GB_SERVICE" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$GB_TMP"
  exit "$GB_STATUS"
}
trap gb_cleanup EXIT HUP INT TERM

if [[ ! -f "$GB_SIGN_KEYCHAIN" ]]; then
  "$GB_ROOT/scripts/package-macos-internal.sh" >/dev/null 2>&1 || {
    echo "Could not prepare the isolated Keychain rebuild regression." >&2
    exit 1
  }
fi

/usr/bin/security unlock-keychain -p "$GB_SIGN_PASSWORD" "$GB_SIGN_KEYCHAIN" >/dev/null 2>&1
GB_SIGN_SHA=$(
  /usr/bin/security find-certificate -c "$GB_SIGN_CERT_NAME" -Z "$GB_SIGN_KEYCHAIN" |
    /usr/bin/awk '/SHA-1 hash:/{print $3; exit}'
)
if [[ -z "$GB_SIGN_SHA" ]]; then
  echo "Could not prepare the isolated Keychain rebuild regression." >&2
  exit 1
fi

GB_SIGN_KEYCHAIN_LISTED=0
for GB_EXISTING_KEYCHAIN in "${GB_ORIGINAL_KEYCHAINS[@]}"; do
  if [[ "$GB_EXISTING_KEYCHAIN" == "$GB_SIGN_KEYCHAIN" ]]; then
    GB_SIGN_KEYCHAIN_LISTED=1
    break
  fi
done
if (( GB_SIGN_KEYCHAIN_LISTED == 0 )); then
  /usr/bin/security list-keychains -d user -s "$GB_SIGN_KEYCHAIN" "${GB_ORIGINAL_KEYCHAINS[@]}" >/dev/null
  GB_SEARCH_LIST_CHANGED=1
fi

xcrun swiftc -framework Security \
  -suppress-warnings \
  -DGB_FIRST_REBUILD \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/InternalKeychainRebuildProbe.swift" \
  -o "$GB_TMP/probe-first"
xcrun swiftc -framework Security \
  -suppress-warnings \
  "$GB_ROOT/macos/GalaxyBridgeMac/Security/GalaxyKeychainPolicy.swift" \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/InternalKeychainRebuildProbe.swift" \
  -o "$GB_TMP/probe-second"

if /usr/bin/cmp -s "$GB_TMP/probe-first" "$GB_TMP/probe-second"; then
  echo "Keychain rebuild probes did not produce changed binaries." >&2
  exit 1
fi

for GB_PROBE in "$GB_TMP/probe-first" "$GB_TMP/probe-second"; do
  /usr/bin/codesign --force --sign "$GB_SIGN_SHA" \
    --identifier com.xopmc.GalaxyBridge.internal.keychain-probe \
    --keychain "$GB_SIGN_KEYCHAIN" "$GB_PROBE" >/dev/null 2>&1
  /usr/bin/codesign --verify --strict "$GB_PROBE" >/dev/null 2>&1
done
/bin/cp "$GB_TMP/probe-second" "$GB_TMP/probe-untrusted"
/usr/bin/codesign --force --sign "$GB_SIGN_SHA" \
  --identifier com.xopmc.GalaxyBridge.internal.keychain-probe-untrusted \
  --keychain "$GB_SIGN_KEYCHAIN" "$GB_TMP/probe-untrusted" >/dev/null 2>&1
/usr/bin/codesign --verify --strict "$GB_TMP/probe-untrusted" >/dev/null 2>&1
GB_FIRST_PROBE_READY=1

GB_FIRST_REQUIREMENT=$(
  /usr/bin/codesign -d -r- "$GB_TMP/probe-first" 2>&1 |
    /usr/bin/awk '/^designated =>/{print; exit}'
)
GB_SECOND_REQUIREMENT=$(
  /usr/bin/codesign -d -r- "$GB_TMP/probe-second" 2>&1 |
    /usr/bin/awk '/^designated =>/{print; exit}'
)
if [[ "$GB_FIRST_REQUIREMENT" != "$GB_SECOND_REQUIREMENT" ]]; then
  echo "Keychain rebuild probes do not share one signing requirement." >&2
  exit 1
fi

# The signing keychain is needed only while codesign resolves the identity.
# Restore the user's exact search list before exercising the default login
# Keychain so this test follows the same file-based backend as the app.
if (( GB_SEARCH_LIST_CHANGED == 1 )); then
  gb_restore_search_list
  GB_SEARCH_LIST_CHANGED=0
fi

# Keep the regression deterministic and independent from whether the user's
# login Keychain is currently locked. All probe data is confined to a fresh,
# unlocked disposable file Keychain; cleanup restores both user preferences.
/usr/bin/security create-keychain -p "$GB_DATA_PASSWORD" "$GB_DATA_KEYCHAIN"
/usr/bin/security set-keychain-settings -lut 21600 "$GB_DATA_KEYCHAIN"
/usr/bin/security unlock-keychain -p "$GB_DATA_PASSWORD" "$GB_DATA_KEYCHAIN"
/usr/bin/security default-keychain -d user -s "$GB_DATA_KEYCHAIN"
/usr/bin/security list-keychains -d user -s "$GB_DATA_KEYCHAIN" "${GB_ORIGINAL_KEYCHAINS[@]}"

gb_run_probe() {
  local GB_OPERATION=$1
  local GB_PROCESS_ID
  local GB_GUARD_ID
  local GB_RESULT
  if [[ "${GALAXYBRIDGE_PROBE_DIAGNOSTICS:-0}" == "1" ]]; then
    "$GB_TMP/probe" "$GB_OPERATION" "$GB_SERVICE" &
  else
    "$GB_TMP/probe" "$GB_OPERATION" "$GB_SERVICE" >/dev/null 2>&1 &
  fi
  GB_PROCESS_ID=$!
  (
    sleep 15
    /bin/kill -TERM "$GB_PROCESS_ID" >/dev/null 2>&1 || true
  ) &
  GB_GUARD_ID=$!
  set +e
  wait "$GB_PROCESS_ID"
  GB_RESULT=$?
  /bin/kill -TERM "$GB_GUARD_ID" >/dev/null 2>&1 || true
  wait "$GB_GUARD_ID" >/dev/null 2>&1
  set -e
  if (( GB_RESULT != 0 )); then
    if [[ "$GB_OPERATION" == "add-read" ]]; then
      echo "Initial isolated Keychain probe failed." >&2
    else
      echo "Keychain access failed across a changed signed binary." >&2
    fi
    exit 1
  fi
}

/bin/cp "$GB_TMP/probe-first" "$GB_TMP/probe"
gb_run_probe add-read
/bin/cp "$GB_TMP/probe-untrusted" "$GB_TMP/probe"
gb_run_probe assert-denied-noninteractive
/bin/cp "$GB_TMP/probe-second" "$GB_TMP/probe"
gb_run_probe update-enumerate-delete

"$GB_TMP/probe-first" cleanup-delete "$GB_SERVICE" >/dev/null 2>&1 || true
GB_FIRST_PROBE_READY=0
gb_restore_search_list

if [[ "$(/usr/bin/security list-keychains -d user)" != "$GB_ORIGINAL_SEARCH_LIST" ]]; then
  echo "Keychain rebuild regression changed the user search list." >&2
  exit 1
fi
GB_CURRENT_DEFAULT_KEYCHAIN="$(/usr/bin/security default-keychain -d user)"
GB_CURRENT_DEFAULT_KEYCHAIN="${GB_CURRENT_DEFAULT_KEYCHAIN#*\"}"
GB_CURRENT_DEFAULT_KEYCHAIN="${GB_CURRENT_DEFAULT_KEYCHAIN%\"*}"
if [[ "$GB_CURRENT_DEFAULT_KEYCHAIN" != "$GB_ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
  echo "Keychain rebuild regression changed the user default Keychain." >&2
  exit 1
fi

echo "Internal Keychain rebuild regression passed."
