import Network
import Testing
@testable import GalaxyBridgeMac

@Suite struct CompanionTransportParametersTests {
    @Test func androidLANDoesNotRequestApplePeerToPeerRadio() {
        let parameters = CompanionTransportParameters.make(tls: NWProtocolTLS.Options())
        #expect(!parameters.includePeerToPeer)
        #expect(parameters.requiredInterfaceType == .other)
        #expect(parameters.prohibitedInterfaceTypes?.isEmpty != false)
        #expect(parameters.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
        let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        #expect(tcp?.noDelay == true)
        #expect(tcp?.enableKeepalive == true)
        #expect(tcp?.keepaliveIdle == 2)
        #expect(tcp?.keepaliveInterval == 1)
        #expect(tcp?.keepaliveCount == 3)
    }
}
