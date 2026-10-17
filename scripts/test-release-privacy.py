#!/usr/bin/env python3
"""Synthetic compressed payloads must be scanned without exposing matched data."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tarfile
import zipfile

script = Path(__file__).with_name('check-release-privacy.py')
spec = importlib.util.spec_from_file_location('release_privacy', script)
privacy = importlib.util.module_from_spec(spec); spec.loader.exec_module(privacy)
private = b'/Users/synthetic-builder/private-project/source.cc'
jar = io.BytesIO()
with zipfile.ZipFile(jar, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('classes.dex', b'dex\n035\0' + private)
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    apk = root / 'fixture.apk'
    with zipfile.ZipFile(apk, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('assets/server.jar', jar.getvalue())
    result = subprocess.run([sys.executable, script, apk], capture_output=True)
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report['findings'][0]['member'] == 'fixture.apk!assets/server.jar!classes.dex'
    assert private not in result.stdout + result.stderr
    assert b'synthetic-builder' not in result.stdout + result.stderr
    tar = io.BytesIO()
    with tarfile.open(fileobj=tar, mode='w:gz') as archive:
        member = tarfile.TarInfo('source/NOTICE'); member.uname = 'synthetic-builder'
        member.size = 7; archive.addfile(member, io.BytesIO(b'license'))
    owners = privacy.inspect(tar.getvalue(), 'source.tar.gz')
    assert owners == [{'member': 'source.tar.gz', 'category': 'archive-owner', 'count': 1}]
    assert 'synthetic-builder' not in json.dumps(owners)
    # Upstream source notices may contain example paths. They are not executables.
    assert not privacy.inspect(b'Example: ' + private, 'licenses/README.md')
    assert not privacy.inspect(b'\x7fELF/galaxybridge/src/fixture.cc', 'runtime')
    assert privacy.inspect(b'own-private-token', 'resource', [b'own-private-token'])
print('Nested APK/JAR privacy, redacted diagnostics, notices and clean payloads: PASS')
