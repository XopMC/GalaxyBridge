#!/usr/bin/env python3
"""Install pinned build-only Python tools into an isolated, disposable venv."""
import argparse
from pathlib import Path
import subprocess
import sys
import venv
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--build-dir', type=Path, default=Path('out/macos-arm64-release'))
a = p.parse_args()
tools = a.build_dir.resolve() / 'tools'
if not (tools / 'pyvenv.cfg').exists():
    venv.EnvBuilder(with_pip=True).create(tools)
subprocess.run([str(tools / 'bin/python3'), '-m', 'pip', 'install', '--disable-pip-version-check',
                '--cache-dir', str(a.build_dir.resolve() / 'dependency-cache/pip'), '--require-hashes', '-r', str(Path(__file__).resolve().with_name('build-tools-requirements.txt'))], check=True)
print('Build tools ready. Add this directory to PATH: ' + str(tools / 'bin'))
