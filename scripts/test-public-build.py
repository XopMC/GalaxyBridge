#!/usr/bin/env python3
"""Exercise build context isolation without compiling or packaging an app."""
import importlib.util
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('public_build', root / 'scripts/public-build.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class EndProbe(Exception):
    pass

for inherited in ({}, {'GALAXYBRIDGE_APP_STORE': '1'}):
    calls = []
    def capture_build(arguments, env):
        assert arguments[0:2] == ['swift', 'build']
        assert Path(arguments[arguments.index('--cache-path') + 1]) == build / 'dependency-cache/swiftpm'
        assert env['GALAXYBRIDGE_APP_STORE'] == '0'
        calls.append('compile')
    def capture_path(arguments, **kwargs):
        assert '--show-bin-path' in arguments
        assert Path(arguments[arguments.index('--cache-path') + 1]) == build / 'dependency-cache/swiftpm'
        assert kwargs['env']['GALAXYBRIDGE_APP_STORE'] == '0'
        calls.append('path')
        raise EndProbe()
    with tempfile.TemporaryDirectory() as temporary:
        build = Path(temporary)
        with patch.object(module, 'generate_pins', return_value=(root / '.build/public-pins/probe', 'probe')), \
             patch.object(module, 'run', side_effect=capture_build), \
             patch.object(module.subprocess, 'check_output', side_effect=capture_path):
            try:
                module.macos_app(build, inherited)
            except EndProbe:
                pass
        assert calls == ['compile', 'path']
        assert not (build / 'app-staging').exists()
    assert inherited.get('GALAXYBRIDGE_APP_STORE') != '0', 'Do not mutate caller context'

print('Public Direct build ignores inherited Store mode for compile and binary lookup: PASS')

with tempfile.TemporaryDirectory() as temporary:
    build = Path(temporary)
    inherited = {'CARGO_HOME': '/unused/cargo', 'GRADLE_USER_HOME': '/unused/gradle', 'PATH': '/usr/bin'}
    env = module.build_environment(build, inherited)
    assert env['CARGO_HOME'] == str(build / 'dependency-cache/cargo')
    assert env['GRADLE_USER_HOME'] == str(build / 'dependency-cache/gradle')
    assert inherited['CARGO_HOME'] == '/unused/cargo'
    assert env['CARGO_PROFILE_TEST_DEBUG'] == env['CARGO_PROFILE_DEV_DEBUG'] == '0'
print('CMake dependency caches are isolated in the selected build tree: PASS')
