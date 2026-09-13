#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GB_NATIVE_COMPONENT=file-receiver
source "$GB_ROOT/scripts/native-build-env.sh"
GB_MANIFEST="$GB_ROOT/native/galaxybridge-file-receiver/Cargo.toml"
GB_SOURCE_SHA=$(python3 - "$GB_ROOT/native/galaxybridge-file-receiver" <<'PY'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1]); digest=hashlib.sha256()
for path in sorted([root/'Cargo.toml',root/'Cargo.lock',*root.joinpath('src').glob('*.rs')]):
    digest.update(path.relative_to(root).as_posix().encode()+b'\0'+path.read_bytes()+b'\0')
print(digest.hexdigest())
PY
)
GB_OUTPUT="${GB_OUTPUT_DIR:-$GB_BUILD_DIR/file-receiver}"
mkdir -p "$GB_OUTPUT"
"$GB_CARGO" build "${GB_CARGO_NETWORK[@]}" --release --manifest-path "$GB_MANIFEST" --target aarch64-apple-darwin
cp "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/galaxybridge-file-receiver" "$GB_OUTPUT/galaxybridge-file-receiver-macos-arm64"
prepare_android
"$GB_CARGO" build "${GB_CARGO_NETWORK[@]}" --release --manifest-path "$GB_MANIFEST" --target aarch64-linux-android
cp "$CARGO_TARGET_DIR/aarch64-linux-android/release/galaxybridge-file-receiver" "$GB_OUTPUT/galaxybridge-file-receiver-android-arm64"
inspect_android "$GB_OUTPUT/galaxybridge-file-receiver-android-arm64" "$GB_OUTPUT/android-elf.txt"
"$GB_CARGO" metadata --manifest-path "$GB_MANIFEST" "${GB_CARGO_NETWORK[@]}" --format-version 1 > "$GB_OUTPUT/metadata-build-input.json"
python3 - "$GB_OUTPUT" "$GB_SOURCE_SHA" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); metadata=json.loads((root/'metadata-build-input.json').read_text())
packages=[]; notices=[]
for package in sorted(metadata['packages'],key=lambda x:x['name']):
    if package['name']=='galaxybridge-file-receiver': continue
    packages.append({'name':package['name'],'version':package['version'],'license':package['license'],
                     'source':package['source'],'url':f"https://crates.io/crates/{package['name']}/{package['version']}"})
    path=pathlib.Path(package['manifest_path']).parent
    for license_file in sorted(path.glob('LICENSE*')):
        if license_file.is_file(): notices.append(f"\n=== {package['name']} {package['version']} / {license_file.name} ===\n"+license_file.read_text())
(root/'DEPENDENCIES.json').write_text(json.dumps({'source_sha256':sys.argv[2],'packages':packages},indent=2)+'\n')
(root/'THIRD_PARTY_NOTICES.txt').write_text('Galaxy Bridge file receiver third-party licenses\n'+''.join(notices))
(root/'metadata-build-input.json').unlink()
files=['galaxybridge-file-receiver-macos-arm64','galaxybridge-file-receiver-android-arm64','DEPENDENCIES.json','THIRD_PARTY_NOTICES.txt']
(root/'SHA256SUMS').write_text(''.join(hashlib.sha256((root/name).read_bytes()).hexdigest()+'  '+name+'\n' for name in files))
print(root)
print((root/'SHA256SUMS').read_text())
PY
