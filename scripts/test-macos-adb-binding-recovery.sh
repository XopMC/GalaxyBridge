#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_BUILD=${GB_ADB_BINDING_RECOVERY_SCRATCH_PATH:-"${TMPDIR:-/tmp}/galaxybridge-adb-binding-recovery-build"}
GB_SWIFT=$(/usr/bin/xcrun --find swift)
GB_DEVELOPER_DIR=$(/usr/bin/xcode-select -p)
GB_TESTING_FRAMEWORKS="$GB_DEVELOPER_DIR/Library/Developer/Frameworks"
GB_TOOLCHAIN_LIBRARIES="$GB_DEVELOPER_DIR/Library/Developer/usr/lib"

set -- "$GB_SWIFT" test \
  --package-path "$GB_ROOT" \
  --scratch-path "$GB_BUILD" \
  --filter ADBBindingRecoveryTests

if [ -d "$GB_TESTING_FRAMEWORKS/Testing.framework" ]; then
  set -- "$@" \
    -Xswiftc -F -Xswiftc "$GB_TESTING_FRAMEWORKS" \
    -Xlinker -F -Xlinker "$GB_TESTING_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$GB_TESTING_FRAMEWORKS"
fi
if [ -d "$GB_TOOLCHAIN_LIBRARIES" ]; then
  set -- "$@" -Xlinker -rpath -Xlinker "$GB_TOOLCHAIN_LIBRARIES"
fi

exec "$@"
