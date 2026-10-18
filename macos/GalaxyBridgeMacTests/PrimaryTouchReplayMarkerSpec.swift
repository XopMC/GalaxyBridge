import Foundation

@main enum PrimaryTouchReplayMarkerSpec {
    static func packet(action: UInt8, pressure: UInt16) -> Data {
        var data = Data([2, action] + Array(repeating: UInt8(255), count: 7) + [254] + Array(repeating: UInt8(0), count: 22))
        data[22] = UInt8(pressure >> 8); data[23] = UInt8(pressure & 255)
        return data
    }
    static func main() {
        let encodedMove = packet(action: 2, pressure: 0x8002)
        if CommandLine.arguments.contains("--expect-normal") {
            precondition(!PrimaryInputMarker.qualifiesForMarker(encodedMove))
            precondition(PrimaryInputMarker.qualifiesForMarker(packet(action: 0, pressure: 65535)))
            print("PASS ordinary build retains the existing click-only marker contract"); return
        }
        precondition(PrimaryInputMarker.qualifiesForMarker(encodedMove), "The dense probe must qualify its exact encoded MOVE, not just a click")
        precondition(PrimaryInputMarker.qualifiesForMarker(packet(action: 0, pressure: 0x8001)))
        precondition(!PrimaryInputMarker.qualifiesForMarker(packet(action: 1, pressure: 0)))
        precondition(!PrimaryInputMarker.qualifiesForMarker(packet(action: 2, pressure: 65535)))
        precondition(!PrimaryInputMarker.qualifiesForMarker(packet(action: 0, pressure: 65535)), "Normal user touches must not advance a QA pressure ordinal")
        precondition(!PrimaryInputMarker.qualifiesForMarker(packet(action: 2, pressure: 0x8000)))
        precondition(!PrimaryInputMarker.qualifiesForMarker(packet(action: 2, pressure: 0x8101)))
        var wrongPointer = encodedMove; wrongPointer[9] = 253
        precondition(!PrimaryInputMarker.qualifiesForMarker(wrongPointer))
        precondition(!PrimaryInputMarker.qualifiesForMarker(Data(encodedMove.prefix(31))))
#if GB_INPUT_REPLAY_QA
        let meter = PrimaryMediaDiagnostics(generation: 4, markerConfiguration: .enabled(0x10203040), sink: { _ in })
        func signature(_ bytes: [UInt8]) -> PrimaryFrameSignature {
            var luma = [UInt8](repeating: 90, count: 576)
            for bit in 0..<96 { luma[(17 + bit / 16) * 24 + 4 + bit % 16] = bytes[bit / 8] & (1 << (7 - bit % 8)) == 0 ? 16 : 235 }
            return PrimaryFrameSignature(luma: luma)
        }
        func frame(_ bytes: [UInt8], at time: Double) {
            let trace = meter.received(stream: .video, bytes: 1, pts: UInt64(time * 1_000_000), epoch: 1, now: time)!
            meter.drawablePresented(trace: trace, submittedAt: time, presentedAt: time + 0.01, signature: signature(bytes))
        }
        frame([0x47,0x42,0x4d,0x31,0x10,0x20,0x30,0x40,0,0,0x74,0x4b], at: 1)
        precondition(meter.touchReplayBaselineReady)
        let input = meter.received(stream: .control, bytes: 32, pts: nil, epoch: nil, now: 2)!
        meter.inputDispatched(trace: input, at: 2, dispatchedMarkerCounter: 7)
        frame([0x47,0x42,0x4d,0x31,0x10,0x20,0x30,0x40,0,7,0x04,0xac], at: 2.1)
        let summary = meter.snapshot(now: 3)
        precondition(summary.inputFrameSamples.count == 1 && summary.inputFrameSamples[0].inputSequence == input.sequence
            && summary.inputFrameSamples[0].markerCounter == 7, "A coalesced MOVE must map to its source wire counter, never a receive-callback count")
        precondition(summary.logLines.joined().contains("validated_pressure_touch_marker_v1"))
#endif
        print("PASS exact pressure-qualified DOWN/MOVE; unrelated touches, pointers, UP and malformed packets rejected")
    }
}
