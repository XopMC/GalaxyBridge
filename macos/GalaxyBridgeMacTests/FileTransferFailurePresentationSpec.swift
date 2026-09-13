import Foundation

@main
enum FileTransferFailurePresentationSpec {
    static func main() {
        precondition(FileTransferFailurePresentation.message(reason: "destination_exists")
            == String(localized: "FILE_DESTINATION_EXISTS"))
        precondition(FileTransferFailurePresentation.message(reason: "storage_folder_unavailable")
            == String(localized: "FILE_STORAGE_UNAVAILABLE"))
        precondition(FileTransferFailurePresentation.message(reason: "sha256_mismatch")
            == String(localized: "FILE_CONTENT_MISMATCH"))
        precondition(FileTransferFailurePresentation.message(reason: "provider_no_resumable_write")
            == String(localized: "FILE_RESUME_UNSUPPORTED"))
        let privateDetail = "unknown: /private/example/secret-name.png"
        let message = FileTransferFailurePresentation.message(reason: privateDetail)
        precondition(message == String(localized: "FILE_TRANSFER_FAILED"))
        precondition(!message.contains("secret-name"))
        print("PASS file collision, storage, integrity and unsupported resume have distinct recovery guidance")
    }
}
