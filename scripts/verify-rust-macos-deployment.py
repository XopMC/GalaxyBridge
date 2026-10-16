#!/usr/bin/env python3
"""Reject a prebuilt Rust standard library newer than the supported Mac floor."""
import argparse
import os
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--rustc', default=os.environ.get('RUSTC', 'rustc'))
parser.add_argument('--minimum', default='14.0')
args = parser.parse_args()
def version(value):
    return tuple((list(map(int, value.split('.'))) + [0, 0, 0])[:3])
floor = version(args.minimum)
sysroot = Path(subprocess.check_output([args.rustc, '--print', 'sysroot'], text=True).strip())
libraries = sysroot / 'lib/rustlib/aarch64-apple-darwin/lib'
archives = [p for prefix in ('libcore-', 'libstd-') for p in libraries.glob(prefix + '*.rlib')]
if len(archives) != 2:
    raise SystemExit('Rust aarch64-apple-darwin standard libraries are unavailable; install the target for the selected RUSTC.')
for archive in archives:
    detail = subprocess.check_output(['otool', '-l', str(archive)], text=True, stderr=subprocess.DEVNULL)
    targets = re.findall(r'\bminos\s+(\d+(?:\.\d+){0,2})', detail)
    if not targets or any(version(target) > floor for target in targets):
        raise SystemExit('The selected Rust standard library requires a newer macOS than ' + args.minimum +
            '. Setting MACOSX_DEPLOYMENT_TARGET cannot lower prebuilt libraries. Select a compatible Rust distribution with RUSTC/CARGO (for example the official rustup toolchain).')
print('Rust standard-library deployment floor is compatible with macOS ' + args.minimum + '.')
