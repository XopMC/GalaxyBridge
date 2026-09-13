#!/usr/bin/env bash
set -euo pipefail
GB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$GB_ROOT" <<'PY'
from pathlib import Path
import os,shutil,subprocess,sys,tempfile
root=Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='gb-package-probe-isolation-') as tmp:
    fixture=Path(tmp); scripts=fixture/'scripts'; scripts.mkdir()
    camera=scripts/'test-macos-internal-camera-extension-package.sh'
    runtime=scripts/'test-macos-internal-no-keychain-runtime.sh'
    for p in [camera,runtime]: shutil.copy2(root/'scripts'/p.name,p)
    # Deliberately stop at the package boundary, before compilation/signing/UI.
    mock=scripts/'package-macos-internal.sh'
    mock.write_text('#!/bin/bash\nset -eu\nprintf "%s" "${GALAXYBRIDGE_INTERNAL_APP_OUTPUT:-}" > "$GB_QA_CAPTURE"\nexit 73\n')
    mock.chmod(0o755)
    capture=fixture/'captured-output'; env=os.environ.copy()
    env.pop('GALAXYBRIDGE_PACKAGE_TEST_APP',None)
    env['GB_QA_CAPTURE']=str(capture)
    result=subprocess.run(['bash',str(camera)],env=env,capture_output=True)
    assert result.returncode==73,result.stderr
    isolated=Path(capture.read_text())
    assert isolated.is_absolute() and isolated.name=='GalaxyBridgeInternal.app'
    assert isolated!=fixture/'.build/GalaxyBridgeInternal.app'
    assert not isolated.parent.exists(),'Standalone scratch must clean itself'
    explicit=fixture/'shared-probes/Internal.app'; env['GALAXYBRIDGE_PACKAGE_TEST_APP']=str(explicit)
    result=subprocess.run(['bash',str(camera)],env=env,capture_output=True)
    assert result.returncode==73 and capture.read_text()==str(explicit)
    canonical=fixture/'.build/GalaxyBridgeInternal.app';canonical.mkdir(parents=True)
    alias=fixture/'Alias.app';alias.symlink_to(canonical)
    for value in [None,str(canonical),str(alias)]:
        if value is None:env.pop('GALAXYBRIDGE_PACKAGE_TEST_APP',None)
        else:env['GALAXYBRIDGE_PACKAGE_TEST_APP']=value
        result=subprocess.run(['bash',str(runtime)],env=env,capture_output=True)
        assert result.returncode==2,(value,result.returncode,result.stderr)
    # Exercise both signing rebuild paths with fake codesign/security/package.
    signing=scripts/'test-macos-internal-signing.sh'
    fakeSecurity=fixture/'security';fakeSecurity.write_text('#!/bin/bash\nprintf "fixed search list\\n"\n');fakeSecurity.chmod(0o755)
    fakeCodesign=fixture/'codesign';fakeCodesign.write_text('#!/bin/bash\nif [[ "$1" == "-d" ]]; then printf "Executable=%s\\ndesignated => identifier stable-fixture\\n" "${@: -1}"; fi\n');fakeCodesign.chmod(0o755)
    signing.write_text((root/'scripts'/signing.name).read_text().replace('/usr/bin/security',str(fakeSecurity)).replace('/usr/bin/codesign',str(fakeCodesign)))
    mock.write_text('#!/bin/bash\nset -eu\ntest -n "$GALAXYBRIDGE_INTERNAL_APP_OUTPUT"\ntest ! -e "$GALAXYBRIDGE_INTERNAL_APP_OUTPUT"\nmkdir -p "$GALAXYBRIDGE_INTERNAL_APP_OUTPUT"\nprintf "%s\\n" "$GALAXYBRIDGE_INTERNAL_APP_OUTPUT" >> "$GB_QA_CAPTURE"\n')
    signDir=fixture/'.build/internal-signing';signDir.mkdir()
    for name in ['private-key.pem','identity.p12','GalaxyBridgeInternalSigning-v2.keychain-db']:
        target=signDir/name;target.touch();target.chmod(0o600)
    capture.write_text('')
    result=subprocess.run(['bash',str(signing)],env=env,capture_output=True)
    assert result.returncode==0,result.stderr
    outputs=[Path(x) for x in capture.read_text().splitlines()]
    assert len(outputs)==2 and outputs[0]!=outputs[1]
    assert all(p!=canonical and not p.parent.exists() for p in outputs)
    # Run only the actual camera launch clause with a harmless mock executable.
    # Its record root must be new and must not resolve to the user's real store.
    cameraSource=(root/'scripts'/camera.name).read_text()
    launch=cameraSource[cameraSource.index('if [[ "${GALAXYBRIDGE_SKIP_PACKAGE_LAUNCH'):]
    mockApp=fixture/'LaunchProbe.app';binary=mockApp/'Contents/MacOS/GalaxyBridgeMac';binary.parent.mkdir(parents=True)
    binary.write_text('#!/usr/bin/env python3\nimport os,time\nfrom pathlib import Path\nPath(os.environ["GB_QA_CAPTURE"]).write_text(os.environ.get("GALAXYBRIDGE_INTERNAL_RECORD_STORE_ROOT",""))\ntime.sleep(10)\n');binary.chmod(0o755)
    cameraTmp=fixture/'camera-runtime';cameraTmp.mkdir()
    launchEnv=env.copy();launchEnv.update(GB_APP=str(mockApp),GB_TMP_DIR=str(cameraTmp),GALAXYBRIDGE_SKIP_PACKAGE_LAUNCH='0')
    result=subprocess.run(['bash','-c',launch],env=launchEnv,capture_output=True)
    assert result.returncode==0,result.stderr
    assert capture.read_text()==str(cameraTmp/'records')
    assert not (cameraTmp/'records').exists(),'Mock must not open real records'
    print('PASS package probes: isolated camera/signing outputs, no canonical runtime or alias, fresh camera record root; mocked build/signing/launch only')
PY
