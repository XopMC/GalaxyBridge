import Foundation
import Security

private enum ProbeFailure: Error {
    case invalidInvocation
    case keychain(OSStatus)
    case unexpectedValue(String)
}

@main
enum InternalKeychainRebuildProbe {
    #if GB_FIRST_REBUILD
    private static let rebuildMarker = "first-build"
    #else
    private static let rebuildMarker = "second-build-with-changed-code"
    #endif

    static func main() {
        do {
            try run()
        } catch {
            if ProcessInfo.processInfo.environment["GALAXYBRIDGE_PROBE_DIAGNOSTICS"] == "1" {
                FileHandle.standardError.write(Data("probe failure: \(error)\n".utf8))
            }
            exit(20)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 3,
              !rebuildMarker.isEmpty
        else { throw ProbeFailure.invalidInvocation }

        let operation = CommandLine.arguments[1]
        let service = CommandLine.arguments[2]
        let account = "rebuild-probe"

        switch operation {
        case "add-read":
            var insertion = baseQuery(service: service, account: account)
            insertion[kSecValueData as String] = Data([0x11, 0x22, 0x33])
            let policyStatus = GalaxyKeychainPolicy.applyInsertionPolicy(
                to: &insertion,
                bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier
            )
            try requireSuccess(policyStatus)
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            try requireSuccess(addStatus)
            if ProcessInfo.processInfo.environment["GALAXYBRIDGE_PROBE_SKIP_FINALIZE"] != "1" {
                try requireSuccess(GalaxyKeychainPolicy.finalizeInsertion(
                    matching: insertion,
                    bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier
                ))
            }
            guard try read(service: service, account: account) == Data([0x11, 0x22, 0x33])
            else { throw ProbeFailure.unexpectedValue("initial-read") }

        case "update-enumerate-delete":
            let query = baseQuery(service: service, account: account)
            if ProcessInfo.processInfo.environment["GALAXYBRIDGE_PROBE_RECOVER_PARTITION"] == "1" {
                try requireSuccess(GalaxyKeychainPolicy.finalizeInsertion(
                    matching: query,
                    bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier
                ))
            }
            guard try read(service: service, account: account) == Data([0x11, 0x22, 0x33])
            else { throw ProbeFailure.unexpectedValue("pre-update-rebuild-read") }
            try requireSuccess(SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: Data([0x44, 0x55, 0x66, 0x77])] as CFDictionary
            ))
            guard try read(service: service, account: account) == Data([0x44, 0x55, 0x66, 0x77])
            else { throw ProbeFailure.unexpectedValue("updated-read") }
            guard try enumeratedAccounts(service: service) == [account]
            else { throw ProbeFailure.unexpectedValue("enumeration") }
            try requireSuccess(SecItemDelete(query as CFDictionary))
            guard try read(service: service, account: account) == nil
            else { throw ProbeFailure.unexpectedValue("delete") }

        case "assert-denied-noninteractive":
            let query = readQuery(service: service, account: account)
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status != errSecSuccess else {
                throw ProbeFailure.unexpectedValue("untrusted-read")
            }

        case "cleanup-delete":
            let query = baseQuery(service: service, account: account)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ProbeFailure.keychain(status)
            }

        default:
            throw ProbeFailure.invalidInvocation
        }
    }

    private static func baseQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ], bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier)
    }

    private static func read(
        service: String,
        account: String
    ) throws -> Data? {
        let query = readQuery(service: service, account: account)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try requireSuccess(status)
        guard let data = result as? Data else { throw ProbeFailure.unexpectedValue("read-type") }
        return data
    }

    private static func readQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ], bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier)
    }

    private static func enumeratedAccounts(
        service: String
    ) throws -> [String] {
        var query = GalaxyKeychainPolicy.searchQuery([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ], bundleIdentifier: GalaxyKeychainPolicy.internalBundleIdentifier)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try requireSuccess(status)
        return (result as? [[String: Any]] ?? []).compactMap {
            $0[kSecAttrAccount as String] as? String
        }.sorted()
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ProbeFailure.keychain(status) }
    }
}
