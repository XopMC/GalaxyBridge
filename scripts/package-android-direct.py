#!/usr/bin/env python3
"""Build a public Direct APK; unsigned by default, externally signed when configured.

Never reads or creates a personal signing identity. Supply all four
GB_ANDROID_DIRECT_* variables to produce an installable signed release APK.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('output', type=Path)
a = p.parse_args()
output = a.output.resolve()
sidecars = [output, output.with_suffix('.signature.txt'), output.with_suffix('.sha256')]
if any(path.exists() or path.is_symlink() for path in sidecars):
    raise SystemExit('Output already exists; choose a fresh APK path.')
env = os.environ.copy()
keys = ['GB_ANDROID_DIRECT_KEYSTORE', 'GB_ANDROID_DIRECT_KEYSTORE_PASSWORD',
        'GB_ANDROID_DIRECT_KEY_ALIAS', 'GB_ANDROID_DIRECT_KEY_PASSWORD']
signed = all(env.get(key) for key in keys)
if any(env.get(key) for key in keys) and not signed:
    raise SystemExit('External signing requires all four GB_ANDROID_DIRECT_* inputs.')
if not signed:
    env['GB_ANDROID_ALLOW_UNSIGNED'] = '1'
env['JAVA_HOME'] = subprocess.check_output(['bash', '-c', 'source "$1"; galaxybridge_select_java_home',
    'bash', str(ROOT / 'scripts/select-java-runtime.sh')], env=env, text=True).strip()
sdk = Path(env.get('ANDROID_SDK_ROOT') or env.get('ANDROID_HOME') or Path.home() / 'Library/Android/sdk')
env['ANDROID_HOME'] = env['ANDROID_SDK_ROOT'] = str(sdk)
subprocess.run(['bash', str(ROOT / 'android/gradlew'), '-p', str(ROOT / 'android'),
                ':app:assembleDirectRelease', '--console=plain', '--no-build-cache', '--rerun-tasks'], env=env, check=True)
name = 'app-direct-release.apk' if signed else 'app-direct-release-unsigned.apk'
apk = ROOT / 'android/app/build/outputs/apk/direct/release' / name
build_tools = sdk / 'build-tools/37.0.0'
badging = subprocess.check_output([str(build_tools / 'aapt2'), 'dump', 'badging', str(apk)], text=True)
if "package: name='com.xopmc.galaxybridge'" not in badging or 'application-debuggable' in badging:
    raise SystemExit('Expected a non-debuggable public APK.')
xml = subprocess.check_output([str(build_tools / 'aapt2'), 'dump', 'xmltree', str(apk), '--file', 'AndroidManifest.xml'], text=True)
if any(name in xml for name in ('MotionQaActivity', 'TextInputQaActivity', 'InputLatencyQaActivity', 'ClipboardQaReceiver', 'DownloadsProviderQaReceiver')):
    raise SystemExit('Internal QA components are forbidden in the public APK.')
subprocess.run([os.fspath(ROOT / 'scripts/test-android-direct-components.py'), apk], check=True)
signature = 'UNSIGNED: not installable until signed with your own stable Android release identity.\n'
if signed:
    signature = subprocess.check_output([str(build_tools / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)], env=env, text=True)
    if 'Android Debug' in signature:
        raise SystemExit('Debug signing is not a release identity.')
output.parent.mkdir(parents=True, exist_ok=True)
with output.open('xb') as dst, apk.open('rb') as src:
    shutil.copyfileobj(src, dst)
output.with_suffix('.signature.txt').write_text(signature)
output.with_suffix('.sha256').write_text(hashlib.sha256(output.read_bytes()).hexdigest() + '  ' + output.name + '\n')
print(('Signed' if signed else 'Unsigned') + ' Direct APK: ' + str(output))
