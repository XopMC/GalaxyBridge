import Foundation
import LocalAuthentication
import Security

enum GalaxyKeychainPolicy {
    static let internalBundleIdentifier = "com.xopmc.GalaxyBridge.internal"

    static func searchQuery(
        _ attributes: [String: Any],
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String: Any] {
        var query = attributes
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = authenticationContext
        if bundleIdentifier == internalBundleIdentifier {
            // kSecUseAuthenticationUI only governs Data Protection keychain
            // queries on macOS. The internal flavor intentionally uses the
            // legacy file keychain, whose ACL evaluation is controlled by this
            // process-wide switch. Disable interaction before every query so a
            // stale ACL can fail without launching SecurityAgent.
            SecKeychainSetUserInteractionAllowed(false)
            // Legacy file-keychain reads can still invoke SecurityAgent despite
            // a non-interactive LAContext. CopyMatching supports UISkip, which
            // ignores stale/inaccessible ACL entries instead of blocking app
            // launch. Mutation queries retain UIFail so they never request UI.
            let isRead = attributes[kSecReturnData as String] as? Bool == true ||
                attributes[kSecReturnAttributes as String] as? Bool == true ||
                attributes[kSecReturnRef as String] as? Bool == true ||
                attributes[kSecReturnPersistentRef as String] as? Bool == true
            query[kSecUseAuthenticationUI as String] =
                isRead ? kSecUseAuthenticationUISkip : kSecUseAuthenticationUIFail
        } else {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func shouldAttemptLegacyRepair(after status: OSStatus) -> Bool {
        switch status {
        case errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Performs the normal, non-interactive read first. Legacy ACL repair is a
    /// fallback only for an inaccessible stable-v6 item, never part of the
    /// ordinary startup read path.
    static func copyMatchingWithLegacyRepair(
        _ query: [String: Any],
        repairAttributes: [String: Any],
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> (status: OSStatus, result: CFTypeRef?) {
        var result: CFTypeRef?
        let initialStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard bundleIdentifier == internalBundleIdentifier,
              shouldAttemptLegacyRepair(after: initialStatus)
        else { return (initialStatus, result) }

        let repairStatus = finalizeInsertion(
            matching: repairAttributes,
            bundleIdentifier: bundleIdentifier
        )
        if repairStatus == errSecSuccess {
            result = nil
            let retryStatus = SecItemCopyMatching(query as CFDictionary, &result)
            return (retryStatus, result)
        }
        if repairStatus == errSecItemNotFound {
            return (initialStatus, result)
        }
        // In particular, preserve a locked-keychain error instead of treating
        // an inaccessible identity or cache key as absent and replacing it.
        return (repairStatus, nil)
    }

    @discardableResult
    static func applyInsertionPolicy(
        to attributes: inout [String: Any],
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> OSStatus {
        if bundleIdentifier == internalBundleIdentifier {
            attributes.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            attributes.removeValue(forKey: kSecAttrAccessible as String)
            // Callers may derive an insertion dictionary from a read query.
            // UISkip is valid only for CopyMatching, so normalize every legacy
            // mutation to the non-interactive mutation policy.
            attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var access: SecAccess?
            let status = SecAccessCreate(
                "GalaxyBridge Internal" as CFString,
                nil,
                &access
            )
            guard status == errSecSuccess, let access else { return status }
            attributes[kSecAttrAccess as String] = access
        } else {
            attributes.removeValue(forKey: kSecAttrAccess as String)
            attributes[kSecUseDataProtectionKeychain as String] = true
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return errSecSuccess
    }

    @discardableResult
    static func finalizeInsertion(
        matching attributes: [String: Any],
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> OSStatus {
        guard bundleIdentifier == internalBundleIdentifier else { return errSecSuccess }

        var lookup = attributes
        for key in [
            kSecValueData,
            kSecAttrAccess,
            kSecAttrAccessible,
            kSecReturnData,
            kSecReturnAttributes,
            kSecReturnRef,
            kSecReturnPersistentRef,
            kSecMatchLimit,
            kSecUseAuthenticationContext,
            kSecUseAuthenticationUI,
            kSecUseDataProtectionKeychain,
        ] {
            lookup.removeValue(forKey: key as String)
        }
        lookup[kSecReturnRef as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        let query = searchQuery(lookup, bundleIdentifier: bundleIdentifier)
        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard lookupStatus == errSecSuccess else { return lookupStatus }
        guard let result else { return errSecInvalidItemRef }
        return finalizeInsertion(
            item: result as! SecKeychainItem,
            bundleIdentifier: bundleIdentifier
        )
    }

    @discardableResult
    static func finalizeInsertion(
        item: SecKeychainItem,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> OSStatus {
        guard bundleIdentifier == internalBundleIdentifier else { return errSecSuccess }

        // SecKeychainItemSetAccess may synchronously launch SecurityAgent and
        // block the caller when the containing file keychain is locked. Check
        // its state before inspecting or mutating the ACL. This check is
        // non-interactive and makes startup fail fast with a recoverable error.
        var keychain: SecKeychain?
        let copyKeychainStatus = SecKeychainItemCopyKeychain(item, &keychain)
        guard copyKeychainStatus == errSecSuccess, let keychain else {
            return copyKeychainStatus
        }
        var keychainStatus: SecKeychainStatus = 0
        let getStatus = SecKeychainGetStatus(keychain, &keychainStatus)
        guard getStatus == errSecSuccess else { return getStatus }
        guard keychainStatus & UInt32(kSecUnlockStateStatus) != 0 else {
            return errSecInteractionNotAllowed
        }

        var access: SecAccess?
        let copyAccessStatus = SecKeychainItemCopyAccess(item, &access)
        guard copyAccessStatus == errSecSuccess, let access else { return copyAccessStatus }

        var aclList: CFArray?
        let copyACLStatus = SecAccessCopyACLList(access, &aclList)
        guard copyACLStatus == errSecSuccess else { return copyACLStatus }

        let partitionAuthorization = kSecACLAuthorizationPartitionID as String
        var removedPartition = false
        for acl in aclList as? [SecACL] ?? [] {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard authorizations.contains(partitionAuthorization) else { continue }
            let removeStatus = SecACLRemove(acl)
            guard removeStatus == errSecSuccess else { return removeStatus }
            removedPartition = true
        }

        guard removedPartition else { return errSecSuccess }

        // A self-signed internal build has no Apple-issued TeamIdentifier, so
        // securityd otherwise writes a cdhash-only partition that changes on
        // every rebuild. The decrypt ACL remains restricted to the stable
        // trusted-application designated requirement created above.
        return SecKeychainItemSetAccess(item, access)
    }
}
