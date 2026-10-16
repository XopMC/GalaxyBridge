#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-policy.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 6 "$root/Sources/GalaxyBridgeCore/DirectConnectivityPolicy.swift" "$root/macos/GalaxyBridgeMacTests/NearbyConnectivityPolicySpec.swift" -o "$tmp/spec"
"$tmp/spec"
