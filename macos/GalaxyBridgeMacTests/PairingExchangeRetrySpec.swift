import Foundation

enum SpecFailure: Error { case failed(String) }

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SpecFailure.failed(message) }
}

@main
enum PairingExchangeRetrySpec {
    static func main() throws {
        let request = Data([0x01])
        let commit = Data([0x03])
        let expiry = Date.distantFuture

        let responseDrop = PairingExchangeRetryState(requestFrame: request, expiresAt: expiry)
        try expect(responseDrop.outboundFrame(now: Date(timeIntervalSince1970: 0)) == request,
                   "initial pairing request must be sent")
        try expect(responseDrop.outboundFrame(now: Date(timeIntervalSince1970: 1)) == request,
                   "a dropped response must retry the identical request")

        var commitDrop = PairingExchangeRetryState(requestFrame: request, expiresAt: expiry)
        commitDrop.responseAccepted()
        try expect(commitDrop.outboundFrame(now: Date(timeIntervalSince1970: 1)) == nil,
                   "commit must not be sent before Mac peer persistence succeeds")
        commitDrop.peerSaved(commitFrame: commit)
        try expect(commitDrop.outboundFrame(now: Date(timeIntervalSince1970: 2)) == commit,
                   "saved peer must advance to commit")
        try expect(commitDrop.outboundFrame(now: Date(timeIntervalSince1970: 3)) == commit,
                   "a dropped commit or acknowledgement must retry the identical commit")

        commitDrop.acknowledged()
        try expect(commitDrop.isComplete, "only the final acknowledgement completes pairing")
        try expect(commitDrop.outboundFrame(now: Date(timeIntervalSince1970: 4)) == nil,
                   "completed pairing must stop retries")

        var immediateAck = PairingExchangeRetryState(requestFrame: request, expiresAt: expiry)
        immediateAck.responseAccepted()
        immediateAck.acknowledged()
        try expect(!immediateAck.isComplete,
                   "an acknowledgement arriving during durable peer save must wait for persistence")
        immediateAck.peerSaved(commitFrame: commit)
        try expect(immediateAck.isComplete,
                   "an acknowledgement arriving before peer save completes must be retained")
        try expect(immediateAck.outboundFrame(now: Date(timeIntervalSince1970: 4)) == nil,
                   "a retained acknowledgement must complete without an unnecessary retry")

        var saveFailure = PairingExchangeRetryState(requestFrame: request, expiresAt: expiry)
        saveFailure.responseAccepted()
        saveFailure.peerSaveFailed()
        try expect(saveFailure.isFailed, "Mac save failure must terminate the transaction")
        try expect(saveFailure.outboundFrame(now: Date(timeIntervalSince1970: 2)) == nil,
                   "Mac save failure must never emit a commit")

        let expired = PairingExchangeRetryState(requestFrame: request, expiresAt: expiry)
        try expect(expired.outboundFrame(now: expiry) == nil,
                   "retry must stop exactly at the one-time token expiry")

        var lateAcknowledgement = PairingExchangeRetryState(
            requestFrame: request,
            expiresAt: .distantPast
        )
        lateAcknowledgement.responseAccepted()
        lateAcknowledgement.peerSaved(commitFrame: commit)
        lateAcknowledgement.acknowledged()
        try expect(!lateAcknowledgement.isComplete,
                   "an acknowledgement received after token expiry must not complete pairing")
        try expect(lateAcknowledgement.isFailed,
                   "an acknowledgement received after token expiry must terminate the exchange")

        print("PASS two-phase pairing retries response/commit/ack loss and gates commit on Mac persistence")
    }
}
