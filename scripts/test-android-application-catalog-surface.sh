#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$GB_ROOT/android"

./gradlew --no-daemon \
  :app:processInternalDebugMainManifest \
  :app:processPlayDebugMainManifest >/dev/null

INTERNAL_MANIFEST="$GB_ROOT/android/app/build/intermediates/merged_manifest/internalDebug/processInternalDebugMainManifest/AndroidManifest.xml"
PLAY_MANIFEST="$GB_ROOT/android/app/build/intermediates/merged_manifest/playDebug/processPlayDebugMainManifest/AndroidManifest.xml"

test -f "$INTERNAL_MANIFEST"
test -f "$PLAY_MANIFEST"

rg -q 'ApplicationCatalogExportReceiver' "$INTERNAL_MANIFEST"
rg -q 'android:permission="android.permission.DUMP"' "$INTERNAL_MANIFEST"
rg -q 'android.intent.category.LAUNCHER' "$INTERNAL_MANIFEST"

if rg -q 'android.permission.QUERY_ALL_PACKAGES' "$INTERNAL_MANIFEST"; then
  echo "Internal catalog must use a launcher-intent visibility query, not QUERY_ALL_PACKAGES" >&2
  exit 1
fi

if rg -q 'android.permission.QUERY_ALL_PACKAGES|ApplicationCatalogExportReceiver' "$PLAY_MANIFEST"; then
  echo "Play manifest leaked the enhanced application-catalog surface" >&2
  exit 1
fi

echo "PASS internal-only application catalog export surface"
