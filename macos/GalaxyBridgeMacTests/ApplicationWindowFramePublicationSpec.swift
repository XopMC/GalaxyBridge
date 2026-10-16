import Combine
import CoreMedia
import CoreVideo
import Foundation

enum PresentationEvent { case firstDecodedFrame }
enum TraceReason { case dropped }
struct FrameTrace { let collector: TraceCollector }
struct TraceCollector { func finish(_ trace: FrameTrace, reason: TraceReason) {} }
struct NativeDecodedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime = .zero
    let epoch: UInt32 = 1
    let trace: FrameTrace? = nil
    var isAdmitted = true
}
@MainActor final class FrameSurfaceProbe {
    var presented = 0
    func present(_ buffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32, diagnosticTrace: FrameTrace?) {
        presented += 1
    }
}
@main enum ApplicationWindowFramePublicationSpec {
    @MainActor static func main() {
        let probe = ApplicationWindowFrameProbe()
        var ratios: [CGFloat] = []
        let subscription = probe.$aspectRatio.dropFirst().sink { ratios.append($0) }
        let portrait = frame(width: 18, height: 32)
        for _ in 0..<120 { probe.receive(portrait) }
        precondition(ratios == [9 / 16], "120 same-size frames must publish one aspect change; got \(ratios.count)")
        precondition(probe.surface.presented == 120, "Publication deduplication must retain every frame presentation")
        probe.receive(frame(width: 32, height: 18))
        precondition(ratios == [9 / 16, 16 / 9], "A real aspect change must publish exactly once")
        precondition(probe.surface.presented == 121 && probe.presentationEvents == 121)
        var obsolete = portrait; obsolete.isAdmitted = false
        probe.receive(obsolete)
        probe.closed = true; probe.receive(portrait)
        precondition(probe.surface.presented == 121 && ratios.count == 2, "Obsolete and closed frames must remain fenced")
        withExtendedLifetime(subscription) {}
        print("PASS actual application-window frame handler: 120 frames, two aspect changes, all presentations, lifetime fences")
    }
    static func frame(width: Int, height: Int) -> NativeDecodedFrame {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        return NativeDecodedFrame(pixelBuffer: buffer!)
    }
}
