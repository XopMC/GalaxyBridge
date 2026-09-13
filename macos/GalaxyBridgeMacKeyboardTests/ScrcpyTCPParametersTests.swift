import Network
import Testing
@testable import GalaxyBridgeMac

struct ScrcpyTCPParametersTests {
    @Test func forwardedScrcpySocketsDisableNagleDelay() throws {
        let parameters = ScrcpyTCPParameters.make()
        let tcp = try #require(
            parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
        )

        #expect(tcp.noDelay)
    }
}
