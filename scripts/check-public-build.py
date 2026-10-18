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
for script in ['public-build.py', 'package-macos-direct.py', 'package-android-direct.py',
               'build-macos-dmg-layout.py', 'verify-macos-dmg-layout.py', 'build-android-catalog-device-test.py', 'build-android-clipboard-device-test.py',
               'test-android-direct-components.py', 'bootstrap-build-tools.py',
               'build-internet-runtime.py', 'package-network-helper.py',
               'network-test-guardian.py', 'test-nearby-bootstrap-interop.py',
               'verify-rust-macos-deployment.py', 'test-android-shell-stop.py',
               'build_path_privacy.py', 'check-release-privacy.py', 'test-release-privacy.py',
               'test-application-retirement-ownership.py', 'test-capture-absence-proof.py', 'test-capture-route-recovery.py', 'test-owned-adb-transfer-lifetime.py', 'test-owned-adb-tunnel-generation.py', 'test-scrcpy-adb-owner-lifetime.py']:
    ast.parse((ROOT / 'scripts' / script).read_text(), filename=script)
run([sys.executable, ROOT / 'scripts/test-public-build.py'])
run([sys.executable, ROOT / 'scripts/test-build-path-privacy.py'])
run([sys.executable, ROOT / 'scripts/test-release-privacy.py'])
run([sys.executable, ROOT / 'scripts/test-media-failure-diagnostics.py'])
run([sys.executable, ROOT / 'scripts/test-primary-touch-replay.py'])
run([sys.executable, ROOT / 'scripts/test-application-retirement-ownership.py'])
run([sys.executable, ROOT / 'scripts/test-capture-absence-proof.py'])
run([sys.executable, ROOT / 'scripts/test-capture-route-recovery.py'])
run([sys.executable, ROOT / 'scripts/test-owned-adb-tunnel-generation.py'])
run([sys.executable, ROOT / 'scripts/test-scrcpy-adb-owner-lifetime.py'])
run([sys.executable, ROOT / 'scripts/test-macos-main-bundle-localization.py'])
run([sys.executable, ROOT / 'scripts/test-macos-application-catalog-loader.py'])
run([sys.executable, ROOT / 'scripts/test-macos-application-catalog-decode.py'])
run([sys.executable, ROOT / 'scripts/test-macos-application-icon-refresh.py'])
run([sys.executable, ROOT / 'scripts/test-macos-direct-package.py', '--metadata-only'])
run(['bash', ROOT / 'scripts/test-macos-distribution-resources.sh'])
run(['bash', ROOT / 'scripts/test-macos-dmg-layout.sh'])
run(['bash', ROOT / 'scripts/test-macos-dmg-release-policy.sh'])
run(['swift', ROOT / 'scripts/verify-localizations.swift'])
run(['swift', ROOT / 'scripts/test-app-icons.swift'])
for product in ['GalaxyBridgeCoreSpec', 'GalaxyBridgeProtocolSpec']:
    run(['swift', 'run', '--package-path', ROOT, '--scratch-path', build / 'check-swift', '--cache-path', build / 'dependency-cache/swiftpm', '-j', env.get('GB_BUILD_JOBS', '4'), product])
swift_bin = Path(subprocess.check_output(['swift', 'build', '--package-path', str(ROOT), '--scratch-path', str(build / 'check-swift'), '--show-bin-path'], cwd=ROOT, env=env, text=True).strip())
source_build = Path((build / 'artifacts/scrcpy/SOURCE_BUILD_DIR.txt').read_text().strip())
java = subprocess.check_output(['bash', '-c', 'source "$1"; galaxybridge_select_java_home',
    'bash', str(ROOT / 'scripts/select-java-runtime.sh')], env=env, text=True).strip()
env.update(JAVA_HOME=java, GB_NEARBY_SWIFT_MODULES=str(swift_bin / 'Modules'),
           GB_NEARBY_PROTOC_PLUGIN=str(swift_bin / 'protoc-gen-swift-tool'),
           GB_NEARBY_PROTOC=str(swift_bin / 'protoc-tool'),
           GB_SCRCPY_CLASS_DIR=str(source_build / '4.1/classes'))
env['GB_OWNED_ADB_TEST_RUNTIME'] = str(build / 'artifacts/adb')
run([sys.executable, ROOT / 'scripts/build-android-catalog-device-test.py', '--java-home', java,
     '--output', build / 'device-tests/catalog-check.jar'])
run([sys.executable, ROOT / 'scripts/build-android-clipboard-device-test.py', '--java-home', java,
     '--output', build / 'device-tests/clipboard-input-unsigned.apk'])
