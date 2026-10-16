import Foundation

@main
struct DownloadsFolderAccessSpec {
    static func main() throws {
        let expected = URL(fileURLWithPath: "/tmp/galaxybridge-download-access", isDirectory: true)
        let suite = "galaxybridge.download-access." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var starts = 0, stops = 0, failBookmark = false
        var resolved = expected
        let operations = DownloadsFolderAccess.Operations(
            bookmark: { _ in
                if failBookmark { throw CocoaError(.fileWriteUnknown) }
                return Data([1, 2, 3])
            },
            resolve: { _ in resolved },
            start: { _ in starts += 1; return true },
            stop: { _ in stops += 1 }
        )
        var access: DownloadsFolderAccess? = DownloadsFolderAccess(
            downloads: expected, defaults: defaults, operations: operations
        )
        do {
            try access!.grant(URL(fileURLWithPath: "/tmp/another-folder"))
            fatalError("An unrelated directory was accepted")
        } catch {}
        precondition(starts == 0 && defaults.data(forKey: DownloadsFolderAccess.bookmarkKey) == nil)
        try access!.grant(expected)
        precondition(starts == 1 && stops == 0)
        precondition(defaults.data(forKey: DownloadsFolderAccess.bookmarkKey) == Data([1, 2, 3]))
        failBookmark = true
        do { try access!.grant(expected); fatalError("Failed persistence was accepted") } catch {}
        precondition(starts == 2 && stops == 1, "Only the failed new scope should be released")
        access = nil
        precondition(stops == 2, "The retained successful scope should be released once")
        failBookmark = false
        access = DownloadsFolderAccess(downloads: expected, defaults: defaults, operations: operations)
        precondition(starts == 3, "Saved selection was not restored")
        access = nil
        precondition(stops == 3)
        resolved = URL(fileURLWithPath: "/tmp/wrong-restored-folder")
        access = DownloadsFolderAccess(downloads: expected, defaults: defaults, operations: operations)
        precondition(starts == 3, "A bookmark resolving outside Downloads acquired access")
        access = nil
        print("PASS Downloads access: restricted selection, retained scope, restart restore, failed-save cleanup, invalid bookmark isolation")
    }
}
