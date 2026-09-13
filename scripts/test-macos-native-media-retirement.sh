#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_SWIFT=$(/usr/bin/xcrun --find swift)
GB_DEVELOPER_DIR=$(/usr/bin/xcode-select -p)
GB_TESTING_FRAMEWORKS="$GB_DEVELOPER_DIR/Library/Developer/Frameworks"
GB_TOOLCHAIN_LIBRARIES="$GB_DEVELOPER_DIR/Library/Developer/usr/lib"
[ -d "$GB_ROOT/.build/checkouts/swift-protobuf" ] || { echo 'Missing prepared SwiftProtobuf checkout' >&2; exit 2; }
GB_SELECTED_FILTER=${GB_NATIVE_RETIREMENT_FILTER:-NativeMediaRetirementTests}
unset GB_NATIVE_RETIREMENT_FILTER PROTOC_PATH GALAXYBRIDGE_APP_STORE
set -- "$GB_SWIFT" test --package-path "$GB_ROOT" --scratch-path "$GB_ROOT/.build" --jobs 2 --disable-automatic-resolution --filter "$GB_SELECTED_FILTER"
if [ -d "$GB_TESTING_FRAMEWORKS/Testing.framework" ]; then
  set -- "$@" -Xswiftc -F -Xswiftc "$GB_TESTING_FRAMEWORKS" -Xlinker -F -Xlinker "$GB_TESTING_FRAMEWORKS" -Xlinker -rpath -Xlinker "$GB_TESTING_FRAMEWORKS"
fi
if [ -d "$GB_TOOLCHAIN_LIBRARIES" ]; then set -- "$@" -Xlinker -rpath -Xlinker "$GB_TOOLCHAIN_LIBRARIES"; fi
exec "$@"
