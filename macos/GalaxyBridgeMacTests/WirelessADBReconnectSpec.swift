import Foundation

@main
enum WirelessADBReconnectSpec {
    static func main() {
        let peer = WirelessADBReconnectPeer(deviceID: "one", endpoint: "192.168.1.2:40000", hardwareSerial: "PHONE", verifiedAt: Date())
        let mdns = "adb-OTHER-abc\t_adb-tls-connect._tcp\t192.168.1.9:41000\nadb-PHONE-abc\t_adb-tls-connect._tcp\t192.168.1.2:42000"
        precondition(WirelessADBReconnectPolicy.candidates(peers: [peer], connectedSerials: [], mdnsServices: mdns) == ["192.168.1.2:42000"])
        precondition(WirelessADBReconnectPolicy.candidates(peers: [peer], connectedSerials: ["adb-PHONE-abc"], mdnsServices: mdns).isEmpty)
        precondition(WirelessADBReconnectPolicy.candidates(peers: [peer], connectedSerials: [peer.endpoint], mdnsServices: "").isEmpty)
        precondition(WirelessADBReconnectPolicy.candidates(peers: [peer], connectedSerials: [], mdnsServices: "") == [peer.endpoint])
        let stale = WirelessADBReconnectPeer(deviceID: "one", endpoint: "192.168.1.3:30000", hardwareSerial: nil, verifiedAt: .distantPast)
        precondition(WirelessADBReconnectPolicy.candidates(peers: [stale, peer], connectedSerials: [], mdnsServices: "") == [peer.endpoint])
        for invalid in ["8.8.8.8:40000", "192.168.1.2:0", "192.168.1.2:99999", "192.168.1.256:1234", "192.168.1.2:44;open", "-s"] {
            precondition(!WirelessADBReconnectPolicy.isLocalEndpoint(invalid))
        }
        print("PASS wireless ADB reconnect follows the paired hardware across port changes without discovering unrelated phones")
    }
}
