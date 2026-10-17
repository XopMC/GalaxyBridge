
import Foundation
import CryptoKit
struct Peer: Sendable { let deviceID="synthetic-phone"; let identityPublicKey=Data([1,2,3]); let pairedAt=Date(timeIntervalSince1970:1) }
typealias PairedPeer=Peer
struct Row { enum Transport {case usbADB}; let transport=Transport.usbADB; let isReady=true; let adbSerial:String?="synthetic-usb" }
struct ADBBindingStore {func isVerified(serial:String,peer:Peer)->Bool {serial=="synthetic-usb" && peer.deviceID=="synthetic-phone"}}
@MainActor final class ADBOwnedRuntime {static let shared=ADBOwnedRuntime();var activeGeneration:UUID?=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!}
struct ADBCompanionTunnelLease:Sendable {let token=UUID();let peerID:String;let serial:String;let port:UInt16=42001}
actor FixtureGate {
 var entered=false
 private var waiter:CheckedContinuation<Void,Never>?
 func wait() async {entered=true;await withCheckedContinuation {waiter=$0}}
 func release() {waiter?.resume();waiter=nil}
}
actor ADBCompanionTunnelCoordinator {
 private var acquisitionGate:FixtureGate?,retirementGate:FixtureGate?
 private(set) var acquisitions=0,releases=0
 func holdAcquisition(_ gate:FixtureGate){acquisitionGate=gate}
 func holdRetirement(_ gate:FixtureGate){retirementGate=gate}
 func acquire(peerID:String,serial:String) async throws->ADBCompanionTunnelLease {
  acquisitions += 1
  if let gate=acquisitionGate {acquisitionGate=nil;await gate.wait()}
  return .init(peerID:peerID,serial:serial)
 }
 func release(_ lease:ADBCompanionTunnelLease) async throws {
  releases += 1
  if let gate=retirementGate {retirementGate=nil;await gate.wait()}
 }
}
@MainActor final class Model {
 struct Admission {var admitsWork=true}
 var terminationAdmission=Admission();let adbRows=[Row()]
 var observedADBGeneration=ADBOwnedRuntime.shared.activeGeneration
 let companionTunnels=ADBCompanionTunnelCoordinator()
 var companionTunnelLeases:[String:ADBCompanionTunnelLease]=[:]
 var companionTunnelDesired:[String:(scope:String,serial:String)]=[:]
 var companionTunnelTasks:[String:Task<Void,Never>]=[:]
 var companionTunnelTokens:[String:UUID]=[:]
 var fileTransferStatus:[String:String]=[:]
 var retired:[String]=[]
 func retireCompanionTunnelRoute(deviceID:String) {retired.append(deviceID)}
 func companionFiles(for id:String)->Int? {nil}
 func mergeDevices() {reconcileCompanionTunnels(peers:[Peer()])}
 // ACTUAL
}
@main struct Spec {
 @MainActor static func settle(_ model:Model) async {
  for _ in 0..<1000 {
   let tasks=Array(model.companionTunnelTasks.values)
   if tasks.isEmpty {return}
   for task in tasks {await task.value}
  }
  fatalError("coordinator did not settle bounded fixture work")
 }
 @MainActor static func waitUntilEntered(_ gate:FixtureGate) async {
  for _ in 0..<1000 {if await gate.entered {return};await Task.yield()}
  fatalError("fixture never reached the ownership barrier")
 }
 @MainActor static func main() async throws {
  let first=UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,second=UUID(uuidString:"00000000-0000-0000-0000-000000000002")!
  ADBOwnedRuntime.shared.activeGeneration=first
  let model=Model(),peer=Peer(),id="device:synthetic-phone"
  model.reconcileCompanionTunnels(peers:[peer]);await settle(model)
  let old=model.companionTunnelLeases[id]!.token
  model.observedADBGeneration=second
  model.reconcileCompanionTunnels(peers:[peer]);await settle(model)
  guard model.companionTunnelLeases[id]?.token != old,model.retired==[id] else {
   throw NSError(domain:"replacement daemon with unchanged serial retained the old Helper USB forward lease",code:1)
  }
  let new=model.companionTunnelLeases[id]!.token
  model.reconcileCompanionTunnels(peers:[peer]);await settle(model)
  guard model.companionTunnelLeases[id]?.token == new,model.retired.count==1 else {fatalError("healthy new generation was replaced again")}

  let ordered=Model();ordered.reconcileCompanionTunnels(peers:[peer]);await settle(ordered)
  let retiring=FixtureGate();await ordered.companionTunnels.holdRetirement(retiring)
  ordered.observedADBGeneration=second;ordered.reconcileCompanionTunnels(peers:[peer]);await waitUntilEntered(retiring)
  ordered.reconcileCompanionTunnels(peers:[peer])
  guard ordered.companionTunnelLeases[id]==nil,await ordered.companionTunnels.acquisitions==1 else {
   fatalError("successor forward allocation overlapped unconfirmed old retirement")
  }
  await retiring.release();await settle(ordered)
  guard ordered.companionTunnelLeases[id] != nil,await ordered.companionTunnels.acquisitions==2 else {fatalError("settled retirement failed to resume latest intent")}

  let pending=Model(),admitted=FixtureGate();await pending.companionTunnels.holdAcquisition(admitted)
  pending.reconcileCompanionTunnels(peers:[peer]);await waitUntilEntered(admitted)
  pending.observedADBGeneration=second;pending.reconcileCompanionTunnels(peers:[peer])
  await admitted.release();await settle(pending)
  guard pending.companionTunnelLeases[id]?.peerID.hasSuffix(second.uuidString)==true,
        await pending.companionTunnels.acquisitions==2,await pending.companionTunnels.releases==1 else {
   fatalError("stale acquisition completion lost the new daemon's desired scope")
  }

  let stopping=Model();stopping.reconcileCompanionTunnels(peers:[peer]);await settle(stopping)
  let exit=FixtureGate();await stopping.companionTunnels.holdRetirement(exit)
  stopping.observedADBGeneration=second;stopping.reconcileCompanionTunnels(peers:[peer]);await waitUntilEntered(exit)
  stopping.terminationAdmission.admitsWork=false;await exit.release();await settle(stopping)
  guard stopping.companionTunnelLeases[id]==nil,await stopping.companionTunnels.acquisitions==1 else {fatalError("shutdown reopened the Helper transport")}
  print("PASS actual Model Helper tunnel: unchanged-serial daemon replacement, healthy coalescing, retirement barrier, stale pending creation and shutdown")
 }
}
