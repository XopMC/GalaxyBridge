#!/usr/bin/env bash
# Run the owned tests against actual derivative production classes.
set -euo pipefail
export LC_ALL=C TZ=UTC
root=$(cd "$(dirname "$0")/.." && pwd)
test "$#" -eq 1 || { echo "Usage: bash scripts/test-scrcpy-gb-sync.sh ABSOLUTE_BUILD_DIR" >&2; exit 2; }
out=$1
out=$(cd "$out" && pwd)
jdk="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
cache="${GB_BUILD_DIR:-$root/build/native/scrcpy-tests}"
mkdir -p "$cache"
fetch() {
    local path="$cache/$1" url="$2" sha="$3"
    if [[ ! -f "$path" ]]; then
        [[ "${GB_OFFLINE:-0}" != 1 ]] || { echo "Missing offline input: $path" >&2; exit 1; }
        curl --fail --location --retry 3 "$url" -o "$path"
    fi
    [[ "$(shasum -a 256 "$path" | awk '{print $1}')" == "$sha" ]] || { echo "Hash mismatch: $path" >&2; exit 1; }
}
fetch junit-4.13.2.jar https://repo.maven.apache.org/maven2/junit/junit/4.13.2/junit-4.13.2.jar 8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3
fetch hamcrest-core-1.3.jar https://repo.maven.apache.org/maven2/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar 66fdef91e9739348df7a096aa384a5685f4e875584cce89386a7a47251c4d8e9
cache=$(cd "$cache" && pwd)
junit="$cache/junit-4.13.2.jar"
hamcrest="$cache/hamcrest-core-1.3.jar"
src="$out/scrcpy-2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0"
tests=$(mktemp -d "$out/host-tests.XXXXXX")
cp="$out/4.1-gb-sync.1/classes:$sdk/platforms/${GB_ANDROID_PLATFORM:-android-37.0}/android.jar:$junit:$hamcrest"
env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS "$jdk/bin/javac" -encoding UTF-8 -source 8 -target 8 -cp "$cp" -d "$tests" \
    "$src/server/src/test/java/com/genymobile/scrcpy/control/ControlMessageReaderTest.java" \
    "$src/server/src/test/java/com/genymobile/scrcpy/video/SyncFrameControlTest.java" \
    "$src/server/src/test/java/com/genymobile/scrcpy/video/RecoveryRateWindowTest.java"
env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS "$jdk/bin/java" -ea -cp "$tests:$cp" org.junit.runner.JUnitCore \
    com.genymobile.scrcpy.control.ControlMessageReaderTest com.genymobile.scrcpy.video.SyncFrameControlTest \
    com.genymobile.scrcpy.video.RecoveryRateWindowTest
