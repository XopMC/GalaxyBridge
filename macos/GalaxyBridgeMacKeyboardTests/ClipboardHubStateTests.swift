import Foundation
import Testing
@testable import GalaxyBridgeMac

@Suite("Shared clipboard hub")
struct ClipboardHubStateTests {
    private let base = Date(timeIntervalSince1970: 1_000)

    @Test func macChangeFansOutToEveryConnectedGalaxyExactlyOnce() {
        let destinations = ClipboardHubState.destinations(
            allConnectedDeviceIDs: ["s24", "fold5", "s24"],
            excluding: nil
        )
        #expect(destinations == ["s24", "fold5"])
    }

    @Test func phoneChangeExcludesOnlyItsSourceAndKeepsOtherPhones() {
        let destinations = ClipboardHubState.destinations(
            allConnectedDeviceIDs: ["s24", "fold5", "tablet"],
            excluding: "fold5"
        )
        #expect(destinations == ["s24", "tablet"])
    }

    @Test func lastRealWriterGetsTheNewestGlobalRevision() {
        var hub = ClipboardHubState()
        let mac = hub.acceptMacChange()
        let firstPhone = hub.acceptRemote(
            sourceDeviceID: "s24",
            changeID: "s24:1",
            now: base
        )
        let secondPhone = hub.acceptRemote(
            sourceDeviceID: "fold5",
            changeID: "fold5:1",
            now: base
        )
        #expect(firstPhone == .accept(revision: mac + 1))
        #expect(secondPhone == .accept(revision: mac + 2))
    }

    @Test func explicitSameContentCopyRemainsANewLastWriter() {
        var hub = ClipboardHubState()

        #expect(
            hub.acceptRemote(
                sourceDeviceID: "fold5",
                changeID: "fold5:explicit-same-content",
                now: base.addingTimeInterval(0.1)
            ) == .accept(revision: 1)
        )
        #expect(
            hub.acceptRemote(
                sourceDeviceID: "s24",
                changeID: "s24:real",
                now: base.addingTimeInterval(0.2)
            ) == .accept(revision: 2)
        )
    }

    @Test func repeatedOccurrenceIdentityIsRejected() {
        var hub = ClipboardHubState()
        _ = hub.acceptRemote(
            sourceDeviceID: "s24",
            changeID: "stable-id",
            now: base
        )
        #expect(
            hub.acceptRemote(
                sourceDeviceID: "s24",
                changeID: "stable-id",
                now: base
            ) == .duplicate
        )
    }

    @Test func clipboardReconnectBackoffIsBounded() {
        #expect(ClipboardSessionReconnectPolicy.delay(afterFailure: 0) == 1)
        #expect(ClipboardSessionReconnectPolicy.delay(afterFailure: 1) == 2)
        #expect(ClipboardSessionReconnectPolicy.delay(afterFailure: 2) == 5)
        #expect(ClipboardSessionReconnectPolicy.delay(afterFailure: 3) == 10)
        #expect(ClipboardSessionReconnectPolicy.delay(afterFailure: 4) == 30)
        #expect(ClipboardSessionReconnectPolicy.delay(afterFailure: 100) == 30)
    }
}
