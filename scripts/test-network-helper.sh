#!/bin/bash
set -euo pipefail
network_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
network_test_dir="$(mktemp -d /tmp/galaxybridge-network-test.XXXXXX)"
trap 'rm -rf "$network_test_dir"' EXIT
cd "$network_repo_root"
clang -std=c11 -Wall -Wextra -Werror -I macos/GalaxyBridgeNetworkHelper macos/GalaxyBridgeNetworkHelper/GBNetworkLease.c macos/GalaxyBridgeNetworkHelper/tests/lease_test.c -o "$network_test_dir/lease-test"
"$network_test_dir/lease-test"
clang -std=c11 -Wall -Wextra -Werror -I native/galaxybridge-internet/include native/galaxybridge-internet/gateway_pool.c native/galaxybridge-internet/tests/gateway_pool_test.c -o "$network_test_dir/pool-test"
"$network_test_dir/pool-test"
clang -std=c11 -Wall -Wextra -Werror -I macos/GalaxyBridgeNetworkHelper macos/GalaxyBridgeNetworkHelper/GBNetworkLease.c macos/GalaxyBridgeNetworkHelper/GBRouteLease.c macos/GalaxyBridgeNetworkHelper/GBCodeTrust.c macos/GalaxyBridgeNetworkHelper/GBProgramFingerprint.c macos/GalaxyBridgeNetworkHelper/GBNetworkDaemon.c -framework Security -framework SystemConfiguration -framework CoreFoundation -lbsm -o "$network_test_dir/helper"
"$network_test_dir/helper" --version
clang -std=c11 -Wall -Wextra -Werror -I macos/GalaxyBridgeNetworkHelper -c macos/GalaxyBridgeNetworkHelper/GBNetworkClient.c -o "$network_test_dir/client.o"
PYTHONPYCACHEPREFIX="$network_test_dir/pycache" python3 -m py_compile scripts/package-network-helper.py scripts/build-internet-runtime.py
printf '%s\n' 'Network helper policy, expiry, ownership-fence, gateway-pinning and Darwin compile checks PASS; no install or network mutation performed.'

clang -std=c11 -Wall -Wextra -Werror -I macos/GalaxyBridgeNetworkHelper macos/GalaxyBridgeNetworkHelper/GBProgramFingerprint.c macos/GalaxyBridgeNetworkHelper/tests/fingerprint_test.c -o "$network_test_dir/fingerprint-test"
python3 -B - "$network_repo_root" "$network_test_dir" <<'PYTEST'
import importlib.util,pathlib,plistlib,subprocess,sys
root=pathlib.Path(sys.argv[1]);temp=pathlib.Path(sys.argv[2]);spec=importlib.util.spec_from_file_location('packager',root/'scripts/package-network-helper.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
app=temp/'Fixture.app';binary=app/'Contents/MacOS/fixture';binary.parent.mkdir(parents=True);resources=app/'Contents/Resources';resources.mkdir();(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'fixture','CFBundleIdentifier':'com.xopmc.NetworkHelperFingerprintFixture','CFBundlePackageType':'APPL'}));source=temp/'fixture.c';source.write_text('int main(void){return 0;}')
subprocess.run(['clang',source,'-o',binary],check=True)
subprocess.run(['codesign','--force','--sign','-',app],check=True,capture_output=True)
before=module.program_fingerprint(binary.read_bytes());native=subprocess.check_output([temp/'fingerprint-test',binary],text=True).strip();assert before==native
(resources/'embedded-helper.pkg').write_bytes(b'owned-test-package')
subprocess.run(['codesign','--force','--sign','-',app],check=True,capture_output=True)
after=module.program_fingerprint(binary.read_bytes());native_after=subprocess.check_output([temp/'fingerprint-test',binary],text=True).strip();assert before==after==native_after
changed=bytearray(binary.read_bytes());changed[4096]^=1;assert module.program_fingerprint(changed)!=before
print('Embedded installer program fingerprint PASS: Python/native agreement, stable across resource embedding/resigning, program mutation rejected.')
PYTEST

swiftc -swift-version 6 -D GB_PAIRED_DNS_WIRE_TEST macos/GalaxyBridgeMac/Transport/PairedDNSRelay.swift native/galaxybridge-internet/tests/PairedDNSWireSpec.swift -o "$network_test_dir/dns-wire-test"
"$network_test_dir/dns-wire-test"

