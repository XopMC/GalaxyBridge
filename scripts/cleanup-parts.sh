#!/usr/bin/env bash
set -euo pipefail

GB_TRANSFER_ROOT="${1:?usage: cleanup-parts.sh TRANSFER_DIRECTORY}"
find "$GB_TRANSFER_ROOT" -type f -name '*.part' -mtime +7 -delete
