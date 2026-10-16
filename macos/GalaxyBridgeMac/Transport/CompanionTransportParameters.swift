import Network

/// Android Companion uses ordinary LAN endpoints, including Wi-Fi and Ethernet.
/// Apple peer-to-peer Wi-Fi cannot reach an Android peer and may interrupt the
/// infrastructure radio while interactive video/control is active.
enum CompanionTransportParameters {
    static func make(tls: NWProtocolTLS.Options) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}
