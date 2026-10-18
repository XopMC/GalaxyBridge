#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-producer-reservation.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$root/macos/GalaxyBridgeMac/Transport/ProducerPreparationReservation.swift" \
  "$root/macos/GalaxyBridgeMacTests/ProducerPreparationReservationSpec.swift" -o "$tmp/spec"
"$tmp/spec"
