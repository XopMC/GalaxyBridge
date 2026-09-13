import Foundation

private final class SelectionOnlyKeychain: SecureRecordPersistenceBackend {
    func upsert(service: String, account: String, data: Data) throws { preconditionFailure("No real Keychain operations") }
    func read(service: String, account: String) throws -> Data? { preconditionFailure("No real Keychain operations") }
    func accounts(service: String) throws -> [String] { preconditionFailure("No real Keychain operations") }
    func delete(service: String, account: String) throws { preconditionFailure("No real Keychain operations") }
}

@main
enum InternalSecureRecordStoreSpec {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--read-direct" {
            let backend = directBackend(base: URL(fileURLWithPath: CommandLine.arguments[2]))
            let data = try backend.read(service: "synthetic-identity", account: "one")
            precondition(data == Data("direct-only".utf8), "Direct identity must survive a new process")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyBridgeInternalStoreSpec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        precondition(
            SecureRecordBackendFactory.kind(bundleIdentifier: "com.xopmc.GalaxyBridge.internal") == .localFile
        )
        precondition(
            SecureRecordBackendFactory.kind(bundleIdentifier: "com.xopmc.GalaxyBridge") == .dataProtectionKeychain
        )

        var backend: LocalSecureRecordPersistenceBackend? = .init(rootURL: root)
        try backend?.upsert(service: "service/with unsafe path", account: "account/../one", data: Data("first".utf8))
        try backend?.upsert(service: "service/with unsafe path", account: "second", data: Data("second".utf8))
        let firstRead = try backend?.read(service: "service/with unsafe path", account: "account/../one")
        let initialAccounts = try backend?.accounts(service: "service/with unsafe path")
        precondition(firstRead == Data("first".utf8))
        precondition(initialAccounts == ["account/../one", "second"])

        try assertMode(root, expected: 0o700)
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        precondition(files.count == 2)
        for file in files {
            precondition(!file.lastPathComponent.contains("account"), "Record names must not disclose account names")
            try assertMode(file, expected: 0o600)
        }

        backend = nil
        let reopened = LocalSecureRecordPersistenceBackend(rootURL: root)
        let reopenedRead = try reopened.read(service: "service/with unsafe path", account: "second")
        precondition(reopenedRead == Data("second".utf8))
        try reopened.delete(service: "service/with unsafe path", account: "account/../one")
        let remainingAccounts = try reopened.accounts(service: "service/with unsafe path")
        precondition(remainingAccounts == ["second"])
        try reopened.delete(service: "service/with unsafe path", account: "missing")

        try verifyDirectSelectionAndIsolation(base: root.appendingPathComponent("direct-fixture"))
        print("Internal secure record store persistence and permissions passed.")
    }

    private static func forbiddenKeychain() -> any SecureRecordPersistenceBackend {
        preconditionFailure("Direct/Internal must not instantiate or access Keychain")
    }

    private static func directBackend(base: URL, internalRoot: URL? = nil) -> any SecureRecordPersistenceBackend {
        SecureRecordBackendFactory.make(
            bundleIdentifier: SecureRecordBackendFactory.publicBundleIdentifier,
            distribution: "github-direct",
            internalRootURL: internalRoot,
            applicationSupportRootURL: base,
            keychainBackend: forbiddenKeychain()
        )
    }

    private static func verifyDirectSelectionAndIsolation(base: URL) throws {
        let publicID = SecureRecordBackendFactory.publicBundleIdentifier
        precondition(SecureRecordBackendFactory.kind(bundleIdentifier: publicID, distribution: "github-direct") == .localFile)
        for distribution in [nil, "developer-id", "app-store", "github-direct ", "GITHUB-DIRECT"] as [String?] {
            precondition(SecureRecordBackendFactory.kind(bundleIdentifier: publicID, distribution: distribution) == .dataProtectionKeychain)
            let sentinel = SelectionOnlyKeychain()
            let selected = SecureRecordBackendFactory.make(bundleIdentifier: publicID, distribution: distribution,
                internalRootURL: base, applicationSupportRootURL: base, keychainBackend: sentinel)
            precondition(selected === sentinel)
        }
        for identifier in [nil, "com.example.other", publicID + ".unknown"] as [String?] {
            precondition(SecureRecordBackendFactory.kind(bundleIdentifier: identifier, distribution: "github-direct") == .dataProtectionKeychain)
        }
        let overrideKey = "GALAXYBRIDGE_INTERNAL_RECORD_STORE_ROOT"
        let oldOverride = ProcessInfo.processInfo.environment[overrideKey]
        let internalURL = base.appendingPathComponent("internal-override")
        setenv(overrideKey, internalURL.path, 1)
        defer {
            if let oldOverride { setenv(overrideKey, oldOverride, 1) } else { unsetenv(overrideKey) }
        }
        let internalBackend = SecureRecordBackendFactory.make(
            bundleIdentifier: SecureRecordBackendFactory.internalBundleIdentifier,
            distribution: "github-direct", keychainBackend: forbiddenKeychain())
        try internalBackend.upsert(service: "synthetic-identity", account: "one", data: Data("internal-only".utf8))
        let direct = directBackend(base: base, internalRoot: internalURL)
        let initial = try direct.read(service: "synthetic-identity", account: "one")
        precondition(initial == nil, "Direct must not read or migrate Internal records")
        try direct.upsert(service: "synthetic-identity", account: "one", data: Data("direct-only".utf8))
        let untouchedInternal = try internalBackend.read(service: "synthetic-identity", account: "one")
        precondition(untouchedInternal == Data("internal-only".utf8))
        let directURL = SecureRecordBackendFactory.defaultDirectRootURL(applicationSupportRootURL: base)
        precondition(directURL == base.appendingPathComponent("GalaxyBridge/DirectSecureRecords-v1"))
        precondition(directURL != SecureRecordBackendFactory.defaultInternalRootURL())
        try assertMode(directURL, expected: 0o700)
        let records = try FileManager.default.contentsOfDirectory(at: directURL, includingPropertiesForKeys: nil)
        precondition(records.count == 1)
        try assertMode(records[0], expected: 0o600)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--read-direct", base.path]
        try child.run(); child.waitUntilExit()
        precondition(child.terminationReason == .exit && child.terminationStatus == 0)

        // A local runtime failure remains an error, never a Keychain retry or alternate store.
        let invalidBase = base.appendingPathComponent("regular-file-not-a-directory")
        try Data("fixture".utf8).write(to: invalidBase)
        do {
            try directBackend(base: invalidBase).upsert(service: "synthetic", account: "one", data: Data())
            preconditionFailure("An invalid Direct root must fail")
        } catch { }
        print("Direct explicit marker selection, isolated restart persistence, 0700/0600, Internal override exclusion and no runtime fallback passed.")
    }

    private static func assertMode(_ url: URL, expected: mode_t) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        precondition(mode == UInt16(expected), "Unexpected mode \(String(mode, radix: 8)) for \(url.path)")
    }
}