for script in ['test-macos-companion-tunnel.sh', 'test-macos-companion-diagnostics.sh', 'test-macos-owned-adb-runtime.sh', 'test-macos-incoming-file-store.sh', 'test-macos-client-setup.sh', 'test-macos-feature-configuration-entrypoint.sh', 'test-companion-transport-interruption.sh', 'test-macos-file-transfer-presentation.sh']:
    run(['sh', ROOT / 'scripts' / script])
for script in ['test-clipboard-agent-protocol.sh', 'test-clipboard-primary-read-admission.sh', 'test-clipboard-callback-lifecycle.sh', 'test-macos-clipboard-polling.sh', 'test-macos-clipboard-hub.sh',
               'test-macos-clipboard-policy.sh', 'test-macos-notification-bridge.sh',
               'test-macos-bonjour-publication.sh', 'test-macos-application-termination-cleanup.sh',
               'test-macos-downloads-access.sh', 'test-macos-video-drawable-retry.sh',
               'test-macos-input-mapping.sh', 'test-phone-display-privacy.sh', 'test-phone-display-interaction.sh', 'test-producer-preparation-reservation.sh', 'test-macos-phone-privacy-entrypoint.sh', 'test-macos-display-power-owner.sh', 'test-macos-display-power-recovery.sh', 'test-phone-privacy-server-ownership.sh', 'test-enhanced-route-handoff.sh',
               'test-camera-extension-policy.sh',
               'test-macos-device-row-merge.sh', 'test-macos-device-selection.sh',
               'test-macos-user-facing-text.sh', 'test-macos-synthetic-text-input.sh', 'test-macos-trackpad-lifecycle.sh',
               'test-macos-native-shortcut-routing.sh', 'test-macos-native-primary-close-command.sh',
               'test-macos-native-close-all-command.sh', 'test-macos-mirror-window-cycle.sh',
               'test-macos-prepared-shell-selection.sh']:
    run(['sh', ROOT / 'scripts' / script])
for script in ['test-nearby-connectivity-policy.sh', 'test-nearby-bootstrap-crypto.sh', 'test-nearby-consent.sh',
               'test-nearby-transport.sh', 'test-nearby-discovery.sh', 'test-raw-channel-upgrade.sh', 'test-shell-relay-diagnostics.sh',
               'test-shell-capability-bridge.sh', 'test-shell-runtime-identity.sh', 'test-display-power-controller.sh', 'test-display-state-snapshot.sh',
               'test-display-state-ownership.sh', 'test-display-state-power-calls.sh', 'test-display-state-runtime.sh', 'test-display-state-controller.sh', 'test-network-helper.sh',
               'test-macos-internet-sharing-lifecycle.sh',
               'test-macos-nearby-preparation.sh', 'test-internet-tunnel-lifecycle.sh']:
    run(['bash', ROOT / 'scripts' / script])
for script in ['test-macos-connectivity-presentation.sh', 'test-macos-nearby-status-dispatch.sh',
               'test-macos-nearby-pairing-promotion.sh', 'test-macos-nearby-pairing-location.sh',
               'test-macos-app-window-frame-publication.sh',
               'test-macos-clipboard-conversion.sh',
               'test-macos-clipboard-conversion-integration.sh',
               'test-macos-notification-cache-maintenance.sh', 'test-macos-notification-ordering.sh', 'test-macos-input-marker.sh']:
    run(['bash', ROOT / 'scripts' / script])
for script in ['test-nearby-bootstrap-interop.py', 'test-network-test-guardian.py']:
    run([sys.executable, ROOT / 'scripts' / script])
# Rust tests compile the source crates; do not depend on frozen release binaries.
run(['bash', ROOT / 'scripts/test-quic-backend.sh'])
run(['bash', ROOT / 'scripts/test-quic-backend-native.sh'])
run(['bash', ROOT / 'scripts/test-quic-media-contract.sh'])
run(['bash', ROOT / 'scripts/test-quic-transport.sh'])
run(['bash', ROOT / 'scripts/test-scrcpy-gb-sync.sh', source_build])
run(['bash', ROOT / 'android/gradlew', '-p', ROOT / 'android', ':app:testDirectDebugUnitTest', ':companion-core:testDebugUnitTest', '--console=plain'], {'JAVA_HOME': java})
for script in ['test-android-shell-stop.py', 'test-android-nearby-discovery.py']:
    # Gradle has now resolved the pinned compiler and JUnit dependencies into
    # this build's cache; standalone compiler fixtures must not need a home cache.
    run([sys.executable, ROOT / 'scripts' / script], {'JAVA_HOME': java})
print('Public source checks passed. No clean-device, GUI, or hardware acceptance claimed.')
