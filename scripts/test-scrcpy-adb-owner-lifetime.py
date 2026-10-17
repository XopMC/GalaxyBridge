#!/usr/bin/env python3
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
def declaration(path,name):
    source=(root/path).read_text(); start=source.find(name)
    assert start >= 0, "raw ADB capture has no independent host-owned heartbeat"
    begin=source.index("{",start); depth=0
    for end in range(begin,len(source)):
        if source[end]=="{": depth+=1
        elif source[end]=="}":
            depth-=1
            if depth==0: return source[start:end+1]
    raise AssertionError("incomplete declaration")
with tempfile.TemporaryDirectory(prefix="gb-adb-owner-") as folder:
    out=Path(folder); actual=out/"Actual.swift"
    actual.write_text("import Foundation\nimport Darwin\n"+declaration("macos/GalaxyBridgeMac/Transport/ScrcpySession.swift","final class ScrcpyADBOwnerLifetime:")+"\n"+declaration("macos/GalaxyBridgeMac/Transport/ADBClient.swift","enum ADBScrcpyServerProcessParser"))
    subprocess.run(["swiftc","-swift-version","6",str(actual),str(root/"macos/GalaxyBridgeMacTests/ScrcpyADBOwnerLifetimeSpec.swift"),"-o",str(out/"spec")],check=True)
    subprocess.run([str(out/"spec")],check=True,timeout=10)
