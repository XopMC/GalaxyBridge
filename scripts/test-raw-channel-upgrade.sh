#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-raw-upgrade.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 6 "$root/Sources/GalaxyBridgeCore/RawChannelUpgradeDecoder.swift" "$root/macos/GalaxyBridgeMacTests/RawChannelUpgradeSpec.swift" -o "$tmp/spec"
"$tmp/spec"
