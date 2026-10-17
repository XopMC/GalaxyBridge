#!/usr/bin/env python3
"""Keep source/cache paths out of native release payloads before signing."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile


def path_maps(root, build, env):
    candidates = [(Path.home(), '/galaxybridge/home'),
                  (Path(tempfile.gettempdir()), '/galaxybridge/tmp'),
                  (Path(root), '/galaxybridge/src'),
                  (Path(build), '/galaxybridge/build'),
                  (Path(env.get('CARGO_HOME', Path.home() / '.cargo')), '/galaxybridge/cargo')]
    if env.get('CARGO_TARGET_DIR'):
        candidates.append((Path(env['CARGO_TARGET_DIR']), '/galaxybridge/rust'))
    # Both compilers choose the last matching map: specific roots come last.
    return sorted({str(p.resolve()): replacement for p, replacement in candidates}.items(),
                  key=lambda item: len(item[0]))


def rust_flags(target, mappings, build, env):
    # Cargo's flag sources are alternatives, not additive. Preserve the effective
    # caller flags before adding release privacy and required Android ABI flags.
    encoded = env.get('CARGO_ENCODED_RUSTFLAGS')
    if encoded is not None:
        flags = encoded.split('\x1f') if encoded else []
    else:
        target_key = 'CARGO_TARGET_' + target.upper().replace('-', '_') + '_RUSTFLAGS'
        flags = env.get('RUSTFLAGS', env.get(target_key, '')).split()
    flags += ['--remap-path-prefix=' + source + '=' + destination for source, destination in mappings]
    if target == 'aarch64-linux-android':
        flags += ['-Lnative=' + str(Path(build) / 'android-cxx-link'), '-lstatic=c++abi',
                  '-Clink-arg=-Wl,-z,max-page-size=16384',
                  '-Clink-arg=-Wl,-z,common-page-size=16384']
    return flags


@contextmanager
def compiler_environment(root, build, target, inherited):
    env = dict(inherited)
    mappings = path_maps(root, build, env)
    env['CARGO_ENCODED_RUSTFLAGS'] = '\x1f'.join(rust_flags(target, mappings, build, env))
    content = shlex.join(['-ffile-prefix-map=' + source + '=' + destination
                         for source, destination in mappings]).encode()
    # cc -> cmake-rs reassembles flags without quoting. A whitespace-free response
    # filename preserves mappings whose source paths themselves contain spaces.
    # Its content-derived name stays stable across incremental Cargo invocations.
    # Only this transient argument file lives outside the selected build tree.
    response = Path('/private/tmp') / ('gb-native-remap-' + str(os.getuid()) + '-' + hashlib.sha256(content).hexdigest() + '.rsp')
    build = Path(build); build.mkdir(parents=True, exist_ok=True)
    with (build / '.compiler-path-privacy.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        fd = os.open(response, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            identity = os.fstat(fd)
            if not stat.S_ISREG(identity.st_mode) or identity.st_uid != os.getuid() or identity.st_nlink != 1:
                raise RuntimeError('Unsafe native compiler argument file')
            os.fchmod(fd, 0o600)
            os.ftruncate(fd, 0)
            os.write(fd, content)
        finally:
            os.close(fd)
        for key in ('CFLAGS', 'CXXFLAGS'):
            env[key] = (env.get(key, '') + ' @' + str(response)).lstrip()
        try:
            yield env
        finally:
            if response.lstat().st_ino == identity.st_ino:
                response.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        parser.error('a foreground compiler/build command is required')
    with compiler_environment(args.root, args.build_dir, args.target, os.environ) as env:
        subprocess.run(command, env=env, check=True)


if __name__ == '__main__':
    main()
