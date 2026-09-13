import Foundation

struct PendingCompanionFileManifest: Equatable, Sendable {
    let transferID: String
    let deviceID: String
    let relativeName: String
    let size: UInt64
    let mimeType: String
    let sha256: Data
}

struct CompanionFileTransferAcknowledgement: Equatable, Sendable {
    let sourceDeviceID: String
    let transferID: String
    let confirmedOffset: UInt64
    let complete: Bool
    let failureReason: String
}

enum CompanionFileTransferInstruction: Equatable, Sendable {
    case sendChunk(offset: UInt64, maximumLength: Int)
    case complete
    case fail(String)
}

struct CompanionFileTransferResumeCoordinator: Sendable {
    private static let chunkSize = 1 * 1_024 * 1_024
    private var manifestsByTransferID: [String: PendingCompanionFileManifest] = [:]

    mutating func register(_ manifest: PendingCompanionFileManifest) {
        manifestsByTransferID[manifest.transferID] = manifest
    }

    mutating func remove(transferID: String) {
        manifestsByTransferID.removeValue(forKey: transferID)
    }

    func manifest(transferID: String) -> PendingCompanionFileManifest? {
        manifestsByTransferID[transferID]
    }

    func manifestsForConnectedFilesChannel(deviceID: String) -> [PendingCompanionFileManifest] {
        manifestsByTransferID.values
            .filter { $0.deviceID == deviceID }
            .sorted { $0.transferID < $1.transferID }
    }

    func instruction(
        for acknowledgement: CompanionFileTransferAcknowledgement
    ) -> CompanionFileTransferInstruction? {
        guard let manifest = manifestsByTransferID[acknowledgement.transferID],
              acknowledgement.sourceDeviceID == manifest.deviceID else { return nil }
        if !acknowledgement.failureReason.isEmpty {
            return .fail(acknowledgement.failureReason)
        }
        if acknowledgement.complete {
            return acknowledgement.confirmedOffset == manifest.size ? .complete : .fail("invalid_completion_offset")
        }
        guard acknowledgement.confirmedOffset <= manifest.size else {
            return .fail("invalid_confirmed_offset")
        }
        return .sendChunk(
            offset: acknowledgement.confirmedOffset,
            maximumLength: Self.chunkSize
        )
    }
}
