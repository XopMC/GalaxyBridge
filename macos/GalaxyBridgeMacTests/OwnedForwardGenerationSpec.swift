
import Foundation
enum Failure:Error {case dead, uncertain}
final class State:@unchecked Sendable {
 var retired=false,created=false,dieOnList=false,dieOnRemove=false,failList=false,dieAfterAllocate=false
 var commands:[[String]]=[]
}
struct ADBClient:Sendable {
 let state:State
 var acquiredGenerationIsRetired:Bool {state.retired}
 func run(arguments:[String],timeout:TimeInterval) throws->String {
  state.commands.append(arguments)
  if state.retired {throw Failure.dead}
  if arguments == ["forward","--list"] {
   if state.dieOnList {state.retired=true;throw Failure.dead}
   if state.failList {throw Failure.uncertain}
   return state.created ? "synthetic-usb tcp:42001 tcp:46737" : ""
  }
  if arguments == ["-s","synthetic-usb","forward","tcp:0","tcp:46737"] {
   state.created=true
   if state.dieAfterAllocate {state.retired=true;throw Failure.dead}
   return "42001"
  }
  if arguments == ["-s","synthetic-usb","forward","--remove","tcp:42001"] {
   if state.dieOnRemove {state.retired=true;throw Failure.dead}
   state.created=false;return ""
  }
  fatalError("unexpected command")
 }
}
// TYPES
struct Actual {
// METHOD
}
@main struct Spec {
 static func require(_ condition:Bool,_ message:String) throws {if !condition {throw NSError(domain:message,code:1)}}
 static func main() throws {
  let dead=State();let resource=try Actual.allocateForward(serial:"synthetic-usb",client:ADBClient(state:dead))
  let before=dead.commands.count;dead.retired=true
  do {try resource.remove()} catch {throw NSError(domain:"retired private daemon still quarantines its absent local forward",code:1)}
  try require(dead.commands.count == before,"cleanup touched a successor daemon")
  for phase in ["list","remove"] {
   let state=State();let r=try Actual.allocateForward(serial:"synthetic-usb",client:ADBClient(state:state))
   if phase=="list" {state.dieOnList=true} else {state.dieOnRemove=true}
   try r.remove();try require(state.retired,"fixture did not hit generation-loss boundary")
  }
  let live=State();let r=try Actual.allocateForward(serial:"synthetic-usb",client:ADBClient(state:live));live.failList=true
  do {try r.remove();fatalError("live unconfirmed cleanup was accepted")} catch Failure.uncertain {}
  let lost=State();lost.dieAfterAllocate=true
  do {_=try Actual.allocateForward(serial:"synthetic-usb",client:ADBClient(state:lost));fatalError("dead generation produced a forward lease")}
  catch ADBCompanionTunnelError.stopped {}
  print("PASS exact forward cleanup: dead private generation, loss during list/remove, no successor commands, live uncertainty retained, allocation death")
 }
}
