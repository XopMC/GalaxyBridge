#!/usr/bin/env python3
"""Check executable payloads for builder paths; never print matching values."""
import argparse
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile
import tarfile
import zipfile

MAGIC = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\x7fELF', b'dex\n')
PATHS = re.compile(rb'/(?:Users|home)/[^/\x00\r\n]{1,100}/|/(?:private/)?var/folders/')
METADATA = {'PROVENANCE.json', 'BuildArtifacts.json', 'OWNED-CONTRACT.json'}


def inspect(data, label, markers=()):
    findings = []
    if data.startswith(MAGIC) or Path(label).name in METADATA:
        count = len(PATHS.findall(data))
        if count:
            findings.append({'member': label, 'category': 'builder-path', 'count': count})
    for number, marker in enumerate(markers):
        count = data.count(marker)
        if count:
            findings.append({'member': label, 'category': 'private-marker-' + str(number), 'count': count})
    if data.startswith(b'PK\x03\x04'):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for member in archive.infolist():
                if member.is_dir(): continue
                if member.file_size > 256 * 1024 * 1024:
                    raise ValueError('Executable archive member exceeds privacy scan limit')
                findings += inspect(archive.read(member), label + '!' + member.filename, markers)
    if data.startswith(b'\x1f\x8b'):
        try:
            archive = tarfile.open(fileobj=io.BytesIO(data), mode='r:gz')
        except tarfile.ReadError:
            archive = None
        if archive is not None:
            with archive:
                for member in archive:
                    if member.uname or member.gname:
                        findings.append({'member': label, 'category': 'archive-owner', 'count': 1})
                    if member.isfile():
                        if member.size > 256 * 1024 * 1024:
                            raise ValueError('Source archive member exceeds privacy scan limit')
                        findings += inspect(archive.extractfile(member).read(), label + '!' + member.name, markers)
    return findings


def scan(path, markers=()):
    findings = []
    files = [path] if path.is_file() else sorted(p for p in path.rglob('*') if p.is_file() and not p.is_symlink())
    for file in files:
        label = file.name if path.is_file() else str(file.relative_to(path))
        findings += inspect(file.read_bytes(), label, markers)
        if file.suffix == '.pkg':
            # A pkg contains compressed payloads: checking its outer bytes is insufficient.
            with tempfile.TemporaryDirectory(prefix='gb-release-privacy-') as temporary:
                expanded = Path(temporary) / 'expanded'
                subprocess.run(['pkgutil', '--expand-full', str(file), str(expanded)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                findings += [dict(item, member=label + '!' + item['member']) for item in scan(expanded, markers)]
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', nargs='+', type=Path)
    parser.add_argument('--private-markers', type=Path, help='Private JSON array; values are never printed')
    args = parser.parse_args()
    markers = [value.encode() for value in json.loads(args.private_markers.read_text())] if args.private_markers else []
    if any(not marker for marker in markers): parser.error('Empty private marker')
    findings = []
    for index, path in enumerate(args.artifacts):
        if not path.exists(): parser.error('Artifact input does not exist')
        findings += [dict(item, artifact=index) for item in scan(path, markers)]
    print(json.dumps({'clean': not findings, 'findings': findings}, indent=2))
    raise SystemExit(bool(findings))


if __name__ == '__main__':
    main()
