#!/usr/bin/env bash
set -euo pipefail

GB_HOST="${1:?usage: companion-tls-smoke.sh HOST PORT}"
GB_PORT="${2:?usage: companion-tls-smoke.sh HOST PORT}"
GB_OPENSSL="${OPENSSL_PATH:-$(command -v openssl)}"

GB_OUTPUT="$(printf '' | "$GB_OPENSSL" s_client \
  -connect "${GB_HOST}:${GB_PORT}" \
  -tls1_3 \
  -brief \
  2>&1)" || {
    echo "companion_tls_handshake_failed" >&2
    exit 1
  }

if ! /usr/bin/grep -Fq 'Protocol version: TLSv1.3' <<<"$GB_OUTPUT"; then
  echo "companion_tls_protocol_mismatch" >&2
  exit 2
fi

printf 'PASS Companion endpoint completed a TLS 1.3 handshake\n'
