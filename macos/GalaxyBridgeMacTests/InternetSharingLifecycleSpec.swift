import Foundation
import Combine

struct GBInternetSharingRequest { var requestID=""; var leaseID=""; var enabled=false }
struct GBInternetSharingStatus { var requestID=""; var leaseID=""; var enabled=false; var errorCode=""; var upstream="unavailable"; var bytesSent:UInt64=0; var bytesReceived:UInt64=0 }
struct TestPeer { var deviceID="phone" }
final class CompanionTLSClient {
    var supportsInternetGateway=true; var peer:TestPeer; var resolvedEndpoint="loopback"
    var authenticatedSessionID=UUID().uuidString; var sent:[GBInternetSharingRequest]=[]
    init(_ id:String="phone") { peer=TestPeer(deviceID:id) }
    func sendInternetSharing(_ request:GBInternetSharingRequest)throws { sent.append(request) }
}
enum InternetGatewaySelectionPolicy:Equatable {case automatic,balanced,fixed(Int)}
enum InternetTunnelDriverState {case idle,starting,running,failed(String)}
@MainActor final class TestGate {
    var open=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    func wait()async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release(){open=true;let saved=waiters;waiters=[];saved.forEach{$0.resume()}}
}
@MainActor final class InternetTunnelDriver:ObservableObject {
    static var last:InternetTunnelDriver!
    @Published var state=InternetTunnelDriverState.idle
    var gatewayDeviceIDs:[String?]=[nil,nil];var totalFlowStarted:[UInt64]=[0,0]
    var starts:[[String]]=[];var active:Set<String>=[];var policy:InternetGatewaySelectionPolicy = .automatic
    var healthyPeers:Set<String>=[]
    enum StartFailure {case rejectedBeforeMutation,destroyed,unproven}
    var nextStartFailure:StartFailure?
    var relays:[String:PairedInternetRelay]=[:]
    var startGate:TestGate?;var activeStarts=0;var maximumConcurrentStarts=0;var stops=0
    init(){Self.last=self}
    var hasActiveTopology:Bool { if case .running=state{return true};return false }
    func start(gatewayRelays:[PairedInternetRelay],userApproved:Bool)async throws{
        activeStarts+=1;maximumConcurrentStarts=max(maximumConcurrentStarts,activeStarts)
        defer{activeStarts-=1}
        let ids=gatewayRelays.map{$0.peer.deviceID};starts.append(ids)
        if let startGate { await startGate.wait() }
        try Task.checkCancellation()
        if let failure=nextStartFailure, ids.contains("B") {
            nextStartFailure=nil
            switch failure {
            case .rejectedBeforeMutation:
                throw InternetTunnelAdmissionRejection(retainedRelays:Set(relays.values.map(ObjectIdentifier.init)))
            case .destroyed:
                active=[];relays.values.forEach{$0.stop()};relays=[:];state = .failed("destroyed")
            case .unproven:break
            }
            throw URLError(.networkConnectionLost)
        }
        active=Set(ids)
        relays=Dictionary(uniqueKeysWithValues:gatewayRelays.map{($0.peer.deviceID,$0)})
        for id in ids where !gatewayDeviceIDs.contains(id) {
            if let index=gatewayDeviceIDs.firstIndex(of:nil){gatewayDeviceIDs[index]=id}
        }
        state = .running
    }
    func stop()async{stops+=1;active=[];gatewayDeviceIDs=[nil,nil];state = .idle}
    func updatePolicy(_ value:InternetGatewaySelectionPolicy){policy=value}
    func setHealthyPeers(_ ids:Set<String>){healthyPeers=ids}
    func uninstallHelper()async throws{}
}
@MainActor final class PairedInternetRelay {
    let peer:TestPeer;let username:String;let password:String;var localPort:UInt16?;var stopped=false
    init(endpoint:String,peer:TestPeer,hostID:String,sessionID:String,leaseID:String,username:String,password:String){self.peer=peer;self.username=username;self.password=password}
    func start()async throws->UInt16 { stopped=false;localPort=43123;return 43123 }
    func stop(){stopped=true;localPort=nil}
}
@MainActor enum InternetGatewayProbe {
    static var privateGates:[String:TestGate]=[:];static var privateCalls:[String]=[]
    static var defaultCalls=0;static var incrementCounters=true
    static func reset(){privateGates=[:];privateCalls=[];defaultCalls=0;incrementCounters=true}
    static func verify(relay:PairedInternetRelay)async throws{
        privateCalls.append(relay.peer.deviceID)
        if let gate=privateGates[relay.peer.deviceID]{await gate.wait()}
        try Task.checkCancellation()
    }
    static func verifyDefaultRoute()async throws {
        defaultCalls+=1
        if incrementCounters {
            let driver=InternetTunnelDriver.last!
            let index:Int
            if case let .fixed(slot)=driver.policy{index=slot}else{index=driver.gatewayDeviceIDs.firstIndex(where:{$0.map(driver.active.contains) == true}) ?? 0}
            driver.totalFlowStarted[index]+=1
        }
        try Task.checkCancellation()
    }
}

