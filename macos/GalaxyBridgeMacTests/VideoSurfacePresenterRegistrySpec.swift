import CoreMedia
import CoreVideo
import Foundation
import Metal

@MainActor
private final class RecordingPresenter: VideoSurfacePresenting {
    private(set) var presentations = 0
    private(set) var clears = 0
    private(set) var receipt: VideoFramePresentationReceipt?
    private(set) var invalidations = 0

    func clear() { clears += 1 }

    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32) {
        presentations += 1
        receipt = nil
    }
    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32,
                 diagnosticTrace: PrimaryMediaTrace?, presentationReceipt: VideoFramePresentationReceipt?) {
        presentations += 1
        receipt = presentationReceipt
    }
    func invalidatePresentationReceipts() { receipt = nil; invalidations += 1 }
}

private final class CompletionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@main
struct VideoSurfacePresenterRegistrySpec {
    @MainActor
    static func main() {
        var pixelBuffer: CVPixelBuffer?
        precondition(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                nil,
                &pixelBuffer
            ) == kCVReturnSuccess
        )
        guard let pixelBuffer else { fatalError("pixel buffer") }

        let registry = VideoSurfacePresenterRegistry()
        let mainWindow = RecordingPresenter()
        let detachedWindow = RecordingPresenter()
        registry.attach(mainWindow)
        registry.attach(detachedWindow)
        registry.present(pixelBuffer, presentationTime: .zero, epoch: 7)

        precondition(mainWindow.presentations == 1, "main window must receive the frame")
        precondition(detachedWindow.presentations == 1, "detached window must receive the same frame")

        registry.detach(mainWindow)
        registry.present(pixelBuffer, presentationTime: .zero, epoch: 7)
        precondition(mainWindow.presentations == 1, "detached presenter must stop receiving frames")
        precondition(detachedWindow.presentations == 2, "remaining presenter must stay live")

        let lateWindow = RecordingPresenter()
        registry.attach(lateWindow)
        precondition(lateWindow.presentations == 1, "opening a window on an idle stream must immediately show the latest frame")
        registry.attach(lateWindow)
        precondition(lateWindow.presentations == 1, "SwiftUI updates must not replay the same frame on every attach")

        registry.clear()
        precondition(detachedWindow.clears == 1 && lateWindow.clears == 1, "retirement must clear every attached camera presenter")
        let afterRetirement = RecordingPresenter()
        registry.attach(afterRetirement)
        precondition(afterRetirement.presentations == 0, "a newly attached camera presenter must not replay retired cached pixels")

        var delivered = 0
        registry.present(pixelBuffer, presentationTime: .zero, epoch: 8,
                         presentationCompletion: { delivered += 1 })
        precondition(delivered == 0, "decode/frame admission cannot verify physical presentation")
        let captured = detachedWindow.receipt!
        let cachedWindow = RecordingPresenter()
        registry.attach(cachedWindow)
        precondition(cachedWindow.receipt == nil, "cached replay acquired a fresh verification receipt")
        detachedWindow.receipt?.confirmPresented()
        lateWindow.receipt?.confirmPresented()
        captured.confirmPresented()
        precondition(delivered == 1, "multicast/repeated redraw must deliver one receipt only")
        registry.present(pixelBuffer, presentationTime: .zero, epoch: 9,
                         presentationCompletion: { delivered += 1 })
        let retired = detachedWindow.receipt!
        registry.clear()
        retired.confirmPresented()
        precondition(delivered == 1, "clear allowed stale in-flight frame evidence")
        registry.detach(detachedWindow)
        precondition(detachedWindow.receipt == nil && detachedWindow.invalidations == 1,
                     "detaching a presenter must invalidate its pending draw receipts")

        for presentedFirst in [true, false] {
            let completion = CompletionCount()
            let proof = VideoDrawablePresentationProof { completion.increment() }
            if presentedFirst { proof.presented(at: 1) } else { proof.completedGPU(succeeded: true) }
            precondition(completion.count == 0, "one Metal callback alone is insufficient")
            if presentedFirst { proof.completedGPU(succeeded: true) } else { proof.presented(at: 1) }
            proof.completedGPU(succeeded: true)
            proof.presented(at: 2)
            precondition(completion.count == 1, "callback order/duplicates changed proof")
        }
        for time in [0.0, -.infinity, .nan] {
            let completion = CompletionCount()
            let proof = VideoDrawablePresentationProof { completion.increment() }
            proof.completedGPU(succeeded: true)
            proof.presented(at: time)
            proof.presented(at: 1)
            precondition(completion.count == 0, "invalid or failed presentation became success")
        }
        let failedCompletion = CompletionCount()
        let failed = VideoDrawablePresentationProof { failedCompletion.increment() }
        failed.presented(at: 1)
        failed.completedGPU(succeeded: false)
        failed.completedGPU(succeeded: true)
        precondition(failedCompletion.count == 0, "failed GPU completion became evidence")

        // Native GPU completion with a controlled presentation signal exercises
        // the same production gate. It does not claim an on-screen drawable.
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let buffer = queue.makeCommandBuffer() else { fatalError("native Metal fixture unavailable") }
        let nativeCompletion = CompletionCount(), settled = DispatchSemaphore(value: 0)
        let nativeProof = VideoDrawablePresentationProof { nativeCompletion.increment() }
        nativeProof.presented(at: 1)
        buffer.addCompletedHandler { result in
            nativeProof.completedGPU(succeeded: result.status == .completed)
            settled.signal()
        }
        buffer.commit()
        precondition(settled.wait(timeout: .now() + 5) == .success)
        precondition(nativeCompletion.count == 1, "native successful GPU result failed the production gate")

        print("PASS multicast, no cached evidence, generation retirement, once-only fresh receipts, callback-order/failure gating, and native Metal completion. Controlled presentation signal; visible drawable QA remains separate.")
    }
}
