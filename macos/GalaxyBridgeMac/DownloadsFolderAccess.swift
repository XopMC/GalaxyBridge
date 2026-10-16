import Foundation

/// Retains the user-selected Downloads URL and its implicit access scope.
/// Direct builds do not adopt App Sandbox; their ordinary bookmarks preserve
/// the selected URL without requesting sandbox-only bookmark entitlements.
final class DownloadsFolderAccess {
    static let bookmarkKey = "GBIncomingDownloadsSelection-v1"

    struct Operations {
        var bookmark: (URL) throws -> Data
        var resolve: (Data) throws -> URL
        var start: (URL) -> Bool
        var stop: (URL) -> Void

        static var system: Operations { Operations(
            bookmark: { try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) },
            resolve: {
                var stale = false
                return try URL(resolvingBookmarkData: $0, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
            },
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() }
        ) }
    }

    private let downloads: URL
    private let defaults: UserDefaults
    private let operations: Operations
    private var selectedURL: URL?
    private var scopeStarted = false

    /// Configuration only: the actual receive operation still checks filesystem access.
    var hasSelection: Bool { selectedURL != nil }

    init(
        downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
        defaults: UserDefaults = .standard,
        operations: Operations = .system
    ) {
        self.downloads = downloads.standardizedFileURL.resolvingSymlinksInPath()
        self.defaults = defaults
        self.operations = operations
        if let data = defaults.data(forKey: Self.bookmarkKey),
           let url = try? operations.resolve(data), accepts(url) {
            selectedURL = url
            scopeStarted = operations.start(url)
        }
    }

    deinit {
        if scopeStarted, let selectedURL { operations.stop(selectedURL) }
    }

    func grant(_ url: URL) throws {
        guard accepts(url) else { throw CocoaError(.fileReadNoPermission) }
        let acquired = operations.start(url)
        let data: Data
        do { data = try operations.bookmark(url) }
        catch {
            if acquired { operations.stop(url) }
            throw error
        }
        defaults.set(data, forKey: Self.bookmarkKey)
        if scopeStarted, let selectedURL { operations.stop(selectedURL) }
        selectedURL = url
        scopeStarted = acquired
    }

    private func accepts(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.resolvingSymlinksInPath().path == downloads.path
    }
}
