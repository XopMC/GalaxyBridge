import Foundation

struct PairingExchangeRetryState {
    private enum Stage {
        case waitingForResponse
        case waitingForPeerSave(acknowledgementReceived: Bool)
        case waitingForAcknowledgement(Data)
        case complete
        case failed
    }

    private let requestFrame: Data
    private let expiresAt: Date
    private var stage: Stage = .waitingForResponse

    init(requestFrame: Data, expiresAt: Date) {
        self.requestFrame = requestFrame
        self.expiresAt = expiresAt
    }

    var isComplete: Bool {
        if case .complete = stage { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = stage { return true }
        return false
    }

    mutating func responseAccepted() {
        guard case .waitingForResponse = stage else { return }
        stage = .waitingForPeerSave(acknowledgementReceived: false)
    }

    mutating func peerSaved(commitFrame: Data) {
        guard case let .waitingForPeerSave(acknowledgementReceived) = stage else { return }
        stage = acknowledgementReceived ? .complete : .waitingForAcknowledgement(commitFrame)
    }

    mutating func peerSaveFailed() {
        guard case .waitingForPeerSave = stage else { return }
        stage = .failed
    }

    mutating func acknowledged(now: Date = Date()) {
        guard !isComplete, !isFailed else { return }
        guard now < expiresAt else {
            stage = .failed
            return
        }
        switch stage {
        case .waitingForPeerSave:
            stage = .waitingForPeerSave(acknowledgementReceived: true)
        case .waitingForAcknowledgement:
            stage = .complete
        case .waitingForResponse, .complete, .failed:
            return
        }
    }

    func outboundFrame(now: Date) -> Data? {
        guard now < expiresAt else { return nil }
        switch stage {
        case .waitingForResponse:
            return requestFrame
        case let .waitingForAcknowledgement(commitFrame):
            return commitFrame
        case .waitingForPeerSave, .complete, .failed:
            return nil
        }
    }
}
