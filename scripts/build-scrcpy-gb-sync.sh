#!/usr/bin/env bash
# Build stock and producer-sync servers from one verified upstream source archive.
set -euo pipefail
export LC_ALL=C TZ=UTC
root=$(cd "$(dirname "$0")/.." && pwd)
bundle="$root/third_party/scrcpy-gb-sync"
cache="${GB_BUILD_DIR:-$root/build/native/scrcpy-build}"
mkdir -p "$cache"
cache=$(cd "$cache" && pwd)
out="${GB_OUTPUT_DIR:-$root/build/native/scrcpy}"
mkdir -p "$out"
out=$(cd "$out" && pwd)
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
jdk="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"
platform="$sdk/platforms/${GB_ANDROID_PLATFORM:-android-37.0}"
build_tools="$sdk/build-tools/${GB_ANDROID_BUILD_TOOLS:-37.0.0}"
for tool in "$jdk/bin/java" "$jdk/bin/javac" "$build_tools/aidl"; do
    [[ -x "$tool" ]] || { echo "Missing tool: $tool" >&2; exit 1; }
done
for input in "$platform/android.jar" "$platform/framework.aidl" "$build_tools/lib/d8.jar" "$build_tools/core-lambda-stubs.jar"; do
    [[ -f "$input" ]] || { echo "Missing Android SDK input: $input" >&2; exit 1; }
done
commit=2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0
archive="${GB_SYNC_ARCHIVE:-$cache/scrcpy-$commit.tar.gz}"
if [[ ! -f "$archive" ]]; then
    [[ "${GB_OFFLINE:-0}" != 1 ]] || { echo 'Pinned scrcpy source archive unavailable offline' >&2; exit 1; }
    curl --fail --location --retry 3 "https://codeload.github.com/Genymobile/scrcpy/tar.gz/$commit" -o "$archive.download"
    mv "$archive.download" "$archive"
fi
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == c4c2ae8d32a1429b355b1438d5b4a842a8882ae1792bd984438d60e98252c51c ]] || { echo 'scrcpy archive hash mismatch' >&2; exit 1; }
(cd "$bundle" && shasum -a 256 -c PATCHES.sha256)
prefix=scrcpy-$commit
tar -tzf "$archive" | awk -v p="$prefix/" 'index($0,p)!=1 || $0 ~ /(^|\/)\.\.(\/|$)/ {exit 1}'
tar -tvzf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}'
work=$(mktemp -d "$cache/source-build.XXXXXX")
tar -xzf "$archive" -C "$work"
src="$work/$prefix"
cp "$bundle/ClipboardAgent.java" "$src/server/src/main/java/com/genymobile/scrcpy/ClipboardAgent.java"
build_server() {
    local version="$1" dest="$work/$1"
    mkdir -p "$dest/gen/com/genymobile/scrcpy" "$dest/classes"
    printf '%s\n' 'package com.genymobile.scrcpy;' 'public final class BuildConfig {' 'public static final boolean DEBUG = false;' "public static final String VERSION_NAME = \"$version\";" '}' > "$dest/gen/com/genymobile/scrcpy/BuildConfig.java"
    (cd "$src/server/src/main/aidl"
     "$build_tools/aidl" -o"$dest/gen" -I. android/content/IOnPrimaryClipChangedListener.aidl
     "$build_tools/aidl" -o"$dest/gen" -I. -p "$platform/framework.aidl" android/view/IDisplayWindowListener.aidl)
    (cd "$src/server/src/main/java"
     env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS "$jdk/bin/javac" -encoding UTF-8 -bootclasspath "$platform/android.jar" \
        -cp "$build_tools/core-lambda-stubs.jar:$dest/gen" -d "$dest/classes" -source 1.8 -target 1.8 \
        android/content/*.java com/genymobile/scrcpy/*.java com/genymobile/scrcpy/{audio,control,device,display,model,opengl,util,video,wrappers}/*.java)
    (cd "$dest/classes"
     find . -name '*.class' -type f | LC_ALL=C sort > "$dest/d8-inputs.txt"
     env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS "$jdk/bin/java" -cp "$build_tools/lib/d8.jar" com.android.tools.r8.D8 \
        --classpath "$platform/android.jar" --min-api 31 --output "$dest/classes.zip" @"$dest/d8-inputs.txt")
    local artifact="scrcpy-server-v$version"
    [[ "$version" != 4.1-gb-sync.1 ]] || artifact="scrcpy-server-$version"
    cp "$dest/classes.zip" "$out/$artifact"
}
build_server 4.1
patch --batch --fuzz=0 -p1 -d "$src" < "$bundle/patches/0001-request-sync-frame.patch"
patch --batch --fuzz=0 -p1 -d "$src" < "$bundle/patches/0002-defer-sync-to-rate-slot.patch"
build_server 4.1-gb-sync.1
(cd "$out" && shasum -a 256 scrcpy-server-v4.1 scrcpy-server-4.1-gb-sync.1 > SHA256SUMS)
{ "$jdk/bin/java" -version 2>&1; shasum -a 256 "$archive" "$platform/android.jar" "$build_tools/lib/d8.jar"; } > "$out/BUILD-INPUTS.txt"
printf '%s\n' "$work" > "$out/SOURCE_BUILD_DIR.txt"
printf 'BUILD_DIR=%s\nSOURCE_BUILD_DIR=%s\n' "$out" "$work"
cat "$out/SHA256SUMS"
