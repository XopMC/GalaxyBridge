#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-nearby-crypto.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
swiftc -swift-version 6 "$root/Sources/GalaxyBridgeCore/NearbyBootstrapCrypto.swift" "$root/macos/GalaxyBridgeMacTests/NearbyBootstrapCryptoSpec.swift" -o "$tmp/spec"
"$tmp/spec"
