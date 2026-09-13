import Foundation
import Security

private enum LockedKeychainFailure: Error {
    case keychain(OSStatus)
    case unexpectedStatus(OSStatus)
    case readBlocked(TimeInterval)
}

@main
enum LockedDisposableKeychainSpec {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let path = CommandLine.arguments[1]
        let password = Array("GalaxyBridgeDisposable-v1".utf8)
        var keychain: SecKeychain?
        let createStatus = password.withUnsafeBytes { bytes in
            SecKeychainCreate(path, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain)
        }
        guard createStatus == errSecSuccess, let keychain else {
            throw LockedKeychainFailure.keychain(createStatus)
        }

        let service = "com.xopmc.GalaxyBridge.internal.locked-regression.\(UUID().uuidString)"
        let account = "locked-probe"
        var insertion = GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain,
            kSecValueData as String: Data([0x47, 0x42]),
        ], bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier)
        let policyStatus = GalaxyKeychainPolicy.applyInsertionPolicy(
            to: &insertion,
            bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier
        )
        guard policyStatus == errSecSuccess else { throw LockedKeychainFailure.keychain(policyStatus) }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw LockedKeychainFailure.keychain(addStatus) }

        let lockStatus = SecKeychainLock(keychain)
        guard lockStatus == errSecSuccess else { throw LockedKeychainFailure.keychain(lockStatus) }

        let readQuery = GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ], bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier)
        let repairQuery = GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseKeychain as String: keychain,
        ], bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier)

        let started = Date()
        let (status, _) = GalaxyKeychainPolicy.copyMatchingWithLegacyRepair(
            readQuery,
            repairAttributes: repairQuery,
            bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier
        )
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed < 2 else { throw LockedKeychainFailure.readBlocked(elapsed) }
        guard status != errSecSuccess else { throw LockedKeychainFailure.unexpectedStatus(status) }
        print("Locked disposable Keychain failed fast in \(elapsed)s with status \(status).")
    }
}
