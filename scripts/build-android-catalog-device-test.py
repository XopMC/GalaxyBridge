#!/usr/bin/env python3
"""Build the synthetic catalog device check; never connects to a phone.

Run its class with app_process and CLASSPATH containing the installed Helper APK
and this JAR. It tests real Android JSON/PNG without enumerating installed apps.
The JAR belongs in a temporary device directory and must be removed afterwards.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--java-home', type=Path, default=os.environ.get('JAVA_HOME'))
parser.add_argument('--sdk', type=Path, default=os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME'))
parser.add_argument('--platform', default='android-37.0')
parser.add_argument('--build-tools', default='37.0.0')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
if args.java_home is None or args.sdk is None:
    parser.error('Set JAVA_HOME and ANDROID_SDK_ROOT or pass their paths explicitly.')
source = Path(__file__).resolve().parents[1] / 'android/device-tests/CatalogInlineDeviceSpec.java'
android = args.sdk / 'platforms' / args.platform / 'android.jar'
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='catalog-device-check-', dir=args.output.parent) as temporary:
    folder = Path(temporary)
    classes, dex = folder / 'classes', folder / 'dex'
    classes.mkdir()
    dex.mkdir()
    subprocess.run([str(args.java_home / 'bin/javac'), '-source', '8', '-target', '8',
                    '-Xlint:-options', '-bootclasspath', str(android), '-d', str(classes), str(source)], check=True)
    subprocess.run([str(args.sdk / 'build-tools' / args.build_tools / 'd8'), '--min-api', '31',
                    '--lib', str(android), '--output', str(dex), *map(str, classes.rglob('*.class'))],
                   env=dict(os.environ, JAVA_HOME=str(args.java_home)), check=True)
    result = folder / 'catalog-check.jar'
    with zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.write(dex / 'classes.dex', 'classes.dex')
    result.replace(args.output)
print(f'Built synthetic device check: {args.output}')
