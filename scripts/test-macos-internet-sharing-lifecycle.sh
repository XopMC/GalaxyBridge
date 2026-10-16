#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gb-sharing-lifecycle.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]);tmp=Path(sys.argv[2]);s=(root/'macos/GalaxyBridgeMac/InternetSharingCoordinator.swift').read_text();s=s[:s.index('/// OS curl')]
s=s.replace('import GalaxyBridgeCore\n','').replace('import GalaxyBridgeProtocol\n','').replace('#if !GALAXYBRIDGE_APP_STORE\n','')
(tmp/'ActualCoordinator.swift').write_text(s)
PY
swiftc -swift-version 6 "$tmp/ActualCoordinator.swift" "$root/macos/GalaxyBridgeMacTests/InternetSharingLifecycleSpec.swift" -o "$tmp/spec"
"$tmp/spec"

# Typecheck the real probe owner and exercise its cancellation against a harmless
# owned sleep child. No curl, internet probe, privileged driver or route changes run.
python3 - "$root" "$tmp" <<'PYPROBE'
from pathlib import Path
import sys
root=Path(sys.argv[1]);tmp=Path(sys.argv[2]);source=(root/'macos/GalaxyBridgeMac/InternetSharingCoordinator.swift').read_text()
probe=source[source.index('private final class InternetProbeProcessOwner:'):].rsplit('#endif',1)[0]
probe=probe.replace('URL(fileURLWithPath: "/usr/bin/curl")','URL(fileURLWithPath: "/bin/sleep")').replace('child.arguments = ["--disable", "--config", "-"]','child.arguments = ["30"]')
fixture="""
private extension InternetProbeProcessOwner {
    var fixtureRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }
    func fixtureTerminate() { lock.lock(); defer { lock.unlock() }; if process?.isRunning == true { process?.terminate() } }
}
@main enum ProbeCancellationSpec {
    static func main() async throws {
        let early=InternetProbeProcessOwner();early.cancel()
        do { try early.run(configuration: ""); preconditionFailure("Cancelled probe launched a process") }
        catch is CancellationError {}
        let owner=InternetProbeProcessOwner()
        let work=Task.detached { try owner.run(configuration: "") }
        let limit=ProcessInfo.processInfo.systemUptime+2
        while !owner.fixtureRunning && ProcessInfo.processInfo.systemUptime<limit { try await Task.sleep(for:.milliseconds(5)) }
        precondition(owner.fixtureRunning,"Harmless owned child did not launch")
        let began=ProcessInfo.processInfo.systemUptime
        // Bound a broken implementation too, so a missing terminate cannot hang tests.
        DispatchQueue.global().asyncAfter(deadline:.now()+1) { owner.fixtureTerminate() }
        owner.cancel()
        do { try await work.value; preconditionFailure("Cancelled running probe succeeded") }
        catch is CancellationError {}
        precondition(ProcessInfo.processInfo.systemUptime-began<0.8,"Cancellation did not retire the owned child promptly")
        print("PASS real probe process owner: cancellation before launch and prompt owned-child termination; no network")
    }
}
"""
(tmp/'ActualProbe.swift').write_text('import Foundation\n'+probe+fixture)
(tmp/'ProbeBoundary.swift').write_text('@MainActor final class PairedInternetRelay { var localPort:UInt16?; var username="";var password="" }\n')
PYPROBE
swiftc -swift-version 6 "$tmp/ActualProbe.swift" "$tmp/ProbeBoundary.swift" -o "$tmp/probe-cancellation"
"$tmp/probe-cancellation"
