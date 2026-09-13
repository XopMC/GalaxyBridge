#!/bin/sh
set -eu

GB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GB_BUILD_FILE="$GB_ROOT/android/app/build.gradle.kts"

if grep -Eiq 'com\.google\.mlkit|com\.google\.android\.datatransport|firebase-analytics' "$GB_BUILD_FILE"
then
    echo "Android build must not include telemetry-bearing scanner dependencies" >&2
    exit 1
fi

for GB_APK in \
    "$GB_ROOT/android/app/build/outputs/apk/internal/debug/app-internal-debug.apk" \
    "$GB_ROOT/android/app/build/outputs/apk/play/debug/app-play-debug.apk"
do
    test -s "$GB_APK"
    if unzip -p "$GB_APK" 'classes*.dex' | strings | \
        grep -Eq 'com/google/android/datatransport|com/google/mlkit|firebase/analytics'
    then
        echo "$(basename "$GB_APK") contains a forbidden telemetry runtime" >&2
        exit 1
    fi
done

printf 'Android APK telemetry surface passed.\n'
