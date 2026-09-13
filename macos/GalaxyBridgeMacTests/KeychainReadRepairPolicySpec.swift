import Foundation
import Security

@main
struct KeychainReadRepairPolicySpec {
    static func main() {
        precondition(!GalaxyKeychainPolicy.shouldAttemptLegacyRepair(after: errSecSuccess))
        precondition(!GalaxyKeychainPolicy.shouldAttemptLegacyRepair(after: errSecParam))
        precondition(GalaxyKeychainPolicy.shouldAttemptLegacyRepair(after: errSecItemNotFound))
        precondition(GalaxyKeychainPolicy.shouldAttemptLegacyRepair(after: errSecAuthFailed))
        precondition(GalaxyKeychainPolicy.shouldAttemptLegacyRepair(after: errSecInteractionNotAllowed))
        print("Keychain read repair policy passed.")
    }
}
