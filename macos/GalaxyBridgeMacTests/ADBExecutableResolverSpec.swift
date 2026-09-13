import Foundation

private enum ResolverSpecFailure: Error, CustomStringConvertible {
    case mismatch(label: String, got: String?, expected: String?)

    var description: String {
        switch self {
        case let .mismatch(label, got, expected):
            return "\(label): got \(got ?? "nil"); expected \(expected ?? "nil")"
        }
    }
}

@main
private enum ADBExecutableResolverSpec {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("galaxybridge-adb-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundle = root.appendingPathComponent("GalaxyBridge.app", isDirectory: true)
        let bundledADB = bundle.appendingPathComponent("Contents/Resources/platform-tools/adb")
        let installedADB = root.appendingPathComponent("installed/platform-tools/adb")
        let secondaryADB = root.appendingPathComponent("homebrew/adb")
        try writeExecutable(at: bundledADB)
        try writeExecutable(at: installedADB)
        try writeExecutable(at: secondaryADB)

        let resolver = ADBExecutableResolver(fileManager: fileManager)
        try expect(
            resolver.resolve(
                distribution: ADBDistributionChannel(infoDictionaryValue: "github-direct"),
                bundleURL: bundle,
                installedCandidates: [installedADB, secondaryADB]
            ),
            bundledADB,
            "GitHub direct must use its bundled runtime even with an installed SDK"
        )
        try expect(
            resolver.resolve(
                distribution: .internalDevelopment,
                bundleURL: bundle,
                installedCandidates: [installedADB, secondaryADB]
            ),
            installedADB,
            "Internal must prefer the first installed adb"
        )
        try expect(
            resolver.resolve(
                distribution: .developerID,
                bundleURL: bundle,
                installedCandidates: [installedADB, secondaryADB]
            ),
            bundledADB,
            "Developer ID must prefer its bundled AOSP adb"
        )

        try fileManager.removeItem(at: bundledADB)
        try expect(
            resolver.resolve(
                distribution: ADBDistributionChannel(infoDictionaryValue: "github-direct"),
                bundleURL: bundle,
                installedCandidates: [installedADB, secondaryADB]
            ),
            nil,
            "GitHub direct must not hide a damaged bundle with the developer SDK"
        )
        try expect(
            resolver.resolve(
                distribution: .developerID,
                bundleURL: bundle,
                installedCandidates: [installedADB, secondaryADB]
            ),
            nil,
            "Developer ID must report a damaged bundle, never silently use developer tooling"
        )

        try fileManager.removeItem(at: installedADB)
        try expect(
            resolver.resolve(
                distribution: .internalDevelopment,
                bundleURL: bundle,
                installedCandidates: [installedADB, secondaryADB]
            ),
            secondaryADB,
            "Resolver must skip missing installed candidates"
        )

        try fileManager.removeItem(at: secondaryADB)
        let nonExecutable = root.appendingPathComponent("not-executable/adb")
        try fileManager.createDirectory(
            at: nonExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: nonExecutable)
        try expect(
            resolver.resolve(
                distribution: .internalDevelopment,
                bundleURL: bundle,
                installedCandidates: [nonExecutable]
            ),
            nil,
            "Resolver must reject non-executable files"
        )

        // This test executable is not inside an app and has no bundled adb.
        // The customer build must explain a damaged installation, not ask the
        // customer to install SDK tools which its resolver would never use.
        do {
            _ = try ADBClient(distribution: .developerID)
            throw ResolverSpecFailure.mismatch(label: "Missing bundled runtime", got: "success", expected: "error")
        } catch let error as ADBClientError {
            guard error.errorDescription == String(localized: "ADB_BUNDLED_RUNTIME_MISSING") else {
                throw ResolverSpecFailure.mismatch(
                    label: "Developer ID repair guidance", got: error.errorDescription,
                    expected: String(localized: "ADB_BUNDLED_RUNTIME_MISSING")
                )
            }
        }

        print("ADB executable resolver spec passed")
    }

    private static func expect(_ got: URL?, _ expected: URL?, _ label: String) throws {
        guard got?.standardizedFileURL == expected?.standardizedFileURL else {
            throw ResolverSpecFailure.mismatch(label: label, got: got?.path, expected: expected?.path)
        }
    }

    private static func writeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
