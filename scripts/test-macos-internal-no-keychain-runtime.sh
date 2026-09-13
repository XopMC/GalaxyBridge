#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_APP="${GALAXYBRIDGE_PACKAGE_TEST_APP:-}"
[[ "$GB_APP" == /* && "$GB_APP" == *.app && "$GB_APP" != "$GB_ROOT/.build/GalaxyBridgeInternal.app" && ! "$GB_APP" -ef "$GB_ROOT/.build/GalaxyBridgeInternal.app" ]] || {
  echo "Set GALAXYBRIDGE_PACKAGE_TEST_APP to an isolated test package." >&2
  exit 2
}
GB_EXECUTABLE="$GB_APP/Contents/MacOS/GalaxyBridgeMac"
GB_TMP="$(mktemp -d)"
GB_PID=""

gb_cleanup() {
  if [[ -n "$GB_PID" ]] && /bin/kill -0 "$GB_PID" 2>/dev/null; then
    /bin/kill -TERM "$GB_PID" 2>/dev/null || true
    wait "$GB_PID" 2>/dev/null || true
  fi
  /bin/rm -rf -- "$GB_TMP"
}
trap gb_cleanup EXIT

[[ -x "$GB_EXECUTABLE" ]] || {
  echo "Package the Internal app before running the runtime storage test." >&2
  exit 1
}
[[ "$(/usr/bin/defaults read "$GB_APP/Contents/Info" CFBundleIdentifier)" == \
  "com.xopmc.GalaxyBridge.internal" ]]

/usr/bin/xcrun clang -dynamiclib \
  "$GB_ROOT/macos/GalaxyBridgeMacTests/KeychainAPICallTrap.c" \
  -framework CoreFoundation \
  -framework Security \
  -o "$GB_TMP/KeychainAPICallTrap.dylib"

GB_SECURITY_AGENT_BEFORE="$(/usr/bin/pgrep -x SecurityAgent 2>/dev/null | /usr/bin/sort -n || true)"
GALAXYBRIDGE_INTERNAL_RECORD_STORE_ROOT="$GB_TMP/records" \
GALAXYBRIDGE_KEYCHAIN_CALL_MARKER="$GB_TMP/keychain-calls.log" \
GALAXYBRIDGE_INTERPOSER_LOADED_MARKER="$GB_TMP/interposer-loaded" \
DYLD_INSERT_LIBRARIES="$GB_TMP/KeychainAPICallTrap.dylib" \
DYLD_FORCE_FLAT_NAMESPACE=1 \
  "$GB_EXECUTABLE" >"$GB_TMP/app.log" 2>&1 &
GB_PID=$!

/bin/sleep 3
if ! /bin/kill -0 "$GB_PID" 2>/dev/null; then
  wait "$GB_PID" || true
  echo "Internal app exited during the non-Keychain runtime probe." >&2
  /bin/cat "$GB_TMP/app.log" >&2
  exit 1
fi

/bin/kill -TERM "$GB_PID"
wait "$GB_PID" 2>/dev/null || true
GB_PID=""

[[ "$(/bin/cat "$GB_TMP/interposer-loaded")" == "loaded" ]] || {
  echo "Keychain call interposer was not loaded into the Internal process." >&2
  exit 1
}

if [[ -s "$GB_TMP/keychain-calls.log" ]]; then
  echo "Internal runtime called a Keychain item API:" >&2
  /bin/cat "$GB_TMP/keychain-calls.log" >&2
  exit 1
fi

GB_SECURITY_AGENT_AFTER="$(/usr/bin/pgrep -x SecurityAgent 2>/dev/null | /usr/bin/sort -n || true)"
if [[ "$GB_SECURITY_AGENT_AFTER" != "$GB_SECURITY_AGENT_BEFORE" ]]; then
  echo "Internal launch changed the SecurityAgent process set." >&2
  echo "before=$GB_SECURITY_AGENT_BEFORE after=$GB_SECURITY_AGENT_AFTER" >&2
  exit 1
fi

[[ "$(/usr/bin/stat -f '%Lp' "$GB_TMP/records")" == "700" ]]
GB_RECORD_COUNT="$(/usr/bin/find "$GB_TMP/records" -type f -name '*.record' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
(( GB_RECORD_COUNT >= 1 )) || {
  echo "Internal launch did not persist its local cache key." >&2
  exit 1
}
while IFS= read -r GB_RECORD; do
  [[ "$(/usr/bin/stat -f '%Lp' "$GB_RECORD")" == "600" ]]
done < <(/usr/bin/find "$GB_TMP/records" -type f -name '*.record')

echo "Internal launch used only the protected local record store and spawned no SecurityAgent."
