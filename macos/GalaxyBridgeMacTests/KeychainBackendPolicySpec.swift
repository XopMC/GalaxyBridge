import Foundation
import LocalAuthentication
import Security

@main
struct KeychainBackendPolicySpec {
    static func main() {
        let internalID = "com.xopmc.GalaxyBridge.internal"
        let distributionID = "com.xopmc.GalaxyBridge"
        let base = [kSecClass as String: kSecClassGenericPassword]

        let internalQuery = GalaxyKeychainPolicy.searchQuery(base, bundleIdentifier: internalID)
        precondition(internalQuery[kSecUseDataProtectionKeychain as String] == nil)
        let internalContext = internalQuery[kSecUseAuthenticationContext as String] as? LAContext
        precondition(internalContext?.interactionNotAllowed == true)
        precondition(
            String(describing: internalQuery[kSecUseAuthenticationUI as String]!) ==
                String(describing: kSecUseAuthenticationUIFail)
        )
        let internalReadQuery = GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ], bundleIdentifier: internalID)
        precondition(
            String(describing: internalReadQuery[kSecUseAuthenticationUI as String]!) ==
                String(describing: kSecUseAuthenticationUISkip)
        )
        var internalInsertDerivedFromRead = internalReadQuery
        let derivedInsertStatus = GalaxyKeychainPolicy.applyInsertionPolicy(
            to: &internalInsertDerivedFromRead,
            bundleIdentifier: internalID
        )
        precondition(derivedInsertStatus == errSecSuccess)
        precondition(
            String(describing: internalInsertDerivedFromRead[kSecUseAuthenticationUI as String]!) ==
                String(describing: kSecUseAuthenticationUIFail)
        )

        var internalInsert = internalQuery
        let internalStatus = GalaxyKeychainPolicy.applyInsertionPolicy(
            to: &internalInsert,
            bundleIdentifier: internalID
        )
        precondition(internalStatus == errSecSuccess)
        precondition(internalInsert[kSecAttrAccess as String] != nil)
        precondition(internalInsert[kSecAttrAccessible as String] == nil)

        let distributionQuery = GalaxyKeychainPolicy.searchQuery(base, bundleIdentifier: distributionID)
        precondition(distributionQuery[kSecUseDataProtectionKeychain as String] as? Bool == true)
        let distributionContext = distributionQuery[kSecUseAuthenticationContext as String] as? LAContext
        precondition(distributionContext?.interactionNotAllowed == true)
        precondition(distributionQuery[kSecUseAuthenticationUI as String] == nil)

        var distributionInsert = distributionQuery
        let distributionStatus = GalaxyKeychainPolicy.applyInsertionPolicy(
            to: &distributionInsert,
            bundleIdentifier: distributionID
        )
        precondition(distributionStatus == errSecSuccess)
        precondition(distributionInsert[kSecAttrAccess as String] == nil)
        precondition(
            String(describing: distributionInsert[kSecAttrAccessible as String]!) ==
                String(describing: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        )

        print("Keychain backend policy passed.")
    }
}
