import Foundation

private final class RebuildForbiddenKeychainBackend: SecureRecordPersistenceBackend {
    init() { preconditionFailure("Internal rebuild probe constructed Keychain backend") }
    func upsert(service: String, account: String, data: Data) throws {}
    func read(service: String, account: String) throws -> Data? { nil }
    func accounts(service: String) throws -> [String] { [] }
    func delete(service: String, account: String) throws {}
}

@main
enum InternalStoreRebuildProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(64) }
#if GALAXYBRIDGE_REBUILD_ONE
        let generation = "one"
#else
        let generation = "two"
#endif
        FileHandle.standardError.write(Data("generation=\(generation)\n".utf8))

        let backend = SecureRecordBackendFactory.make(
            bundleIdentifier: SecureRecordBackendFactory.internalBundleIdentifier,
            internalRootURL: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
            keychainBackend: RebuildForbiddenKeychainBackend()
        )
        let fingerprint = try KeychainIdentityStore(
            backend: backend,
            service: "test.rebuild.identity"
        ).fingerprint()
        print(fingerprint.map { String(format: "%02x", $0) }.joined())
    }
}
