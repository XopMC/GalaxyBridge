import Foundation
import GalaxyBridgeCore
import Testing
@testable import GalaxyBridgeMac

@MainActor
private final class KeyboardEmissionRecorder {
    private(set) var messages: [Data] = []

    func record(_ emission: ScrcpyKeyboardEmission) {
        messages.append(emission.controlMessage)
    }
}

@MainActor
@Suite
struct ScrcpyKeyboardOrderingTests {
    @Test
    func testVirtualDisplayTextIsEnqueuedBeforeImmediateReturnEdges() throws {
        let recorder = KeyboardEmissionRecorder()
        let session = try makeSession(serial: "ordering", recorder: recorder)
        let returnDown = Data([0, 0, 0, 0, 0, 66, 0, 0, 0, 0, 0, 0, 0, 0])
        let returnUp = Data([0, 1, 0, 0, 0, 66, 0, 0, 0, 0, 0, 0, 0, 0])

        session.sendVirtualDisplayText("A")
        session.sendKeyboardControl(returnDown)
        session.sendKeyboardControl(returnUp)

        #expect(
            recorder.messages ==
            [
                Data([1, 0, 0, 0, 1, 0x41]),
                returnDown,
                returnUp,
            ]
        )
    }

    @Test
    func deletePreservesRepeatCountAndModifiers() throws {
        let recorder = KeyboardEmissionRecorder()
        let session = try makeSession(serial: "delete", recorder: recorder)
        let deleteDown = Data([0, 0, 0, 0, 0, 67, 0, 0, 0, 3, 0, 0, 0x10, 0x01])
        let deleteUp = Data([0, 1, 0, 0, 0, 67, 0, 0, 0, 0, 0, 0, 0x10, 0x01])

        session.sendKeyboardControl(deleteDown)
        session.sendKeyboardControl(deleteUp)

        #expect(recorder.messages == [deleteDown, deleteUp])
    }

    @Test
    func virtualDisplayTextPreservesBoundedUTF8ChunkOrder() throws {
        let recorder = KeyboardEmissionRecorder()
        let session = try makeSession(serial: "chunks", recorder: recorder)

        session.sendVirtualDisplayText("")
        session.sendVirtualDisplayText(String(repeating: "Ж", count: 4_097))

        let payloads = try recorder.messages.map(directTextPayload)
        #expect(payloads.map(\.count) == Array(repeating: 300, count: 27) + [92])
        #expect(String(decoding: payloads.joined(), as: UTF8.self) == String(repeating: "Ж", count: 4_096))
    }

    @Test
    func interleavedSessionsKeepIndependentEmissionOrder() throws {
        let firstRecorder = KeyboardEmissionRecorder()
        let secondRecorder = KeyboardEmissionRecorder()
        let first = try makeSession(serial: "first", recorder: firstRecorder)
        let second = try makeSession(serial: "second", recorder: secondRecorder)
        let firstReturn = Data([0, 0, 0, 0, 0, 66, 0, 0, 0, 0, 0, 0, 0, 0])
        let secondDelete = Data([0, 0, 0, 0, 0, 67, 0, 0, 0, 2, 0, 0, 0, 1])

        first.sendVirtualDisplayText("A")
        second.sendVirtualDisplayText("Б")
        first.sendKeyboardControl(firstReturn)
        second.sendKeyboardControl(secondDelete)

        #expect(firstRecorder.messages == [Data([1, 0, 0, 0, 1, 0x41]), firstReturn])
        #expect(secondRecorder.messages == [Data([1, 0, 0, 0, 2, 0xD0, 0x91]), secondDelete])
    }

    @Test
    func clipboardAcknowledgementAndSettlementRemainRealQueueBarriers() async throws {
        let recorder = KeyboardEmissionRecorder()
        let session = try makeSession(serial: "clipboard", recorder: recorder)
        let sequence: UInt64 = 0x8000_0000_0000_0000
        let returnDown = Data([0, 0, 0, 0, 0, 66, 0, 0, 0, 0, 0, 0, 0, 0])
        let setClipboard = Data([
            9,
            0x80, 0, 0, 0, 0, 0, 0, 0,
            0,
            0, 0, 0, 2,
            0xD0, 0x91,
        ])
        let pasteDown = Data([13, 0, 1, 0, 8, 1, 0, 0x19, 0, 0, 0, 0, 0])
        let pasteUp = Data([13, 0, 1, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0])

        session.sendText("Б")
        session.sendVirtualDisplayText("A")
        session.sendKeyboardControl(returnDown)
        #expect(recorder.messages == [setClipboard])

        session.receiveKeyboardClipboardAcknowledgement(sequence)
        #expect(recorder.messages == [setClipboard, pasteDown, pasteUp])

        try await waitForMessageCount(5, recorder: recorder)
        #expect(
            recorder.messages == [
                setClipboard,
                pasteDown,
                pasteUp,
                Data([1, 0, 0, 0, 1, 0x41]),
                returnDown,
            ]
        )
    }

    @Test
    func keyboardCleanupDropsPendingOperationsAndStaleSettlement() async throws {
        let recorder = KeyboardEmissionRecorder()
        let session = try makeSession(serial: "cleanup", recorder: recorder)
        let sequence: UInt64 = 0x8000_0000_0000_0000
        let returnDown = Data([0, 0, 0, 0, 0, 66, 0, 0, 0, 0, 0, 0, 0, 0])

        session.sendText("Б")
        session.receiveKeyboardClipboardAcknowledgement(sequence)
        session.sendVirtualDisplayText("A")
        session.sendKeyboardControl(returnDown)
        #expect(recorder.messages.count == 3)

        session.resetKeyboardInput()
        try await Task.sleep(for: .milliseconds(350))

        #expect(recorder.messages.count == 3)
    }

    private func makeSession(
        serial: String,
        recorder: KeyboardEmissionRecorder
    ) throws -> ScrcpySession {
        try ScrcpySession(
            serial: serial,
            adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
            physicalDisplayPolicy: .leaveUnchanged,
            automaticDisplayManagement: false,
            keyboardEmissionSink: recorder.record
        )
    }

    private func directTextPayload(_ message: Data) throws -> Data {
        guard message.count >= 5, message[0] == 1 else {
            throw KeyboardSpecFailure.invalidDirectTextMessage(Array(message))
        }
        let length = Int(message[1]) << 24
            | Int(message[2]) << 16
            | Int(message[3]) << 8
            | Int(message[4])
        guard message.count == 5 + length else {
            throw KeyboardSpecFailure.invalidDirectTextMessage(Array(message))
        }
        return message.subdata(in: 5 ..< message.count)
    }

    private func waitForMessageCount(
        _ expectedCount: Int,
        recorder: KeyboardEmissionRecorder
    ) async throws {
        for _ in 0 ..< 100 {
            if recorder.messages.count == expectedCount { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw KeyboardSpecFailure.timedOut(
            expectedCount: expectedCount,
            actualCount: recorder.messages.count
        )
    }
}

private enum KeyboardSpecFailure: Error {
    case invalidDirectTextMessage([UInt8])
    case timedOut(expectedCount: Int, actualCount: Int)
}
