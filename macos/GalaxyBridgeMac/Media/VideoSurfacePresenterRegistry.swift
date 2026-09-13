import CoreMedia
import CoreVideo
import Foundation

/// The two independent Metal callbacks can arrive in either order. A drawable
/// timestamp without successful GPU completion is not proof of a shown frame.
final class VideoDrawablePresentationProof: @unchecked Sendable {
    private let lock = NSLock()
    private var gpuSucceeded = false
    private var wasPresented = false
    private var completion: (@Sendable () -> Void)?
    init(completion: @escaping @Sendable () -> Void) { self.completion = completion }
    func completedGPU(succeeded: Bool) { update(success: succeeded, presentation: false) }
    func presented(at time: TimeInterval) { update(success: time.isFinite && time > 0, presentation: true) }
    private func update(success: Bool, presentation: Bool) {
        lock.lock()
        guard success else { completion = nil; lock.unlock(); return }
        if presentation { wasPresented = true } else { gpuSucceeded = true }
        let action = gpuSucceeded && wasPresented ? completion : nil
        if action != nil { completion = nil }
        lock.unlock()
        action?()
    }
}

@MainActor private final class VideoSurfacePresentationGeneration {}

/// Shared by all presenters of one fresh frame. Only one actual draw can claim
/// it, and clearing the registry invalidates every outstanding old-frame claim.
@MainActor final class VideoFramePresentationReceipt {
    private weak var generation: VideoSurfacePresentationGeneration?
    private var completion: (@MainActor @Sendable () -> Void)?
    fileprivate init(generation: VideoSurfacePresentationGeneration,
                     completion: @escaping @MainActor @Sendable () -> Void) {
        self.generation = generation
        self.completion = completion
    }
    func confirmPresented() {
        guard generation != nil, let completion else { return }
        self.completion = nil
        completion()
    }
}

@MainActor
protocol VideoSurfacePresenting: AnyObject {
    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32)
    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32, diagnosticTrace: PrimaryMediaTrace?)
    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32,
                 diagnosticTrace: PrimaryMediaTrace?, presentationReceipt: VideoFramePresentationReceipt?)
    func invalidatePresentationReceipts()
    func clear()
}

extension VideoSurfacePresenting {
    func clear() {}
    func invalidatePresentationReceipts() {}
    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32, diagnosticTrace: PrimaryMediaTrace?) {
        present(pixelBuffer, presentationTime: presentationTime, epoch: epoch)
    }
    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32,
                 diagnosticTrace: PrimaryMediaTrace?, presentationReceipt: VideoFramePresentationReceipt?) {
        present(pixelBuffer, presentationTime: presentationTime, epoch: epoch, diagnosticTrace: diagnosticTrace)
    }
}

/// Keeps every visible Metal surface subscribed to the shared device stream.
/// A device may be rendered in the main workspace and detached windows at the
/// same time, so a single weak renderer reference is not sufficient.
@MainActor
final class VideoSurfacePresenterRegistry {
    private struct WeakPresenter {
        weak var value: (any VideoSurfacePresenting)?
    }

    private var presenters: [ObjectIdentifier: WeakPresenter] = [:]
    private var latestFrame: (pixelBuffer: CVPixelBuffer, time: CMTime, epoch: UInt32, trace: PrimaryMediaTrace?)?
    private var presentationGeneration = VideoSurfacePresentationGeneration()

    func attach(_ presenter: any VideoSurfacePresenting) {
        pruneReleasedPresenters()
        let id = ObjectIdentifier(presenter)
        guard presenters[id]?.value == nil else { return }
        presenters[id] = WeakPresenter(value: presenter)
        if let latestFrame {
            presenter.present(latestFrame.pixelBuffer, presentationTime: latestFrame.time, epoch: latestFrame.epoch, diagnosticTrace: latestFrame.trace)
        }
    }

    func detach(_ presenter: any VideoSurfacePresenting) {
        presenters.removeValue(forKey: ObjectIdentifier(presenter))
        presenter.invalidatePresentationReceipts()
    }

    func clear() {
        presentationGeneration = VideoSurfacePresentationGeneration()
        latestFrame = nil
        pruneReleasedPresenters()
        for presenter in presenters.values.compactMap(\.value) { presenter.clear() }
    }

    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32,
                 diagnosticTrace: PrimaryMediaTrace? = nil,
                 presentationCompletion: (@MainActor @Sendable () -> Void)? = nil) {
        let receipt = presentationCompletion.map {
            VideoFramePresentationReceipt(generation: presentationGeneration, completion: $0)
        }
        // Cached replay intentionally retains no receipt. Starting a new test
        // and attaching a window cannot turn an old frame into fresh evidence.
        latestFrame = (pixelBuffer, presentationTime, epoch, diagnosticTrace)
        pruneReleasedPresenters()
        for presenter in presenters.values.compactMap(\.value) {
            presenter.present(pixelBuffer, presentationTime: presentationTime, epoch: epoch,
                              diagnosticTrace: diagnosticTrace, presentationReceipt: receipt)
        }
    }

    private func pruneReleasedPresenters() {
        presenters = presenters.filter { $0.value.value != nil }
    }
}
