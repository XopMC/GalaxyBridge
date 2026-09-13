import AppKit
import Foundation
import UniformTypeIdentifiers

enum RecordingDestinationPolicy {
    static var requiresUserSelection: Bool {
#if GALAXYBRIDGE_APP_STORE
        true
#else
        false
#endif
    }

    static func resolve(
        suggestedFilename: String,
        moviesDirectory: URL,
        selectUserURL: () -> URL?
    ) -> URL? {
        if requiresUserSelection {
            return selectUserURL()
        }
        return moviesDirectory.appendingPathComponent(suggestedFilename)
    }
}

@MainActor
struct SystemRecordingDestinationPicker {
    func chooseURL(suggestedFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "RECORDING_SAVE_TITLE")
        panel.nameFieldLabel = String(localized: "RECORDING_SAVE_NAME")
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
