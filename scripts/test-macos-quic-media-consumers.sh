#!/bin/sh
set -eu
GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_SWIFT=$(/usr/bin/xcrun --find swift)
GB_DEVELOPER_DIR=$(/usr/bin/xcode-select -p)
GB_TESTING_FRAMEWORKS="$GB_DEVELOPER_DIR/Library/Developer/Frameworks"
GB_TOOLCHAIN_LIBRARIES="$GB_DEVELOPER_DIR/Library/Developer/usr/lib"
GB_PROTOBUF="$GB_ROOT/.build/checkouts/swift-protobuf"
[ -d "$GB_PROTOBUF" ] || { echo 'Missing prepared default SwiftProtobuf checkout' >&2; exit 2; }
[ "$(/usr/bin/git -C "$GB_PROTOBUF" rev-parse HEAD)" = 55d7a1cc5666b85c13464aea1c4b4a90feccb4c8 ] || { echo 'Unexpected prepared SwiftProtobuf revision' >&2; exit 2; }
unset PROTOC_PATH GALAXYBRIDGE_APP_STORE
export GB_QUIC_MEDIA_FIXTURE="$GB_ROOT/.build/quic-target-official/aarch64-apple-darwin/debug/gb-quic-media-fixture"
export GB_QUIC_MEDIA_ARTIFACTS="$GB_ROOT/.build/quic-media-native-artifacts"
[ -x "$GB_QUIC_MEDIA_FIXTURE" ] || { echo 'Build the scoped Rust fixture first with test-quic-media-contract.sh' >&2; exit 2; }
GB_SELECTED_FILTER=${GB_QUIC_NATIVE_FILTER:-QuicMediaConsumerFixture}
# This runner-owned selector changes test selection, not plugin build inputs.
unset GB_QUIC_NATIVE_FILTER
set -- "$GB_SWIFT" test --package-path "$GB_ROOT" --scratch-path "$GB_ROOT/.build" --jobs 2 --disable-automatic-resolution --skip-update --filter "$GB_SELECTED_FILTER"
if [ -d "$GB_TESTING_FRAMEWORKS/Testing.framework" ]; then
  set -- "$@" -Xswiftc -F -Xswiftc "$GB_TESTING_FRAMEWORKS" -Xlinker -F -Xlinker "$GB_TESTING_FRAMEWORKS" -Xlinker -rpath -Xlinker "$GB_TESTING_FRAMEWORKS"
fi
if [ -d "$GB_TOOLCHAIN_LIBRARIES" ]; then set -- "$@" -Xlinker -rpath -Xlinker "$GB_TOOLCHAIN_LIBRARIES"; fi
exec "$@"
