import Foundation

@main
enum CompanionFileTransferResumeSpec {
    static func main() throws {
        let manifest = PendingCompanionFileManifest(
            transferID: "transfer-resume-1",
            deviceID: "device:galaxy-s24",
            relativeName: "archive.bin",
            size: 5 * 1_024 * 1_024,
            mimeType: "application/octet-stream",
            sha256: Data(repeating: 0x5a, count: 32)
        )
        var coordinator = CompanionFileTransferResumeCoordinator()
        coordinator.register(manifest)

        guard coordinator.manifest(transferID: manifest.transferID) == manifest else {
            throw SpecFailure(message: "a newly queued transfer must use its registered manifest")
        }

        let confirmedOffset: UInt64 = 2 * 1_024 * 1_024
        let firstInstruction = coordinator.instruction(
            for: CompanionFileTransferAcknowledgement(
                sourceDeviceID: manifest.deviceID,
                transferID: manifest.transferID,
                confirmedOffset: confirmedOffset,
                complete: false,
                failureReason: ""
            )
        )
        guard firstInstruction == .sendChunk(offset: confirmedOffset, maximumLength: 1 * 1_024 * 1_024) else {
            throw SpecFailure(message: "ACK N must continue by sending the next chunk at exactly N")
        }

        let replayed = coordinator.manifestsForConnectedFilesChannel(deviceID: manifest.deviceID)
        guard replayed == [manifest] else {
            throw SpecFailure(
                message: "recreating the files channel must replay the same pending manifest before sending more bytes"
            )
        }

        let resumedInstruction = coordinator.instruction(
            for: CompanionFileTransferAcknowledgement(
                sourceDeviceID: manifest.deviceID,
                transferID: manifest.transferID,
                confirmedOffset: confirmedOffset,
                complete: false,
                failureReason: ""
            )
        )
        guard resumedInstruction == .sendChunk(offset: confirmedOffset, maximumLength: 1 * 1_024 * 1_024) else {
            throw SpecFailure(
                message: "the receiver's existing .part offset must resume from N after logical channel recreation"
            )
        }
        guard coordinator.manifest(transferID: manifest.transferID) == manifest else {
            throw SpecFailure(message: "logical channel recreation must not discard the pending transfer")
        }

        for offset: UInt64 in [0, manifest.size - 1, manifest.size + 1] {
            precondition(coordinator.instruction(for: .init(sourceDeviceID: manifest.deviceID,
                transferID: manifest.transferID, confirmedOffset: offset, complete: true, failureReason: "")) == .fail("invalid_completion_offset"))
        }
        precondition(coordinator.instruction(for: .init(sourceDeviceID: "device:other-phone",
            transferID: manifest.transferID, confirmedOffset: manifest.size, complete: true, failureReason: "")) == nil)
        precondition(coordinator.instruction(for: .init(sourceDeviceID: manifest.deviceID,
            transferID: manifest.transferID, confirmedOffset: manifest.size, complete: true, failureReason: "")) == .complete)

        coordinator.remove(transferID: manifest.transferID)
        guard coordinator.manifestsForConnectedFilesChannel(deviceID: manifest.deviceID).isEmpty else {
            throw SpecFailure(message: "a completed transfer must not be replayed on later files channels")
        }

        print("PASS files-channel recreation replays manifest and resumes from confirmed .part offset")
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
