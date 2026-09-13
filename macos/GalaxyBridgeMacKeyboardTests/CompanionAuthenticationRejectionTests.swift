import GalaxyBridgeProtocol
import Testing
@testable import GalaxyBridgeMac

@Suite("Companion authentication rejection")
struct CompanionAuthenticationRejectionTests {
    @Test("Only stable authentication codes become terminal recovery states")
    func stableCodes() {
        #expect(
            CompanionAuthenticationRejection.message(
                for: CompanionAuthenticationRejection.pairingRequiredCode
            )?.isEmpty == false
        )
        #expect(
            CompanionAuthenticationRejection.message(
                for: CompanionAuthenticationRejection.authenticationFailedCode
            )?.isEmpty == false
        )
        #expect(CompanionAuthenticationRejection.message(for: "unsupported_payload") == nil)
        #expect(CompanionAuthenticationRejection.message(for: "") == nil)
    }
}
