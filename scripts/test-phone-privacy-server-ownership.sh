#!/bin/bash
set -euo pipefail
privacy_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
privacy_test_dir="$(mktemp -d /tmp/galaxybridge-privacy-owner.XXXXXX)"
trap 'rm -rf "$privacy_test_dir"' EXIT
cd "$privacy_repo_root"
swiftc -swift-version 6 -parse-as-library \
  macos/GalaxyBridgeMac/Transport/PhonePrivacyServerOwnership.swift \
  macos/GalaxyBridgeMacTests/PhonePrivacyServerOwnershipSpec.swift \
  -o "$privacy_test_dir/spec"
"$privacy_test_dir/spec"
