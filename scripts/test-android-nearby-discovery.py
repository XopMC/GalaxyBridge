#!/usr/bin/env python3
"""Focused cached compiler checks; never invokes Gradle, a device or a radio."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))) / 'caches/modules-2/files-2.1'
def jar(group, artifact, version):
    candidates = sorted((cache / group / artifact / version).glob('*/*.jar'))
    if not candidates:
        raise SystemExit(f'Missing Gradle dependency {group}:{artifact}:{version}; run :app:testDirectDebugUnitTest with the same GRADLE_USER_HOME first.')
    return str(candidates[0])
stdlib = jar('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.10')
junit = jar('junit', 'junit', '4.13.2')
hamcrest = jar('org.hamcrest', 'hamcrest-core', '1.3')
coroutines = jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.10.2')
compiler = os.pathsep.join([
    jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.10'), stdlib,
    jar('org.jetbrains.kotlin', 'kotlin-build-tools-api', '2.4.10'),
    jar('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.4.10'),
    jar('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
    jar('org.jetbrains.kotlin', 'kotlin-daemon-embeddable', '2.4.10'),
    jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
    jar('org.jetbrains', 'annotations', '13.0'),
])
base = root / 'android/app/src/main/java/com/xopmc/galaxybridge/nearby'
tests = root / 'android/app/src/test/java/com/xopmc/galaxybridge/nearby'
def run(args):
    command = list(map(str, args))
    if command[0] in ('java', 'javac') and os.environ.get('JAVA_HOME'):
        command[0] = str(Path(os.environ['JAVA_HOME']) / 'bin' / command[0])
    subprocess.run(command, check=True)
with tempfile.TemporaryDirectory(prefix='gb-android-nearby-discovery-') as temporary:
    tmp = Path(temporary)
    run(['javac', '-cp', junit, '-d', tmp, base / 'NearbyDiscoveryMetadata.java', tests / 'NearbyDiscoveryMetadataTest.java'])
    run(['java', '-cp', os.pathsep.join([str(tmp), junit, hamcrest]), 'org.junit.runner.JUnitCore',
         'com.xopmc.galaxybridge.nearby.NearbyDiscoveryMetadataTest'])
    source = (base / 'NearbyBlePeripheral.kt').read_text()
    start = source.index('                override fun onCharacteristicReadRequest(')
    end = source.index('                override fun onCharacteristicWriteRequest(', start)
    callback = source[start:end].replace('override fun', 'fun').replace('BluetoothDevice', 'DiscoveryReadDevice') \
        .replace('BluetoothGattCharacteristic', 'DiscoveryReadCharacteristic').replace('BluetoothGatt.', 'DiscoveryReadGatt.')
    fixture = (root / 'scripts/fixtures/NearbyDiscoveryReadSpec.kt').read_text().replace('    // ACTUAL_READ_CALLBACK', callback)
    (tmp / 'ActualRead.kt').write_text(fixture)
    def compile_kotlin(files, classpath):
        run(['java', '-cp', compiler, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
             '-jvm-target', '17', '-classpath', os.pathsep.join(classpath), '-d', tmp, *files])
    compile_kotlin([tmp / 'ActualRead.kt'], [str(tmp), stdlib])
    run(['java', '-cp', os.pathsep.join([str(tmp), stdlib]), 'com.xopmc.galaxybridge.nearby.NearbyDiscoveryReadSpec'])
    sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME') or str(Path.home() / 'Library/Android/sdk')
    android = Path(sdk) / 'platforms' / os.environ.get('GB_ANDROID_PLATFORM', 'android-37.0') / 'android.jar'
    compile_kotlin([base / 'NearbyBlePeripheral.kt', base / 'NearbyAdvertisingLifecycle.kt',
                    base / 'NearbyFrameDecoder.kt', base / 'NearbyDiscoveryRecovery.kt',
                    tests / 'NearbyAdvertisingLifecycleTest.kt', tests / 'NearbyDiscoveryRecoveryTest.kt'],
                   [str(tmp), stdlib, coroutines, str(android), junit])
    run(['java', '-cp', os.pathsep.join([str(tmp), stdlib, coroutines, junit, hamcrest]), 'org.junit.runner.JUnitCore',
         'com.xopmc.galaxybridge.nearby.NearbyAdvertisingLifecycleTest',
         'com.xopmc.galaxybridge.nearby.NearbyDiscoveryRecoveryTest'])
    runtime = (base / 'ForegroundConnectivityRuntime.kt').read_text()
    def block(text, marker):
        start = text.index(marker)
        opening = text.index('{', start)
        depth = 0
        for end in range(opening, len(text)):
            if text[end] == '{': depth += 1
            elif text[end] == '}':
                depth -= 1
                if depth == 0: return text[start:end+1], text[opening+1:end]
        raise RuntimeError(marker)
    fixture = (root / 'scripts/fixtures/NearbyDiscoveryStatusSpec.kt').read_text()
    fixture = fixture.replace('        // ACTUAL_DISCOVERY_ERROR_CALLBACK', block(runtime, '        onError = {')[1])
    fixture = fixture.replace('        // ACTUAL_DISCOVERY_STARTED_CALLBACK', block(runtime, '        onStarted = {')[1])
    fixture = fixture.replace('    // ACTUAL_DISCOVERY_REFRESH', block(runtime, '    fun refresh()')[0])
    (tmp / 'ActualStatus.kt').write_text(fixture)
    compile_kotlin([tmp / 'ActualStatus.kt', base / 'NearbyAdvertisingLifecycle.kt', base / 'NearbyDiscoveryRecovery.kt'],
                   [str(tmp), stdlib, coroutines, junit])
    run(['java', '-cp', os.pathsep.join([str(tmp), stdlib, coroutines, junit, hamcrest]), 'org.junit.runner.JUnitCore',
         'com.xopmc.galaxybridge.nearby.NearbyDiscoveryStatusSpec'])
    activity = (root / 'android/app/src/main/java/com/xopmc/galaxybridge/MainActivity.kt').read_text()
    fixture = (root / 'scripts/fixtures/NearbyBluetoothEnableSpec.kt').read_text()
    for placeholder, marker, fallback in [
        ('ACTUAL_REQUEST_NEARBY', '    private fun requestNearbyEnable()', ''),
        ('ACTUAL_CONTINUE_NEARBY', '    private fun continueNearbyEnable(', ''),
        ('ACTUAL_RADIO_STATE', '    private fun bluetoothRadioEnabled()', 'fun bluetoothRadioEnabled(): Boolean? = bluetooth.adapter?.isEnabled'),
        ('ACTUAL_REQUEST_BLUETOOTH', '    private fun requestBluetoothEnableIfNeeded(', 'fun requestBluetoothEnableIfNeeded(explicitRequest: Boolean) = false'),
        ('ACTUAL_COMPLETE_BLUETOOTH', '    private fun completeBluetoothEnable()', 'fun completeBluetoothEnable() { bluetoothEnableInFlight = false; pendingNearbyEnable.cancel() }'),
    ]:
        method = block(activity, marker)[0].replace('private fun', 'fun', 1) if marker in activity else fallback
        fixture = fixture.replace('    // ' + placeholder, method)
    if '    private fun finishAutomaticSetup()' in activity:
        finish = block(activity, '    private fun finishAutomaticSetup()')[0].replace('private fun', 'fun', 1)
    else:
        finish = 'fun finishAutomaticSetup() {' + block(activity, '                AutomaticSetupStep.Finish -> {')[1] + '}'
    fixture = fixture.replace('    // ACTUAL_FINISH_SETUP', finish)
    (tmp / 'ActualBluetoothEnable.kt').write_text(fixture)
    policy = base / 'NearbyBluetoothEnablePolicy.kt'
    compile_kotlin([tmp / 'ActualBluetoothEnable.kt'] + ([policy, tests / 'NearbyBluetoothEnablePolicyTest.kt'] if policy.exists() else []), [str(tmp), stdlib, junit])
    run(['java', '-cp', os.pathsep.join([str(tmp), stdlib, junit, hamcrest]), 'org.junit.runner.JUnitCore',
         'com.xopmc.galaxybridge.nearby.NearbyBluetoothEnableSpec',
         *(['com.xopmc.galaxybridge.nearby.NearbyBluetoothEnablePolicyTest'] if policy.exists() else [])])
    setup = root / 'android/app/src/main/java/com/xopmc/galaxybridge/setup'
    setup_tests = root / 'android/app/src/test/java/com/xopmc/galaxybridge/setup'
    compile_kotlin([setup / 'AutomaticPermissionSetup.kt', setup / 'SetupStateResolver.kt', setup / 'ExplicitPermissionPolicy.kt',
                    setup_tests / 'AutomaticPermissionSetupTest.kt', setup_tests / 'ExplicitPermissionPolicyTest.kt'],
                   [str(tmp), stdlib, junit])
    run(['java', '-cp', os.pathsep.join([str(tmp), stdlib, junit, hamcrest]), 'org.junit.runner.JUnitCore',
         'com.xopmc.galaxybridge.setup.AutomaticPermissionSetupTest',
         'com.xopmc.galaxybridge.setup.ExplicitPermissionPolicyTest'])
    print('PASS actual Android BLE source compiles against Android 37; no radio calls')
