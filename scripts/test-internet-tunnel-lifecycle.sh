#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/galaxybridge-tunnel-lifecycle.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$repo_root"
clang -std=c11 -Wall -Wextra -Werror -DGB_TUNNEL_ADAPTER_TEST \
  -I native/galaxybridge-internet/include -I native/galaxybridge-internet/tests/stubs \
  native/galaxybridge-internet/tunnel_adapter.c native/galaxybridge-internet/tests/tunnel_lifecycle_test.c \
  -o "$test_dir/lifecycle"
"$test_dir/lifecycle"
