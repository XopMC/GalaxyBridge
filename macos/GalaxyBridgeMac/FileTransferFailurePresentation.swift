import Foundation

enum FileTransferFailurePresentation {
    static func message(reason: String) -> String {
        switch reason {
        case "destination_exists":
            String(localized: "FILE_DESTINATION_EXISTS")
        case "storage_folder_unavailable", "transfer_document_missing":
            String(localized: "FILE_STORAGE_UNAVAILABLE")
        case "sha256_mismatch", "checkpoint_prefix_mismatch", "conflicting_duplicate":
            String(localized: "FILE_CONTENT_MISMATCH")
        case "provider_no_resumable_write":
            String(localized: "FILE_RESUME_UNSUPPORTED")
        default:
            String(localized: "FILE_TRANSFER_FAILED")
        }
    }
}