clang -std=c11 -Wall -Wextra -Werror -I macos/GalaxyBridgeNetworkHelper macos/GalaxyBridgeNetworkHelper/GBRouteLease.c macos/GalaxyBridgeNetworkHelper/tests/route_test.c -o "$network_test_dir/route-test"
"$network_test_dir/route-test"
printf '%s\n' 'Actual route adapter ownership/VPN decision seam PASS: EEXIST foreign routes preserved, uncertain writes reconciled, changed routes stay fenced.'

python3 -B - "$network_test_dir" <<'PYTEST'
from pathlib import Path
import sys
source=Path('macos/GalaxyBridgeMac/Transport/InternetTunnelDriver.swift').read_text()
start=source.index('    private static func gatewayAddress(')
end=source.index('    private enum DriverError:',start)
method=source[start:end].replace('private static func','static func',1)
fixture=Path('native/galaxybridge-internet/tests/GatewayAddressSpec.swift').read_text()
Path(sys.argv[1],'gateway-address.swift').write_text('import Foundation\nimport Network\nstruct Check { enum DriverError:Error {case gatewayAddressUnavailable}\n'+method+'}\n'+fixture)
PYTEST
swiftc -swift-version 6 -import-objc-header macos/GalaxyBridgeNetworkHelper/GBNetworkLease.h "$network_test_dir/gateway-address.swift" -o "$network_test_dir/gateway-address-test"
"$network_test_dir/gateway-address-test"

clang -std=c11 -Wall -Wextra -Werror -I macos/GalaxyBridgeNetworkHelper macos/GalaxyBridgeNetworkHelper/GBCodeTrust.c macos/GalaxyBridgeNetworkHelper/tests/code_trust_test.c -framework Security -framework CoreFoundation -o "$network_test_dir/trust-fixture"
python3 -B - "$network_test_dir" <<'PYTEST'
from pathlib import Path
import plistlib,shutil,subprocess,sys
root=Path(sys.argv[1]);base=root/'trust-fixture'
keys=['com.apple.security.cs.disable-library-validation','com.apple.security.cs.allow-dyld-environment-variables','com.apple.security.get-task-allow','get-task-allow','com.apple.security.cs.allow-unsigned-executable-memory','com.apple.security.cs.disable-executable-page-protection','com.apple.security.cs.allow-jit']
cases=[('ordinary',False,{},0),('hardened',True,{},1),('false-exceptions',True,{k:False for k in keys},1)]+[(f'relaxed-{i}',True,{key:True},0) for i,key in enumerate(keys)]
for name,runtime,entitlements,expected in cases:
 binary=root/name;shutil.copyfile(base,binary);binary.chmod(0o700)
 args=['codesign','--force','--sign','-']
 if runtime:args+=['--options','runtime']
 if entitlements:
  plist=root/(name+'.plist');plist.write_bytes(plistlib.dumps(entitlements));args+=['--entitlements',str(plist)]
 subprocess.run(args+[str(binary)],check=True,capture_output=True)
 subprocess.run([str(base),str(expected),str(binary)],check=True)
 if name in ('ordinary','hardened'):subprocess.run([str(binary),str(expected)],check=True)
print('Hardened caller trust PASS: live/static ordinary ad-hoc rejected and hardened accepted; signed static fixtures reject all seven relaxing entitlements and permit explicit false values.')
PYTEST

python3 -B - "$network_test_dir" <<'PYTEST'
from pathlib import Path
import sys
source=Path('native/galaxybridge-internet/android_gateway_jni.c').read_text()
start=source.index('void gb_android_upstream_failure(')
end=source.index('void gb_android_listener_ready(',start)
Path(sys.argv[1],'AndroidNetworkBindingUnderTest.h').write_text(source[start:end])
PYTEST
clang -std=c11 -Wall -Wextra -Werror -I "$network_test_dir" native/galaxybridge-internet/tests/AndroidNetworkBindingSpec.c -o "$network_test_dir/android-network-binding-test"
"$network_test_dir/android-network-binding-test"
printf '%s\n' 'Android network adapter seam PASS: exact selected handle, no default fallback, bind errno preserved, bounded diagnostics.'
