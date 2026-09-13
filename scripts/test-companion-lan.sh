#!/usr/bin/env bash
set -euo pipefail

GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_OPENSSL="${OPENSSL_PATH:-$(command -v openssl)}"
GB_LSOF="$(command -v lsof)"
GB_TLS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/galaxybridge-lan-tls.XXXXXX")"
GB_SERVER_PID=""
GB_SPEC_BIN="$GB_ROOT/.build/debug/GalaxyBridgeLANIntegrationSpec"

cleanup() {
  if [[ -n "$GB_SERVER_PID" ]] && kill -0 "$GB_SERVER_PID" 2>/dev/null; then
    kill "$GB_SERVER_PID" 2>/dev/null || true
    wait "$GB_SERVER_PID" 2>/dev/null || true
  fi
  if [[ -d "$GB_TLS_TMP" ]]; then
    find "$GB_TLS_TMP" -type f -delete
    rmdir "$GB_TLS_TMP"
  fi
}
trap cleanup EXIT

lan_spec_needs_build() {
  [[ ! -x "$GB_SPEC_BIN" ]] && return 0

  local input
  for input in \
    "$GB_ROOT/Package.swift" \
    "$GB_ROOT/Package.resolved" \
    "$GB_ROOT/Sources/GalaxyBridgeCore" \
    "$GB_ROOT/Sources/GalaxyBridgeLANIntegrationSpec" \
    "$GB_ROOT/protocol" \
    "$GB_ROOT/.build/checkouts/swift-protobuf/Sources"
  do
    [[ -e "$input" ]] || continue
    if find "$input" -type f -newer "$GB_SPEC_BIN" -print -quit | grep -q .; then
      return 0
    fi
  done

  return 1
}

if lan_spec_needs_build; then
  /usr/bin/swift build \
    --package-path "$GB_ROOT" \
    --product GalaxyBridgeLANIntegrationSpec
fi

"$GB_SPEC_BIN"

"$GB_OPENSSL" req \
  -x509 \
  -newkey ec \
  -pkeyopt ec_paramgen_curve:P-256 \
  -nodes \
  -subj "/CN=GalaxyBridge Companion LAN Test" \
  -keyout "$GB_TLS_TMP/key.pem" \
  -out "$GB_TLS_TMP/cert.pem" \
  -days 1 \
  >/dev/null 2>&1

"$GB_OPENSSL" s_server \
  -accept 127.0.0.1:0 \
  -cert "$GB_TLS_TMP/cert.pem" \
  -key "$GB_TLS_TMP/key.pem" \
  -tls1_3 \
  -quiet \
  -naccept 1 \
  >"$GB_TLS_TMP/server.log" 2>&1 &
GB_SERVER_PID="$!"

GB_PORT=""
for _ in {1..50}; do
  GB_ENDPOINT="$(
    "$GB_LSOF" -nP -a -p "$GB_SERVER_PID" -iTCP -sTCP:LISTEN -Fn 2>/dev/null \
      | sed -n 's/^n//p' \
      | head -1 \
      || true
  )"
  GB_PORT="${GB_ENDPOINT##*:}"
  [[ -n "$GB_PORT" ]] && break
  kill -0 "$GB_SERVER_PID" 2>/dev/null || {
    cat "$GB_TLS_TMP/server.log" >&2
    exit 1
  }
  sleep 0.05
done

if [[ -z "$GB_PORT" ]]; then
  echo "Timed out waiting for the local TLS test endpoint." >&2
  cat "$GB_TLS_TMP/server.log" >&2
  exit 1
fi

OPENSSL_PATH="$GB_OPENSSL" "$GB_ROOT/scripts/companion-tls-smoke.sh" 127.0.0.1 "$GB_PORT"
wait "$GB_SERVER_PID"
GB_SERVER_PID=""
printf 'PASS Companion LAN local endpoint negotiates TLS 1.3\n'
