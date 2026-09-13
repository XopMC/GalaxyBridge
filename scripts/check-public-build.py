#!/usr/bin/env python3
"""Portable, bounded source checks. No personal fixtures, UI, keychain or devices."""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--build-dir', type=Path, required=True)
a = p.parse_args(); build = a.build_dir.resolve()
env = dict(os.environ, GB_PRODUCER_JAR=str(build / 'artifacts/scrcpy/scrcpy-server-4.1-gb-sync.1'), GB_BUILD_DIR=str(build / 'native-build/check'), GB_BUILD_JOBS=os.environ.get('GB_BUILD_JOBS', '4'))
# Source-only runs have no runtime trust; after native builds, test the exact
# compiled pin module against the fresh producer artifact independently.
if (build / 'BuildArtifacts.json').is_file():
    import importlib.util
    spec = importlib.util.spec_from_file_location('public_build', ROOT / 'scripts/public-build.py')
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    generated, _ = module.generate_pins(build)
    env['GB_BUILD_PINS_DIRECTORY'] = str(generated.relative_to(ROOT))
    env['GB_EXPECTED_SCRCPY_SHA'] = module.sha(build / 'artifacts/scrcpy/scrcpy-server-v4.1')
def run(args, extra=None):
    subprocess.run([str(x) for x in args], cwd=ROOT, env=dict(env, **(extra or {})), check=True)
for script in ['public-build.py', 'package-macos-direct.py', 'package-android-direct.py', 'bootstrap-build-tools.py']:
    ast.parse((ROOT / 'scripts' / script).read_text(), filename=script)
run([sys.executable, ROOT / 'scripts/test-public-build.py'])
run([sys.executable, ROOT / 'scripts/test-macos-direct-package.py', '--metadata-only'])
run(['swift', ROOT / 'scripts/verify-localizations.swift'])
run(['swift', ROOT / 'scripts/test-app-icons.swift'])
for product in ['GalaxyBridgeCoreSpec', 'GalaxyBridgeProtocolSpec']:
    run(['swift', 'run', '--package-path', ROOT, '--scratch-path', build / 'check-swift', '--cache-path', build / 'dependency-cache/swiftpm', '-j', env.get('GB_BUILD_JOBS', '4'), product])
env['GB_OWNED_ADB_TEST_RUNTIME'] = str(build / 'artifacts/adb')
for script in ['test-macos-companion-diagnostics.sh', 'test-macos-owned-adb-runtime.sh', 'test-macos-incoming-file-store.sh', 'test-macos-client-setup.sh', 'test-macos-file-transfer-presentation.sh']:
    run(['sh', ROOT / 'scripts' / script])
# Rust tests compile the source crates; do not depend on frozen release binaries.
run(['bash', ROOT / 'scripts/test-quic-backend.sh'])
run(['bash', ROOT / 'scripts/test-quic-backend-native.sh'])
run(['bash', ROOT / 'scripts/test-quic-media-contract.sh'])
run(['bash', ROOT / 'scripts/test-quic-transport.sh'])
source_build = Path((build / 'artifacts/scrcpy/SOURCE_BUILD_DIR.txt').read_text().strip())
run(['bash', ROOT / 'scripts/test-scrcpy-gb-sync.sh', source_build])
java = subprocess.check_output(['bash', '-c', 'source "$1"; galaxybridge_select_java_home',
    'bash', str(ROOT / 'scripts/select-java-runtime.sh')], env=env, text=True).strip()
run(['bash', ROOT / 'android/gradlew', '-p', ROOT / 'android', ':app:testDirectDebugUnitTest', ':companion-core:testDebugUnitTest', '--console=plain'], {'JAVA_HOME': java})
print('Public source checks passed. No clean-device, GUI, or hardware acceptance claimed.')
