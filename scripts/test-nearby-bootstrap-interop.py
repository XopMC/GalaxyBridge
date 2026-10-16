#!/usr/bin/env python3
"""Real Swift CryptoKit to Android's JCE implementation; synthetic identities only."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[1]
java_home=os.environ.get('JAVA_HOME')
java=str(Path(java_home)/'bin/java') if java_home else 'java'
javac=str(Path(java_home)/'bin/javac') if java_home else 'javac'
with tempfile.TemporaryDirectory(prefix='gb-nearby-interop-') as d:
    tmp=Path(d)
    subprocess.run(['swiftc','-swift-version','5',str(root/'Sources/GalaxyBridgeCore/NearbyBootstrapCrypto.swift'),str(root/'macos/GalaxyBridgeMacTests/NearbyBootstrapInteropPeer.swift'),'-o',str(tmp/'swift-peer')],check=True)
    subprocess.run([javac,'-d',d,str(root/'android/app/src/main/java/com/xopmc/galaxybridge/transport/NearbyBootstrapCrypto.java'),str(root/'scripts/fixtures/NearbyBootstrapJavaPeer.java')],check=True)
    left=subprocess.Popen([str(tmp/'swift-peer')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    right=subprocess.Popen([java,'-cp',d,'NearbyBootstrapJavaPeer'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    try:
        def relay(a,b):
            line=a.stdout.readline();assert line, 'peer terminated before exchange';b.stdin.write(line);b.stdin.flush()
        relay(left,right);relay(right,left);relay(left,right);relay(right,left)
        result=left.communicate(timeout=10)[0];assert left.returncode==0 and 'PASS' in result,result
        assert right.wait(timeout=10)==0
        print(result.strip())
    finally:
        for p in (left,right):
            if p.poll() is None:p.kill();p.wait()
