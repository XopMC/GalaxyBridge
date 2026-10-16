import Foundation

private enum ClipboardHubSpecFailure: Error {
    case failed(String)
}

@main
private enum ClipboardHubStateSpec {
    static func main() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        var hub = ClipboardHubState()

        try require(
            ClipboardHubState.destinations(
                allConnectedDeviceIDs: ["s24", "fold5", "s24"],
                excluding: nil
            ) == ["s24", "fold5"],
            "Mac changes must fan out once to every connected Galaxy"
        )
        try require(
            ClipboardHubState.destinations(
                allConnectedDeviceIDs: ["s24", "fold5"],
                excluding: "s24"
            ) == ["fold5"],
            "a Galaxy change must reach every other Galaxy without echoing to its source"
        )

        let macRevision = hub.acceptMacChange()
        let phoneA = hub.acceptRemote(
            sourceDeviceID: "s24",
            changeID: "s24:1",
            now: base
        )
        let phoneB = hub.acceptRemote(
            sourceDeviceID: "fold5",
            changeID: "fold5:1",
            now: base
        )
        try require(phoneA == .accept(revision: macRevision + 1), "first phone must follow the Mac revision")
        try require(phoneB == .accept(revision: macRevision + 2), "last real writer must own the newest revision")

        try require(
            hub.acceptRemote(
                sourceDeviceID: "fold5",
                changeID: "fold5:explicit-same-content",
                now: base.addingTimeInterval(0.1)
            ) == .accept(revision: macRevision + 3),
            "a transport-confirmed explicit copy of identical content must remain a real last write"
        )
        try require(
            hub.acceptRemote(
                sourceDeviceID: "fold5",
                changeID: "fold5:explicit-same-content",
                now: base.addingTimeInterval(0.3)
            ) == .duplicate,
            "a repeated occurrence identity must be idempotent"
        )
        try require(
            [0, 1, 2, 3, 4, 100].map(ClipboardSessionReconnectPolicy.delay(afterFailure:))
                == [1, 2, 5, 10, 30, 30],
            "capture-free clipboard reconnect must use the bounded 1/2/5/10/30 second policy"
        )
        let epoch = ClipboardDeliveryEpoch(trustGeneration: UUID(), routeIDs: ["control:A", "clipboard:A"])
        let content = Data("same".utf8)
        hub.observeClipboard(deviceID: "A", epoch: epoch, kind: .text, content: content)
        try require(hub.needsDelivery(deviceID: "A", epoch: epoch, kind: .text, content: content), "Queued delivery without a current observer is not an ACK")
        hub.observeClipboard(deviceID: "A", epoch: epoch, kind: .text, content: content, confirmed: true)
        try require(!hub.needsDelivery(deviceID: "A", epoch: epoch, kind: .text, content: content), "Unchanged target needs no physical rewrite")
        try require(hub.needsDelivery(deviceID: "A", epoch: epoch, kind: .png, content: content), "Image/text payload families remain distinct")
        hub.forgetClipboard(deviceID: "A")
        try require(hub.needsDelivery(deviceID: "A", epoch: epoch, kind: .text, content: content), "Empty/sensitive/unreadable target or feature reset must invalidate the current value")
        print("PASS shared clipboard hub orders Mac and multi-Galaxy writes without loops")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ClipboardHubSpecFailure.failed(message) }
    }
}
