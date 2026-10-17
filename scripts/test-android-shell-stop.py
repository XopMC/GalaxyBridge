#!/usr/bin/env python3
"""Run actual Runtime/server STOP ownership bodies without Gradle or Android."""
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
failure_start = source.index('        } catch (_: Exception) {', source.index('fun executeAuthenticated')) + len('        } catch (_: Exception) {')
failure_end = source.index('        } finally {', failure_start)
failure_fixture = (root / 'scripts/fixtures/ShellReadOnlyFailureIsolationSpec.kt').read_text().replace(
    '        // ACTUAL_EXECUTE_FAILURE', source[failure_start:failure_end])
fixture = (root / 'scripts/fixtures/ShellStopOwnershipSpec.kt').read_text().replace('        // ACTUAL_STOP_COMPLETION', completion)
server = Path(os.environ.get('GB_SHELL_STOP_SERVER_SOURCE', root / 'android/app/src/main/java/com/xopmc/galaxybridge/transport/CompanionLanServer.kt')).read_text()
lease_start = server.index('    private data class FeatureShellLease(')
lease_end = server.index('    private val featureShellLeases', lease_start)
lease_record = server[lease_start:lease_end].replace('private data class', 'data class', 1)
stop_start = server.index('                        if (shellRequest.operation == com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.STOP)')
stop_end = server.index('                        else if (result.available', stop_start)
def body(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 0
    for end in range(opening, len(text)):
        if text[end] == '{': depth += 1
        elif text[end] == '}':
            depth -= 1
            if depth == 0: return text[opening + 1:end]
    raise RuntimeError(marker)
disable = body(server[server.index('featureShellLeases.values.filter'):], '.forEach { lease ->').split('->', 1)[1]
late_offset = server.index('// A different CONTROL operation may have disabled this feature')
late_start = server.rfind('\n', 0, server.index('bridge?.executeAuthenticated', late_offset)) + 1
late_end = server.index('                                writeEnvelope(output, featureDisabled(incoming)); continue', late_start)
upgrade_fixture = (root / 'scripts/fixtures/ShellRuntimeUpgradeAdmissionSpec.kt').read_text().replace(
    '        // ACTUAL_RUNTIME_PREPARE', body(source, 'fun prepare('))
feature_fixture = (root / 'scripts/fixtures/FeatureShellStopOwnershipSpec.kt').read_text() \
    .replace('    // ACTUAL_FEATURE_LEASE', lease_record) \
    .replace('        // ACTUAL_FEATURE_STOP', server[stop_start:stop_end]) \
    .replace('        // ACTUAL_FEATURE_DISABLE', disable) \
    .replace('        // ACTUAL_LATE_START_DISABLE', server[late_start:late_end])
with tempfile.TemporaryDirectory(prefix='gb-android-shell-stop-') as temporary:
    tmp = Path(temporary)
    # Compile checked-in protocol source so a stale Gradle JAR cannot hide a wire change.
    protocol = tmp / 'protocol-classes'
    protocol.mkdir()
    javac = str(Path(java).with_name('javac'))
    generated = sorted((root / 'android/companion-protocol/src/main/java').rglob('*.java'))
    run([javac, '--release', '17', '-encoding', 'UTF-8', '-cp', protobuf, '-d', protocol, *generated])
    actual = tmp / 'ActualShellStop.kt'
    actual.write_text(fixture)
    actual_failure = tmp / 'ActualShellFailure.kt'
    actual_failure.write_text(failure_fixture)
    actual_upgrade = tmp / 'ActualRuntimeUpgrade.kt'
    actual_upgrade.write_text(upgrade_fixture)
    actual_feature = tmp / 'ActualFeatureShellStop.kt'
    actual_feature.write_text(feature_fixture)
    classpath = os.pathsep.join([str(tmp), str(protocol), stdlib, protobuf, junit, hamcrest])
    run([java, '-cp', compiler, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
         '-jvm-target', '17', '-classpath', classpath, '-d', tmp,
         base / 'ShellBridgePolicy.kt', base / 'ShellBridgeWire.kt',
         tests / 'ShellBridgePolicyTest.kt', base / 'ShellActivationTicketPolicy.kt',
         base / 'ShellRuntimeIdentity.kt', tests / 'ShellRuntimeIdentityTest.kt',
         actual, actual_feature, actual_failure, actual_upgrade])
    run([java, '-cp', classpath, 'org.junit.runner.JUnitCore',
         'com.xopmc.galaxybridge.transport.shell.ShellBridgePolicyTest',
         'com.xopmc.galaxybridge.transport.shell.ShellStopOwnershipSpec',
         'com.xopmc.galaxybridge.transport.shell.FeatureShellStopOwnershipSpec',
         'com.xopmc.galaxybridge.transport.shell.ShellReadOnlyFailureIsolationSpec',
         'com.xopmc.galaxybridge.transport.shell.ShellRuntimeIdentityTest',
         'com.xopmc.galaxybridge.transport.shell.ShellRuntimeUpgradeAdmissionSpec'])
