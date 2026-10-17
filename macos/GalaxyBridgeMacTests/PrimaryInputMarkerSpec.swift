import Foundation

private let markerZero: [UInt8] = [0x47, 0x42, 0x4d, 0x31, 0x10, 0x20, 0x30, 0x40, 0x00, 0x00, 0x74, 0x4b]
private let markerOne: [UInt8] = [0x47, 0x42, 0x4d, 0x31, 0x10, 0x20, 0x30, 0x40, 0x00, 0x01, 0x64, 0x6a]
private let markerTwo: [UInt8] = [0x47, 0x42, 0x4d, 0x31, 0x10, 0x20, 0x30, 0x40, 0x00, 0x02, 0x54, 0x09]
private let markerSeven: [UInt8] = [0x47, 0x42, 0x4d, 0x31, 0x10, 0x20, 0x30, 0x40, 0x00, 0x07, 0x04, 0xac]
private let markerOtherNonce: [UInt8] = [0x47, 0x42, 0x4d, 0x31, 0x50, 0x60, 0x70, 0x80, 0x00, 0x01, 0x57, 0x79]

// GBM1: 32-bit nonce, 16-bit counter, CRC-16/CCITT-FALSE. The independent
// golden bytes use nonce 0x10203040. Six rows of 16 cells align to the existing
// 24x24 diagnostic sample grid (rows17...22, columns4...19).
private func fixture(_ bytes: [UInt8], background: UInt8) -> PrimaryFrameSignature {
    precondition(bytes.count == 12)
    var luma = Array(repeating: background, count: 576)
    for bit in 0..<96 {
        let set = bytes[bit / 8] & (1 << (7 - bit % 8)) != 0
        luma[(17 + bit / 16) * 24 + 4 + bit % 16] = set ? 235 : 16
    }
    return PrimaryFrameSignature(luma: luma)
}

