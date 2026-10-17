#!/usr/bin/env python3
"""Run exact Runtime STOP completion and lease tests without Gradle or Android."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
cache = Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')) / 'caches/modules-2/files-2.1'
java = str(Path(os.environ['JAVA_HOME']) / 'bin/java') if os.environ.get('JAVA_HOME') else 'java'

def jar(group, artifact, version):
    candidates = sorted((cache / group / artifact / version).glob('*/*.jar'))
    if not candidates:
        raise SystemExit(f'Missing cached {artifact}:{version}; run Android unit tests with the same GRADLE_USER_HOME first.')
    return str(candidates[0])

def run(args):
    subprocess.run(list(map(str, args)), check=True)

stdlib = jar('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.10')
junit = jar('junit', 'junit', '4.13.2')
hamcrest = jar('org.hamcrest', 'hamcrest-core', '1.3')
protobuf = jar('com.google.protobuf', 'protobuf-javalite', '4.36.0')
compiler = os.pathsep.join([
    jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.10'), stdlib,
    jar('org.jetbrains.kotlin', 'kotlin-build-tools-api', '2.4.10'),
    jar('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.4.10'),
    jar('org.jetbrains.kotlin', 'kotlin-reflect', '1.6.10'),
    jar('org.jetbrains.kotlin', 'kotlin-daemon-embeddable', '2.4.10'),
    jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.8.0'),
    jar('org.jetbrains', 'annotations', '13.0'),
])
base = root / 'android/app/src/main/java/com/xopmc/galaxybridge/transport/shell'
tests = root / 'android/app/src/test/java/com/xopmc/galaxybridge/transport/shell'
source = Path(os.environ.get('GB_SHELL_STOP_RUNTIME_SOURCE', base / 'ShellBridgeRuntime.kt')).read_text()
start = source.index('            synchronized(lock) {', source.index('            val response = completion.get('))
end = source.index('            return response', start)
completion = source[start:end]
assert 'request.operation == ShellBridgeRequest.Operation.STOP' in completion
fixture = (root / 'scripts/fixtures/ShellStopOwnershipSpec.kt').read_text().replace('        // ACTUAL_STOP_COMPLETION', completion)
with tempfile.TemporaryDirectory(prefix='gb-android-shell-stop-') as temporary:
    tmp = Path(temporary)
    # Freeze the existing protocol artifact; no shared build outputs are written.
    protocol = tmp / 'protocol.jar'
    shutil.copyfile(root / 'android/companion-protocol/build/intermediates/compile_library_classes_jar/debug/bundleLibCompileToJarDebug/classes.jar', protocol)
    actual = tmp / 'ActualShellStop.kt'
    actual.write_text(fixture)
    classpath = os.pathsep.join([str(tmp), str(protocol), stdlib, protobuf, junit, hamcrest])
    run([java, '-cp', compiler, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
         '-jvm-target', '17', '-classpath', classpath, '-d', tmp,
         base / 'ShellBridgePolicy.kt', base / 'ShellBridgeWire.kt',
         tests / 'ShellBridgePolicyTest.kt', actual])
    run([java, '-cp', classpath, 'org.junit.runner.JUnitCore',
         'com.xopmc.galaxybridge.transport.shell.ShellBridgePolicyTest',
         'com.xopmc.galaxybridge.transport.shell.ShellStopOwnershipSpec'])
