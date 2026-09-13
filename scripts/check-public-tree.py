#!/usr/bin/env python3
"""Check source publication hygiene without printing matching secret values."""
import hashlib
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SKIP = {'.git', '.build', '.gradle', '.swiftpm', 'build', 'target', 'out', '__pycache__'}
FORBIDDEN_SUFFIXES = {'.apk', '.dmg', '.p12', '.pfx', '.jks', '.keystore', '.mobileprovision', '.ips', '.log', '.sqlite', '.db', '.key'}
# Public upstream TLS test material, never a Galaxy Bridge or user identity.
PUBLIC_TEST_KEYS = {
    'native/galaxybridge-quic/vendor/quiche/examples/cert.key':
        'e60fc77960951b1f3f86fb255f71f4a844174e0d1f7be32e1e53bc0d1f213e00',
}
PATTERNS = {
    'private signing material': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'GitHub credential': re.compile(r'gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,}'),
    'personal build path': re.compile('/Users/' + 'xopmc' + r'(?:/|\b)'),
    'internal evidence path': re.compile(r'\.' + 'superpowers/'),
    'device identifier': re.compile('R5CX' + '4259SEB|' + 'RFCW' + '719VW5J|' + 'R5GL' + '75392JT|' + 'RFGL' + '72GGM9R'),
    'personal network': re.compile(r'192\.168\.' + r'50\.[0-9]+'),
}


def candidates():
    if (ROOT / '.git').exists():
        result = subprocess.run(['git', 'ls-files', '-co', '--exclude-standard', '-z'],
                                cwd=ROOT, capture_output=True, check=True)
        for name in sorted(set(result.stdout.decode().split('\0')) - {''}):
            yield ROOT / name
    else:
        for directory, names, files in os.walk(ROOT):
            names[:] = [name for name in names if name not in SKIP]
            yield from (Path(directory) / name for name in files)


def main():
    failures = []
    count = 0
    for path in candidates():
        relative = path.relative_to(ROOT).as_posix()
        if path.is_symlink():
            failures.append((relative, 'source symlink needs explicit review'))
            continue
        if not path.is_file():
            continue
        count += 1
        if any(part in SKIP for part in path.relative_to(ROOT).parts):
            failures.append((relative, 'tracked build/cache artifact'))
        if path.suffix in FORBIDDEN_SUFFIXES and relative not in PUBLIC_TEST_KEYS:
            failures.append((relative, 'runtime or private artifact'))
        if path.name.startswith('.env') and path.name != '.env.example':
            failures.append((relative, 'local environment configuration'))
        data = path.read_bytes()
        if relative in PUBLIC_TEST_KEYS:
            if hashlib.sha256(data).hexdigest() != PUBLIC_TEST_KEYS[relative]:
                failures.append((relative, 'upstream test-key content changed'))
            continue
        try:
            source = data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        for name, pattern in PATTERNS.items():
            if relative == '.gitignore' and name == 'internal evidence path':
                continue
            for match in pattern.finditer(source):
                line = source.count('\n', 0, match.start()) + 1
                failures.append((f'{relative}:{line}', name))
    for path, reason in failures:
        print(f'FAIL {path}: {reason}')
    if failures:
        raise SystemExit(1)
    print(f'PASS publication hygiene: {count} source files; public upstream test-key exception hash verified.')


if __name__ == '__main__':
    main()
