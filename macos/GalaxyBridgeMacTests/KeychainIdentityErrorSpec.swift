import Foundation
import Security

@main
struct KeychainIdentityErrorSpec {
    static func main() {
        for status in [errSecDuplicateItem, errSecAuthFailed, errSecInteractionNotAllowed] {
            let error = IdentityStoreError.keychain(status)
            let diagnostic = error as NSError
            precondition(diagnostic.code == Int(status), "Keychain status must survive NSError bridging")
            precondition(diagnostic.domain == IdentityStoreError.errorDomain)
            precondition(diagnostic.localizedDescription == error.localizedDescription,
                         "Bridging must preserve localized user guidance")
            precondition(!error.localizedDescription.contains(String(status)),
                         "The numeric status belongs in diagnostics, not user-facing copy")
            precondition(!error.localizedDescription.contains("error 0"))
        }
        print("Keychain identity error diagnostics passed.")
    }
}