@main struct InternetSharingLifecycleSpec {
    @MainActor static func settle(_ rounds:Int=40)async{for _ in 0..<rounds{await Task.yield()}}
    @MainActor static func ready(_ c:InternetSharingCoordinator,_ control:CompanionTLSClient,id:String){
        var status=GBInternetSharingStatus();status.enabled=true;status.leaseID=control.sent.first{$0.enabled}!.leaseID;status.upstream="wifi"
        c.receive(status,deviceID:id,control:control)
    }
    @MainActor static func main()async throws{
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A"),b=CompanionTLSClient("B")
            c.selection="balanced"
            c.setEnabled(true,deviceID:"A",control:a);c.setEnabled(true,deviceID:"B",control:b)
            ready(c,a,id:"A");ready(c,b,id:"B");await settle(100)
            let driver=InternetTunnelDriver.last!,establishedB=driver.relays["B"]!
            c.selection="A";await settle(100)
            let stops=driver.stops,probes=InternetGatewayProbe.defaultCalls
            var unavailable=GBInternetSharingStatus();unavailable.enabled=true
            unavailable.leaseID=a.sent[0].leaseID;unavailable.upstream="unavailable";unavailable.errorCode="no_validated_upstream"
            c.receive(unavailable,deviceID:"A",control:a);await settle(100)
            precondition(driver.active == ["B"] && driver.stops == stops && !establishedB.stopped,
                "Unavailable fixed A must retain B's established flows instead of stopping the global tunnel")
            precondition(driver.healthyPeers.isEmpty && driver.policy == .fixed(0),
                "Keeping B's existing flows must not admit new flows or DNS through B under fixed A")
            precondition(c.devices["A"]?.key == "INTERNET_WAITING" && c.devices["B"]?.key == "INTERNET_WAITING",
                "No phone may advertise ready while the chosen fixed gateway is unavailable")
            precondition(InternetGatewayProbe.defaultCalls == probes,
                "An intentionally closed new-flow policy must not run an impossible readiness probe")
            c.selection="balanced";await settle(100)
            precondition(c.devices["B"]?.key == "INTERNET_READY" && driver.healthyPeers == ["B"],
                "Returning to balancing must reverify and reopen the healthy retained phone")
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),b=CompanionTLSClient("B")
            c.selection="never-enabled-A"
            c.setEnabled(true,deviceID:"B",control:b);ready(c,b,id:"B");await settle(100)
            precondition(InternetTunnelDriver.last.starts.isEmpty && c.devices["B"]?.key == "INTERNET_WAITING",
                "Retaining established flows must not install a new tunnel while the fixed peer is unavailable")
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A"),b=CompanionTLSClient("B")
            c.setEnabled(true,deviceID:"A",control:a);ready(c,a,id:"A");await settle(100)
            let driver=InternetTunnelDriver.last!,established=driver.relays["A"]!
            precondition(c.devices["A"]?.key == "INTERNET_READY")
            driver.nextStartFailure = .rejectedBeforeMutation
            c.setEnabled(true,deviceID:"B",control:b);ready(c,b,id:"B");await settle(100)
            precondition(c.devices["A"]?.enabled == true && c.devices["A"]?.key == "INTERNET_READY",
                "Rejecting B before mutation must preserve the already verified A gateway")
            precondition(!established.stopped && a.sent.allSatisfy{$0.enabled},
                "Failed admission of B must not stop A's relay or phone lease")
            precondition(c.devices["B"]?.enabled == false && c.devices["B"]?.key == "INTERNET_FAILED" && b.sent.last?.enabled == false,
                "The rejected new phone must roll back its lease and report failure")
            await c.stop()
        }
        for failure in [InternetTunnelDriver.StartFailure.destroyed,.unproven] {
            InternetGatewayProbe.reset()
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A"),b=CompanionTLSClient("B")
            c.setEnabled(true,deviceID:"A",control:a);ready(c,a,id:"A");await settle(100)
            InternetTunnelDriver.last.nextStartFailure=failure
            c.setEnabled(true,deviceID:"B",control:b);ready(c,b,id:"B");await settle(100)
            precondition(c.devices["A"]?.enabled == false && c.devices["B"]?.enabled == false,
                "A destroyed or unproven topology must fail closed for every affected phone")
            precondition(c.devices.values.allSatisfy{$0.key != "INTERNET_READY"})
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A")
            c.setEnabled(true,deviceID:"A",control:a)
            var denied=GBInternetSharingStatus();denied.leaseID=a.sent[0].leaseID;denied.errorCode="internet_sharing_not_allowed"
            c.receive(denied,deviceID:"A",control:a)
            precondition(c.devices["A"]?.key == "INTERNET_PHONE_PERMISSION_REQUIRED" && c.devices["A"]?.enabled == false,
                "Denied phone consent must explain how to recover instead of reporting a generic gateway failure")
            precondition(a.sent.last?.enabled == false && a.sent.last?.leaseID == denied.leaseID,
                "Consent denial must retire the exact gateway lease")
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A")
            c.setEnabled(true,deviceID:"A",control:a);ready(c,a,id:"A");await settle(100)
            c.selection="never-enabled-B"
            precondition(InternetTunnelDriver.last.policy != .automatic && InternetTunnelDriver.last.healthyPeers.isEmpty,
                "An unresolved fixed phone must close new flows immediately, before asynchronous tunnel retirement")
            await settle(100)
            precondition(InternetTunnelDriver.last.active == ["A"] && c.devices["A"]?.key == "INTERNET_WAITING",
                "An unresolved fixed phone must retain established flows while closing new admission")
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A"),b=CompanionTLSClient("B")
            precondition(!c.isSelectableGateway(deviceID:"A"),"Never-enabled phones must not appear as usable fixed gateways")
            c.setEnabled(true,deviceID:"A",control:a);c.setEnabled(true,deviceID:"B",control:b)
            ready(c,a,id:"A");ready(c,b,id:"B");await settle(100)
            precondition(c.isSelectableGateway(deviceID:"A") && c.isSelectableGateway(deviceID:"B"))
            c.selection="A";await settle(100)
            precondition(InternetTunnelDriver.last.healthyPeers == ["A"],"Fixed policy must constrain DNS and new-flow health to the selected phone")
            c.forget(deviceID:"A");await settle(100)
            precondition(c.selection == "automatic" && c.devices["A"] == nil && !c.isSelectableGateway(deviceID:"A"))
            precondition(InternetTunnelDriver.last.active == ["B"] && c.devices["B"]?.key == "INTERNET_READY",
                "Forgetting the fixed phone must leave a valid policy and usable sharing through the remaining phone")
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A")
            c.setEnabled(true,deviceID:"A",control:a);ready(c,a,id:"A");await settle(100)
            var publications=0
            let observation=c.$devices.dropFirst().sink { _ in publications += 1 }
            var status=GBInternetSharingStatus();status.enabled=true;status.leaseID=a.sent[0].leaseID
            status.upstream="wifi";status.bytesSent=17;status.bytesReceived=29
            c.receive(status,deviceID:"A",control:a)
            precondition(publications == 1,"One status must publish its upstream and both counters as one presentation")
            c.receive(status,deviceID:"A",control:a)
            precondition(publications == 1,"An unchanged heartbeat must not invalidate the device workspace")
            status.upstream="cellular";c.receive(status,deviceID:"A",control:a)
            precondition(c.devices["A"]?.key == "INTERNET_WAITING",
                "Changing upstream must withdraw readiness until fresh probes complete")
            observation.cancel();await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),control=CompanionTLSClient("vpn-phone")
            c.setEnabled(true,deviceID:"vpn-phone",control:control)
            var pending=GBInternetSharingStatus();pending.enabled=true
            pending.leaseID=control.sent[0].leaseID;pending.upstream="unavailable"
            pending.errorCode="vpn_upstream_unavailable"
            c.receive(pending,deviceID:"vpn-phone",control:control)
            precondition(c.devices["vpn-phone"]?.enabled==true,
                "A temporarily unavailable required phone VPN must preserve sharing intent and never claim readiness")
            precondition(c.devices["vpn-phone"]?.key != "INTERNET_READY")
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),old=CompanionTLSClient()
            c.setEnabled(true,deviceID:"phone",control:old)
            var waiting=GBInternetSharingStatus();waiting.enabled=true;waiting.leaseID=old.sent[0].leaseID;waiting.errorCode="no_validated_upstream"
            c.receive(waiting,deviceID:"phone",control:old)
            precondition(c.devices["phone"]?.enabled==true)
            c.retire(deviceID:"phone",control:old)
            precondition(c.devices["phone"]?.enabled==true)
            c.setEnabled(false,deviceID:"phone",control:nil)
            precondition(c.devices["phone"]?.enabled==false)
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A"),b=CompanionTLSClient("B")
            let privateA=TestGate(),driverGate=TestGate()
            InternetGatewayProbe.privateGates["A"]=privateA
            let driver=InternetTunnelDriver.last!;driver.startGate=driverGate
            c.setEnabled(true,deviceID:"A",control:a);c.setEnabled(true,deviceID:"B",control:b)
            ready(c,a,id:"A");ready(c,b,id:"B");await settle()
            precondition(driver.starts.allSatisfy{!$0.contains("A")},"Unprobed A cannot enter B's tunnel topology")
            privateA.release();await settle()
            precondition(driver.maximumConcurrentStarts<=1,"Global tunnel mutations must serialize even while two peer probes finish")
            driverGate.release();await settle(100)
            precondition(driver.active==Set(["A","B"]))
            precondition(InternetGatewayProbe.defaultCalls>0,"READY requires a fresh default-route HTTPS probe after tunnel start")
            c.setEnabled(false,deviceID:"A",control:nil);await settle(100)
            c.selection="B";await settle(100)
            precondition(driver.gatewayDeviceIDs[1]=="B"&&driver.policy == .fixed(1),"Fixed B must follow stable driver slot1 after A leaves")
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),old=CompanionTLSClient("A"),fresh=CompanionTLSClient("A")
            c.setEnabled(true,deviceID:"A",control:old)
            let driver=InternetTunnelDriver.last!
            driver.state = .failed("old-generation")
            c.setEnabled(false,deviceID:"A",control:nil)
            c.setEnabled(true,deviceID:"A",control:fresh)
            await settle(100)
            precondition(c.devices["A"]?.enabled==true,"Queued old driver failure cannot retire a new device generation")
            await c.stop()
        }
        InternetGatewayProbe.reset()
        do {
            let c=InternetSharingCoordinator(),a=CompanionTLSClient("A"),b=CompanionTLSClient("B")
            let driver=InternetTunnelDriver.last!,gate=TestGate();driver.startGate=gate
            c.setEnabled(true,deviceID:"A",control:a);ready(c,a,id:"A");await settle()
            precondition(driver.activeStarts==1)
            let stopping=Task { @MainActor in await c.stop() }
            await settle()
            c.setEnabled(true,deviceID:"B",control:b);ready(c,b,id:"B");await settle()
            precondition(driver.maximumConcurrentStarts==1,"Restart cannot overlap an in-flight retired helper operation")
            gate.release();await settle(100);await stopping.value
            precondition(driver.active==Set(["B"]) && c.devices["B"]?.enabled==true,
                "An old Stop completion cannot tear down a newer explicit restart")
            await c.stop()
        }
        InternetGatewayProbe.reset();InternetGatewayProbe.incrementCounters=false
        do {
            let c=InternetSharingCoordinator(),control=CompanionTLSClient("A")
            c.setEnabled(true,deviceID:"A",control:control);ready(c,control,id:"A")
            await settle(100)
            precondition(c.devices["A"]?.key != "INTERNET_READY","HTTPS success without a native TUN flow increase must not claim tunnel acceptance")
            await c.stop()
        }
        print("PASS actual internet coordinator: isolated admission rejection, destructive/unproven failure closure, fixed-peer established-flow retention with closed new admission/DNS and honest waiting state, phone consent/lease cleanup, intent/handoff, serialized probes, stable slots, stale failure fence and native-flow readiness proof")
    }
}
