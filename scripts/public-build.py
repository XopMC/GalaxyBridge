#!/usr/bin/env python3
"""CMake's build executor. All artifacts originate in this checkout's source builds."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def build_environment(build, inherited):
    environment = dict(inherited, MACOSX_DEPLOYMENT_TARGET='14.0',
                       CARGO_HOME=str(build / 'dependency-cache/cargo'),
                       CARGO_PROFILE_DEV_DEBUG='0', CARGO_PROFILE_TEST_DEBUG='0',
                       GRADLE_USER_HOME=str(build / 'dependency-cache/gradle'))
    environment['PATH'] = str(build / 'tools/bin') + os.pathsep + environment.get('PATH', '')
    return environment

def run(arguments, env):
    subprocess.run([str(x) for x in arguments], cwd=ROOT, env=env, check=True)

def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()

def generate_pins(build):
    artifacts = build / 'artifacts'
    paths = {
        'adbSHA': artifacts / 'adb/adb',
        'libusbSHA': artifacts / 'adb/libusb-1.0.0.dylib',
        'quicAndroidSHA': artifacts / 'quic-backend/gb-quic-backend-android-arm64',
        'producerSHA': artifacts / 'scrcpy/scrcpy-server-4.1-gb-sync.1',
        'scrcpySHA': artifacts / 'scrcpy/scrcpy-server-v4.1',
    }
    pins = {key: sha(path) for key, path in paths.items()}
    pins['quicHostSHA'] = sha(artifacts / 'quic-backend/libgalaxybridge_quic_backend-macos-arm64.a')
    identity = hashlib.sha256(json.dumps(pins, sort_keys=True).encode()).hexdigest()
    generated = ROOT / '.build/public-pins' / identity
    generated.mkdir(parents=True, exist_ok=True)
    source = '// Generated from this build; expected bytes are compiled into the executable.\npublic enum GalaxyBridgeBuildPins {\n'
    source += ''.join(f'    public static let {key} = "{value}"\n' for key, value in pins.items()) + '}\n'
    pin_source = generated / 'BuildPins.swift'
    if not pin_source.exists() or pin_source.read_text() != source:
        pin_source.write_text(source)
    manifest = build / 'BuildArtifacts.json'
    metadata = json.dumps(pins, indent=2) + '\n'
    if not manifest.exists() or manifest.read_text() != metadata:
        manifest.write_text(metadata)
    return generated, identity

def native(build, env):
    artifacts = build / 'artifacts'; artifacts.mkdir(parents=True, exist_ok=True)
    for component, script in [('scrcpy', 'build-scrcpy-gb-sync.sh'), ('quic-backend', 'build-quic-backend.sh')]:
        settings = dict(env, GB_OUTPUT_DIR=str(artifacts / component), GB_BUILD_DIR=str(build / 'native-build' / component), GB_PRODUCER_JAR=str(artifacts / 'scrcpy/scrcpy-server-4.1-gb-sync.1'))
        run(['bash', ROOT / 'scripts' / script], settings)
    runtime = artifacts / 'adb'
    if not runtime.exists():
        run(['bash', ROOT / 'scripts/build-owned-adb.sh', runtime],
            dict(env, GB_OWNED_ADB_BUILD_ROOT=str(build / 'native-build/adb')))
    else:
        provenance = json.loads((runtime / 'PROVENANCE.json').read_text())
        patches = {p.name: sha(p) for p in (ROOT / 'third_party/adb-owned/patches').glob('*.patch')}
        if provenance.get('patches_sha256') != patches:
            raise SystemExit('ADB source patches changed; remove this build tree and rebuild native.')
        if provenance.get('staging_script_sha256') != sha(ROOT / 'scripts/stage-redistributable-adb.py'):
            with tempfile.TemporaryDirectory(prefix='adb-restage-', dir=artifacts) as temporary:
                staged = Path(temporary) / 'runtime'
                run(['bash', ROOT / 'scripts/build-owned-adb.sh', staged],
                    dict(env, GB_OWNED_ADB_BUILD_ROOT=str(build / 'native-build/adb')))
                shutil.rmtree(runtime)  # Replace only this executor's declared generated runtime.
                shutil.move(staged, runtime)
        else:
            run([sys.executable, ROOT / 'scripts/test-owned-adb-artifact.py', runtime / 'adb'], env)
    generate_pins(build)

def macos_app(build, env):
    generated, identity = generate_pins(build)
    archive = build / 'artifacts/quic-backend/libgalaxybridge_quic_backend-macos-arm64.a'
    swift_env = dict(env, GALAXYBRIDGE_APP_STORE="0", GB_QUIC_BACKEND_LIBRARY=str(archive), GB_BUILD_PINS_DIRECTORY=str(generated.relative_to(ROOT)))
    scratch = build / 'swift' / identity
    run(['swift', 'build', '--package-path', ROOT, '--scratch-path', scratch, '--cache-path', build / 'dependency-cache/swiftpm', '-c', 'release', '--product', 'GalaxyBridgeMac', '-j', env.get('GB_BUILD_JOBS', '4')], swift_env)
    binary_directory = Path(subprocess.check_output(['swift', 'build', '--package-path', str(ROOT), '--scratch-path', str(scratch), '--cache-path', str(build / 'dependency-cache/swiftpm'), '-c', 'release', '--show-bin-path'], cwd=ROOT, env=swift_env, text=True).strip())
    output = build / 'artifacts/GalaxyBridge.app'
    staging = build / 'app-staging'
    if staging.exists(): shutil.rmtree(staging)
    app = staging / 'GalaxyBridge.app'; contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    resources = contents / 'Resources'; resources.mkdir()
    shutil.copy2(binary_directory / 'GalaxyBridgeMac', contents / 'MacOS/GalaxyBridgeMac')
    info = plistlib.loads((ROOT / 'macos/GalaxyBridgeMac/Info.plist').read_bytes())
    info.update(CFBundleIdentifier='com.xopmc.GalaxyBridge', CFBundleName='Galaxy Bridge',
                CFBundleExecutable='GalaxyBridgeMac', GalaxyBridgeDistribution='github-direct',
                GalaxyBridgeReleaseStatus='candidate', GalaxyBridgeCameraExtensionProvisioned=False,
                CFBundleShortVersionString='0.1.0', CFBundleVersion='1')
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    bundle = binary_directory / 'GalaxyBridge_GalaxyBridgeMac.bundle'
    shutil.copytree(bundle, resources / bundle.name)
    for locale in bundle.glob('*.lproj'): shutil.copytree(locale, resources / locale.name)
    for filename in ['GalaxyBridge.icns', 'PrivacyInfo.xcprivacy']:
        shutil.copy2(ROOT / 'macos/GalaxyBridgeMac/Resources' / filename, resources / filename)
    shutil.copy2(build / 'BuildArtifacts.json', resources / 'BuildArtifacts.json')
    shutil.copy2(build / 'artifacts/scrcpy/scrcpy-server-v4.1', resources / 'scrcpy-server-v4.1')
    quic = resources / 'quic'; quic.mkdir()
    shutil.copy2(build / 'artifacts/scrcpy/scrcpy-server-4.1-gb-sync.1', quic / 'scrcpy-server-4.1-gb-sync.1')
    shutil.copy2(build / 'artifacts/quic-backend/gb-quic-backend-android-arm64', quic / 'gb-quic-backend-android-arm64')
    shutil.copytree(build / 'artifacts/adb', resources / 'platform-tools')
    extension = contents / 'Library/SystemExtensions/com.xopmc.GalaxyBridge.CameraExtension.systemextension'
    (extension / 'Contents/MacOS').mkdir(parents=True)
    extension_sources = sorted((ROOT / 'macos/GalaxyBridgeCameraExtension').glob('*.swift'))
    run(['xcrun', 'swiftc', '-O', '-whole-module-optimization', '-target', 'arm64-apple-macos14.0', *extension_sources,
         '-o', extension / 'Contents/MacOS/GalaxyBridgeCameraExtension'], env)
    ei = plistlib.loads((ROOT / 'macos/GalaxyBridgeCameraExtension/Info.plist').read_bytes())
    ei.update(CFBundleExecutable='GalaxyBridgeCameraExtension', CFBundleIdentifier='com.xopmc.GalaxyBridge.CameraExtension',
              CFBundleShortVersionString='0.1.0', CFBundleVersion='1', CMIOExtensionMachServiceName='group.com.xopmc.GalaxyBridge.CameraExtension')
    (extension / 'Contents/Info.plist').write_bytes(plistlib.dumps(ei))
    run(['codesign', '--force', '--timestamp=none', '--sign', '-', extension], env)
    run(['codesign', '--force', '--timestamp=none', '--sign', '-', app], env)
    run(['codesign', '--verify', '--deep', '--strict', app], env)
    if output.exists(): shutil.rmtree(output)  # Only CMake's declared app output, never an installed app.
    shutil.move(app, output)
    staging.rmdir()
    print('Built source app: ' + str(output))

def android_apk(build, env):
    signed = bool(env.get('GB_ANDROID_DIRECT_KEYSTORE'))
    output = build / 'artifacts' / ('GalaxyBridge-0.1.0-direct.apk' if signed else 'GalaxyBridge-0.1.0-direct-unsigned.apk')
    # Gradle builds incrementally; remove only this executor's declared outputs.
    for path in (output, output.with_suffix('.signature.txt'), output.with_suffix('.sha256')):
        if path.exists(): path.unlink()
    run([sys.executable, ROOT / 'scripts/package-android-direct.py', output], env)

def package(build, env):
    output = build / 'packages'
    if output.exists(): raise SystemExit('Package directory exists; choose a fresh build tree or move its packages directory. Never overwritten.')
    run([sys.executable, ROOT / 'scripts/package-macos-direct.py', build / 'artifacts/GalaxyBridge.app', output,
         '--adb-runtime', build / 'artifacts/adb', '--release'], env)
    for apk in (build / 'artifacts').glob('GalaxyBridge-0.1.0-direct*.apk'):
        for path in (apk, apk.with_suffix('.signature.txt'), apk.with_suffix('.sha256')):
            shutil.copy2(path, output / path.name)
    lines = [sha(p) + '  ' + p.name for p in sorted(output.iterdir()) if p.suffix in ('.dmg', '.apk')]
    (output / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')

def check(build, env):
    run([sys.executable, ROOT / 'scripts/check-public-build.py', '--build-dir', build], env)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['native', 'macos-app', 'android-apk', 'package', 'check'])
    parser.add_argument('--build-dir', type=Path, required=True)
    args = parser.parse_args(); build = args.build_dir.resolve(); build.mkdir(parents=True, exist_ok=True)
    environment = build_environment(build, os.environ)
    {'native': native, 'macos-app': macos_app, 'android-apk': android_apk, 'package': package, 'check': check}[args.action](build, environment)