private func meter() -> PrimaryMediaDiagnostics {
    PrimaryMediaDiagnostics.logging(generation: 77, bundleID: "com.xopmc.GalaxyBridge.internal", startedAt: 0)
}
@discardableResult private func frame(_ meter: PrimaryMediaDiagnostics, _ bytes: [UInt8], at time: Double,
                                    background: UInt8 = 20, presentedAt: Double? = nil) -> PrimaryMediaTrace {
    let trace = meter.received(stream: .video, bytes: 1, pts: UInt64(time * 1_000_000), epoch: 1, now: time)!
    meter.drawablePresented(trace: trace, submittedAt: time, presentedAt: presentedAt ?? time + 0.01,
                            signature: fixture(bytes, background: background))
    return trace
}
@discardableResult private func input(_ meter: PrimaryMediaDiagnostics, at time: Double) -> PrimaryMediaTrace {
    let trace = meter.received(stream: .control, bytes: 1, pts: nil, epoch: nil, now: time)!
    meter.inputDispatched(trace: trace, at: time, epochMS: time * 1_000)
    return trace
}
@main enum PrimaryInputMarkerSpec {
    static func main() {
        precondition(PrimaryFrameSignature.side == 24, "GBM1 raster requires the documented24x24 sample lattice")
        if CommandLine.arguments.contains("--expect-marker-disabled") {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerZero, at: 2.05, background: 90)
            precondition(m.snapshot(now: 3).inputFrameSamples.count == 1,
                "Ordinary diagnostics must preserve their existing approximate matching")
            print("PASS marker disabled: existing diagnostics unchanged"); return
        }
        if CommandLine.arguments.contains("--expect-marker-invalid") {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerOne, at: 2.05, background: 90)
            precondition(m.snapshot(now: 3).inputFrameSamples.isEmpty,
                "Malformed or duplicate marker configuration must fail closed")
            print("PASS malformed marker configuration: no qualified sample"); return
        }
        do {
            let valid = fixture(markerOne, background: 90)
            precondition(PrimaryInputMarker.decode(valid, nonce: 0x10203040)?.counter == 1)
            for bit in 0..<96 {
                var corrupted = valid.luma
                let index = (17 + bit / 16) * 24 + 4 + bit % 16
                corrupted[index] = corrupted[index] < 128 ? 235 : 16
                precondition(PrimaryInputMarker.decode(PrimaryFrameSignature(luma: corrupted), nonce: 0x10203040) == nil,
                    "Every single-bit payload/magic/nonce/CRC corruption must be rejected")
            }
            precondition(PrimaryInputMarker.decode(PrimaryFrameSignature(luma: Array(repeating: 128, count: 144)), nonce: 0x10203040) == nil)
            var down = Data([2, 0] + Array(repeating: UInt8(255), count: 7) + [254] + Array(repeating: UInt8(0), count: 22))
            precondition(PrimaryInputMarker.isClickStart(down))
            precondition(PrimaryInputMarker.isClickStart((Data([0]) + down).dropFirst()))
            down[1] = 2; precondition(!PrimaryInputMarker.isClickStart(down))
            down[1] = 0; down[9] = 253; precondition(!PrimaryInputMarker.isClickStart(down))
            precondition(!PrimaryInputMarker.isClickStart(Data([2, 0])))
            print("PASS independent golden packet, all96 corruptions, dimensions and real control kind")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerZero, at: 2.05, background: 90)
            precondition(m.snapshot(now: 2.1).inputFrameSamples.isEmpty,
                "A background/refinement change with an unchanged input marker must not prove the click")
            let response = frame(m, markerOne, at: 2.2, background: 90)
            let summary = m.snapshot(now: 2.3)
            precondition(summary.inputFrameSamples.count == 1 && summary.inputFrameSamples[0].frameSequence == response.sequence)
            precondition(summary.logLines.joined().contains("matching:marker-v1"), "A semantic proof must be distinguishable from a heuristic")
            precondition(!summary.logLines.joined().contains("270544960"), "Do not log the marker nonce")
            print("PASS unchanged picture rejected, first exact marker response matched")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerOtherNonce, at: 2.03, background: 80)
            var corrupt = markerOne; corrupt[11] ^= 1
            frame(m, corrupt, at: 2.05, background: 100)
            let response = frame(m, markerOne, at: 2.2, background: 120)
            let samples = m.snapshot(now: 3).inputFrameSamples
            precondition(samples.count == 1 && samples[0].frameSequence == response.sequence,
                "Wrong nonce and corrupt CRC must not consume an input probe")
            print("PASS independent nonce and CRC rejection")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerSeven, at: 2.1); frame(m, markerOne, at: 2.2, background: 90)
            precondition(m.snapshot(now: 3).inputFrameSamples.isEmpty,
                "An unowned counter jump must invalidate the trial, not resynchronize it")
            print("PASS unowned marker counter invalidates the generation")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerOne, at: 1.99, presentedAt: 2.02)
            frame(m, markerOne, at: 2.05, background: 90)
            precondition(m.snapshot(now: 3).inputFrameSamples.isEmpty,
                "A marker received before dispatch cannot become proof via a later repeat")
            print("PASS pre-input frame cannot become a repeated semantic proof")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            let latest = input(m, at: 2.01); frame(m, markerTwo, at: 2.05)
            let samples = m.snapshot(now: 3).inputFrameSamples
            precondition(samples.count == 1 && samples[0].inputSequence == latest.sequence,
                "A coalesced visual update proves only its exact latest input")
            print("PASS coalesced fixture updates map to their exact input")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); let failed = input(m, at: 2)
            m.cancelInputProbe(trace: failed); frame(m, markerOne, at: 2.1)
            input(m, at: 3); frame(m, markerTwo, at: 3.1)
            precondition(m.snapshot(now: 4).inputFrameSamples.isEmpty,
                "An uncertain control failure invalidates semantic matching for this generation")
            print("PASS failed input cannot silently shift the marker ordinal")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1)
            let move = m.received(stream: .control, bytes: 1, pts: nil, epoch: nil, now: 2)!
            m.inputDispatched(trace: move, at: 2, markerGestureStart: false)
            frame(m, markerZero, at: 2.05, background: 90)
            let click = input(m, at: 3); frame(m, markerOne, at: 3.1)
            let samples = m.snapshot(now: 4).inputFrameSamples
            precondition(samples.count == 1 && samples[0].inputSequence == click.sequence,
                "MOVE cannot advance the click-only marker ordinal")
            print("PASS non-click controls do not shift click ordinals")
        }
        do {
            let m = meter(); input(m, at: 0.5)
            frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerOne, at: 2.1)
            precondition(m.snapshot(now: 3).inputFrameSamples.isEmpty,
                "A click sent before baseline must poison the generation, not disappear")
            print("PASS pre-baseline click cannot be forgotten")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); let failed = input(m, at: 2)
            frame(m, markerOne, at: 2.1); m.cancelInputProbe(trace: failed)
            precondition(m.snapshot(now: 3).logLines.joined().contains("input_marker_state=invalidated"),
                "Late failure after presentation must invalidate the trial receipt")
            input(m, at: 4); frame(m, markerTwo, at: 4.1)
            precondition(m.snapshot(now: 5).inputFrameSamples.count == 1,
                "No later qualified samples after an ambiguous late failure")
            print("PASS late failed control invalidates a consumed probe generation")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); let expired = input(m, at: 2)
            input(m, at: 100); m.cancelInputProbe(trace: expired)
            precondition(m.snapshot(now: 101).inputMarkerState == "invalidated",
                "Failure of an expired control still invalidates the generation")
            print("PASS expired control failure remains disqualifying")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerOne, at: 2.1)
            let up = m.received(stream: .control, bytes: 32, pts: nil, epoch: nil, now: 2.2)!
            m.inputDispatched(trace: up, at: 2.2, markerGestureStart: false)
            m.cancelInputProbe(trace: up)
            precondition(m.snapshot(now: 3).inputMarkerState == "invalidated",
                "A failed UP makes even a matched DOWN trial ambiguous")
            print("PASS failed UP invalidates the semantic trial")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); input(m, at: 2)
            frame(m, markerOne, at: 2.1); frame(m, markerZero, at: 2.2)
            precondition(m.snapshot(now: 3).inputMarkerState == "invalidated",
                "A newer source frame may not regress a validated counter")
            print("PASS valid counter regression invalidates the generation")
        }
        do {
            let m = meter(); frame(m, markerSeven, at: 1)
            precondition(m.snapshot(now: 2).logLines.joined().contains("input_marker_state=invalidated"),
                "A fresh semantic trial must begin at fixture counter zero, never adopt earlier input")
            print("PASS nonzero initial marker cannot anchor a new trial")
        }
        do {
            let m = meter(); frame(m, markerZero, at: 1); let owned = input(m, at: 2)
            let other = meter(); _ = other.received(stream: .audio, bytes: 1, pts: 1, epoch: 1, now: 1)
            let foreign = other.received(stream: .control, bytes: 1, pts: nil, epoch: nil, now: 2)!
            precondition(foreign.sequence == owned.sequence)
            m.cancelInputProbe(trace: foreign); frame(m, markerOne, at: 2.1)
            precondition(m.snapshot(now: 3).inputFrameSamples.count == 1,
                "A foreign collector cannot cancel or poison the current marker trial")
            print("PASS collector identity fence survives sequence collision")
        }

    }
}
