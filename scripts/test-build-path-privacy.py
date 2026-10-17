#!/usr/bin/env python3
"""Exercise compiler path remapping and debug stripping with real tiny programs."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location('build_path_privacy', Path(__file__).with_name('build_path_privacy.py'))
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='gb privacy  spaced ') as temporary:
    root = Path(temporary).resolve()
    build = root / 'build with  spaces'; build.mkdir()
    env = dict(os.environ, CARGO_TARGET_DIR=str(build / 'cargo'), CARGO_HOME=str(root / 'cargo cache'),
               CARGO_ENCODED_RUSTFLAGS='--cfg\x1fpreserved_flag')
    mappings = privacy.path_maps(root, build, env)
    flags = privacy.rust_flags('aarch64-linux-android', mappings, build, env)
    assert flags[:2] == ['--cfg', 'preserved_flag']
    assert '-Lnative=' + str(build / 'android-cxx-link') in flags
    assert '-Clink-arg=-Wl,-z,max-page-size=16384' in flags
    assert '-Clink-arg=-Wl,-z,common-page-size=16384' in flags
    with privacy.compiler_environment(root, build, 'aarch64-apple-darwin', env) as compiler_env:
        token = compiler_env['CFLAGS'].split()[-1]
        assert token.startswith('@') and not any(c.isspace() for c in token)
        response = Path(token[1:]); assert response.is_file()
        for suffix, compiler, text in [
            ('c', 'clang', '#include <stdio.h>\nint main(void) { puts(__FILE__); return 0; }\n'),
            ('cc', 'clang++', '#include <cstdio>\nint main() { std::puts(__FILE__); return 0; }\n')]:
            source = root / ('fixture.' + suffix); source.write_text(text)
            binary = build / ('fixture-' + suffix)
            run(['xcrun', compiler, '-g', token, source, '-o', binary])
            assert b'/galaxybridge/src/fixture.' in run([binary]).stdout
            run(['xcrun', 'strip', '-S', binary])
            run(['codesign', '--force', '--sign', '-', binary])
            run(['codesign', '--verify', '--strict', binary])
            assert str(root).encode() not in binary.read_bytes()
        if os.environ.get('ANDROID_NDK_HOME'):
            ndk = Path(os.environ['ANDROID_NDK_HOME']) / 'toolchains/llvm/prebuilt/darwin-x86_64/bin'
            for suffix, compiler in [('c', 'aarch64-linux-android31-clang'), ('cc', 'aarch64-linux-android31-clang++')]:
                obj = build / ('fixture-android-' + suffix + '.o')
                run([ndk / compiler, token, '-c', root / ('fixture.' + suffix), '-o', obj])
                assert str(root).encode() not in obj.read_bytes()
                assert b'/galaxybridge/src/fixture.' in obj.read_bytes()
        source = root / 'fixture.rs'; source.write_text('fn main() { println!("{}", file!()); }\n')
        binary = build / 'fixture-rust'
        native_flags = privacy.rust_flags('aarch64-apple-darwin', mappings, build, {})
        run([os.environ.get('RUSTC', 'rustc'), *native_flags, '-C', 'debuginfo=0', source, '-o', binary])
        run(['xcrun', 'strip', '-S', binary])
        assert b'/galaxybridge/src/fixture.rs' in run([binary]).stdout
        assert str(root).encode() not in binary.read_bytes()
    assert not response.exists(), 'Transient response file must be removed'
print('Real C/C++/Rust paths with spaces, preserved flags, Android alignment, strip/sign: PASS')
