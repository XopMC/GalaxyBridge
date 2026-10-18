#!/usr/bin/env python3
"""Compile the permission-free clipboard/input fixture. No signing or device access."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--java-home', type=Path, required=True)
p.add_argument('--android-sdk-root', type=Path, default=Path(os.environ.get('ANDROID_SDK_ROOT', Path.home() / 'Library/Android/sdk')))
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
source = ROOT / 'tests/android/gesture-marker'
manifest = source / 'AndroidManifest.xml'
xml = ET.parse(manifest).getroot()
assert xml.get('package') == 'com.xopmc.galaxybridge.qa.gestureresponse'
assert not xml.findall('uses-permission')
assert all(node.get('{http://schemas.android.com/apk/res/android}name') != 'android.intent.category.LAUNCHER'
           for node in xml.iter('category'))
platform = a.android_sdk_root / 'platforms' / os.environ.get('GB_ANDROID_PLATFORM', 'android-37.0') / 'android.jar'
tools = a.android_sdk_root / 'build-tools' / os.environ.get('GB_ANDROID_BUILD_TOOLS', '37.0.0')
a.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='clipboard-fixture-', dir=a.output.parent) as temporary:
    work = Path(temporary)
    classes = work / 'classes'
    classes.mkdir()
    def run(arguments):
        subprocess.run([str(x) for x in arguments], check=True)
    run([a.java_home / 'bin/javac', '-source', '8', '-target', '8', '-Xlint:-options',
         '-bootclasspath', platform, '-d', classes, *sorted((source / 'src').rglob('*.java'))])
    run([a.java_home / 'bin/java', '-cp', tools / 'lib/d8.jar', 'com.android.tools.r8.D8',
         '--lib', platform, '--min-api', '31', '--output', work, *sorted(classes.rglob('*.class'))])
    unsigned = work / 'fixture.apk'
    run([tools / 'aapt2', 'link', '-o', unsigned, '--manifest', manifest, '-I', platform])
    with zipfile.ZipFile(unsigned, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(work / 'classes.dex', 'classes.dex')
    run([tools / 'zipalign', '-f', '4', unsigned, a.output])
print('Built unsigned permission-free clipboard/input fixture:', a.output)
