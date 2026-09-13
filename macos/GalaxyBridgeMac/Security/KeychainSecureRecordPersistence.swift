import Foundation
import Security

/// Distribution-only secure-record backend. The Internal flavor selects the
/// local backend before this type is constructed, so Internal runtime storage
/// never reaches a SecItem API or the login Keychain.
final class KeychainSecureRecordPersistenceBackend: SecureRecordPersistenceBackend {
    func upsert(service: String, account: String, data: Data) throws {
        let query = baseQuery(service: service, account: account)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            let policyStatus = GalaxyKeychainPolicy.applyInsertionPolicy(to: &insertion)
            guard policyStatus == errSecSuccess else { throw IdentityStoreError.keychain(policyStatus) }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw IdentityStoreError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw IdentityStoreError.keychain(status)
        }
    }

    func read(service: String, account: String) throws -> Data? {
        let query = GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityStoreError.keychain(status) }
        return result as? Data
    }

    func accounts(service: String) throws -> [String] {
        let query = GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ])
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw IdentityStoreError.keychain(status) }
        return (result as? [[String: Any]] ?? []).compactMap {
            $0[kSecAttrAccount as String] as? String
        }.sorted()
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityStoreError.keychain(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ])
    }
}
