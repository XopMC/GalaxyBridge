#!/usr/bin/env python3
"""Focused cached compiler checks; never invokes Gradle, a device or a radio."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
def jar(group, artifact, version):
    return str(next((cache / group / artifact / version).glob('*/*.jar')))
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
    subprocess.run(list(map(str, args)), check=True)
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
    android = Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))) / 'platforms/android-37.0/android.jar'
    compile_kotlin([base / 'NearbyBlePeripheral.kt', base / 'NearbyAdvertisingLifecycle.kt',
                    base / 'NearbyFrameDecoder.kt', base / 'NearbyDiscoveryRecovery.kt',
                    tests / 'NearbyAdvertisingLifecycleTest.kt', tests / 'NearbyDiscoveryRecoveryTest.kt'],
                   [str(tmp), stdlib, coroutines, str(android), junit])
    run(['java', '-cp', os.pathsep.join([str(tmp), stdlib, coroutines, junit, hamcrest]), 'org.junit.runner.JUnitCore',
         'com.xopmc.galaxybridge.nearby.NearbyAdvertisingLifecycleTest',
         'com.xopmc.galaxybridge.nearby.NearbyDiscoveryRecoveryTest'])
    print('PASS actual Android BLE source compiles against Android 37; no radio calls')
