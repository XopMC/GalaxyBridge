import Foundation
import GalaxyBridgeCore

@main enum DisplayPowerControllerProtocolSpec {
    static func main() async throws {
        let mixed = #"{"version":1,"pid":123,"startTime":"456","initial":[{"id":"17","on":false},{"id":"22","on":true}],"current":[{"id":"17","on":false},{"id":"22","on":true}],"ok":true,"error":""}"#
        let header = try DisplayPowerControllerAcknowledgement.decode(Data(mixed.utf8))
        precondition(header.initial.hasActivePanel && !header.initial.isAllOff)
        let sf = "Display 17\n connectionType=Internal\n powerMode=OFF\nDisplay 22\n connectionType=Internal\n powerMode=ON\nVirtual Display 90\n powerMode=ON"
        precondition(PhonePanelPowerParser.snapshot(sf) == header.initial && PhonePanelPowerParser.parse(sf) == .unknown)
        precondition(PhonePanelPowerParser.snapshot("Display 17\n connectionType=Internal") == nil)
        let off = try header.initial.settingAllOff()
        precondition(off.isAllOff && off != header.initial)
        let repeated = try header.validating(identity: header.identity, initial: header.initial)
        precondition(repeated.current == header.initial)
        for invalid in [mixed.replacingOccurrences(of: "\"id\":\"22\"", with: "\"id\":\"17\""), mixed.replacingOccurrences(of: "\"on\":true", with: "\"on\":1"), mixed.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), mixed.replacingOccurrences(of: "\"id\":\"22\"", with: "\"id\":\"-1\""), mixed.replacingOccurrences(of: "\"id\":\"22\"", with: "\"id\":\"022\"")] {
            do { _ = try DisplayPowerControllerAcknowledgement.decode(Data(invalid.utf8)); preconditionFailure("Malformed panel acknowledgement accepted") } catch { }
        }
        do { _ = try header.validating(identity: .init(pid: 124, startTime: "456"), initial: header.initial); preconditionFailure("Cross-owner receipt accepted") } catch { }
        let restoredFailure = mixed.replacingOccurrences(of: "\"ok\":true,\"error\":\"\"", with: "\"ok\":false,\"error\":\"panel_operation_failed_restored\"")
        do { _ = try DisplayPowerControllerAcknowledgement.decode(Data(restoredFailure.utf8)); preconditionFailure("A failed command was acknowledged as success") }
        catch let rejection as DisplayPowerControllerAcknowledgement.Rejection {
            precondition(rejection.code == "panel_operation_failed_restored" && rejection.acknowledgement.current == header.initial)
            _ = try rejection.acknowledgement.validating(identity: header.identity, initial: header.initial)
        }
        var firstFrame = PhonePrivacySessionReadiness()
        precondition(!firstFrame.receive(.firstFrame) && firstFrame.receive(.controlReady))
        precondition(!firstFrame.receive(.controlReady) && !firstFrame.receive(.firstFrame))
        firstFrame.reset(); precondition(!firstFrame.isReady)
        precondition(!firstFrame.receive(.controlReady) && firstFrame.receive(.firstFrame))
        let child = Process(), childInput = Pipe(), childOutput = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["python3", "-u", "-c", #"""
import json,os,sys
initial=[{"id":"17","on":False},{"id":"22","on":True}]
current=[dict(p) for p in initial]
def ack():
 print(json.dumps(dict(version=1,pid=os.getpid(),startTime="1",initial=initial,current=current,ok=True,error="")),flush=True)
ack()
while True:
 b=sys.stdin.buffer.read(1)
 if not b:
  current=[dict(p) for p in initial]
  break
 if b==bytes([0]): current=[dict(id=p["id"],on=False) for p in initial]
 elif b==bytes([1]): current=[dict(p) for p in initial]
 elif b==bytes([2]):
  current=[dict(p) for p in initial]
  ack()
  break
 ack()
"""#]
        child.standardInput = childInput; child.standardOutput = childOutput; child.standardError = FileHandle.nullDevice
        try child.run(); try childInput.fileHandleForReading.close(); try childOutput.fileHandleForWriting.close()
        let io = DisplayPowerControllerProcess(process: child, input: childInput.fileHandleForWriting, output: childOutput.fileHandleForReading)
        let live = try await io.exchange(nil)
        let hidden = try await io.exchange(0)
        precondition(hidden.current.isAllOff)
        let restored = try await io.exchange(2)
        precondition(restored.initial == live.initial && restored.current == live.initial)
        try await io.closeAndWait(); try await io.closeAndWait()
        let rejectedChild = Process(), rejectedInput = Pipe(), rejectedOutput = Pipe()
        rejectedChild.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        rejectedChild.arguments = ["python3", "-u", "-c", #"""
import json,os,sys
initial=[{"id":"17","on":False},{"id":"22","on":True}]
print(json.dumps(dict(version=1,pid=os.getpid(),startTime="1",initial=initial,current=initial,ok=True,error="")),flush=True)
sys.stdin.buffer.read(1)
print(json.dumps(dict(version=1,pid=os.getpid(),startTime="1",initial=[],current=[],ok=False,error="panel_inventory_unavailable")),flush=True)
sys.exit(1)
"""#]
        rejectedChild.standardInput = rejectedInput; rejectedChild.standardOutput = rejectedOutput; rejectedChild.standardError = FileHandle.nullDevice
        try rejectedChild.run(); try rejectedInput.fileHandleForReading.close(); try rejectedOutput.fileHandleForWriting.close()
        let rejectedIO = DisplayPowerControllerProcess(process: rejectedChild, input: rejectedInput.fileHandleForWriting, output: rejectedOutput.fileHandleForReading)
        _ = try await rejectedIO.exchange(nil)
        do { _ = try await rejectedIO.exchange(0); preconditionFailure("Post-mutation error was accepted") }
        catch is DisplayPowerControllerAcknowledgement.StartupFailure { }
        do { try await rejectedIO.closeAndWait(); preconditionFailure("Startup exit1 waiver was reused after a mutating command") }
        catch DisplayPowerControllerProcess.ProcessError.controllerRestorationFailed { }
        print("PASS mixed physical panel snapshots, strict bounded child acknowledgements, exact owner identity and both initial readiness orders")
    }
}
