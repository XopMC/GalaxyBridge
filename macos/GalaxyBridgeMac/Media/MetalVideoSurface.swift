import CoreImage
import CoreMedia
import CoreVideo
import GalaxyBridgeCore
import MetalKit
import SwiftUI

@MainActor
final class VideoSurfaceModel: ObservableObject {
    fileprivate let presenters = VideoSurfacePresenterRegistry()
    @Published private(set) var hasFrame = false
    @Published private(set) var protectedContentSuspected = false
    private var protectedContentHeuristic = ProtectedContentHeuristic()
    private var publicationState = VideoSurfacePublicationState()
    /// Called only at new frame admission. The producer captures its current
    /// verification attempt here; old cached redraws never ask for a new token.
    var freshFramePresentationReceipt: (@MainActor () -> (@MainActor @Sendable () -> Void)?)?

    // Camera retirement only; screen/window owners do not call this hook.
    func clearCameraFrame() {
        presenters.clear()
        hasFrame = false
        protectedContentSuspected = false
        protectedContentHeuristic = ProtectedContentHeuristic()
        publicationState = VideoSurfacePublicationState()
    }

    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32, diagnosticTrace: PrimaryMediaTrace? = nil) {
        if let trace = diagnosticTrace { trace.collector.mark(.surface, trace: trace) }
        let seconds = presentationTime.isValid && presentationTime.isNumeric
            ? presentationTime.seconds
            : .nan
        let protectedContent = protectedContentHeuristic.observe(
            uniformlyBlack: ProtectedContentPixelDetector.isUniformlyBlack(pixelBuffer),
            presentationTime: seconds,
            epoch: epoch
        )
        let update = publicationState.consume(
            protectedContentSuspected: protectedContent
        )
        if let nextHasFrame = update.hasFrame { hasFrame = nextHasFrame }
        if let nextProtectedContent = update.protectedContentSuspected {
            protectedContentSuspected = nextProtectedContent
        }
        let receipt = freshFramePresentationReceipt?()
        presenters.present(pixelBuffer, presentationTime: presentationTime, epoch: epoch,
                           diagnosticTrace: diagnosticTrace, presentationCompletion: receipt)
        if let trace = diagnosticTrace { trace.collector.finish(trace) }
    }
}

struct MetalVideoSurface: NSViewRepresentable {
    let model: VideoSurfaceModel

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else { return MTKView() }
        let view = MTKView(frame: .zero, device: device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.autoResizeDrawable = true
        view.focusRingType = .none
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        let renderer = MetalVideoRenderer(view: view, device: device)
        context.coordinator.renderer = renderer
        context.coordinator.model = model
        view.delegate = renderer
        model.presenters.attach(renderer)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if let renderer = context.coordinator.renderer {
            if context.coordinator.model !== model {
                context.coordinator.model?.presenters.detach(renderer)
                context.coordinator.model = model
            }
            model.presenters.attach(renderer)
        }
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        guard let model = coordinator.model, let renderer = coordinator.renderer else { return }
        model.presenters.detach(renderer)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var model: VideoSurfaceModel?
        var renderer: MetalVideoRenderer?
    }
}

final class MetalVideoRenderer: NSObject, MTKViewDelegate, VideoSurfacePresenting, @unchecked Sendable {
    private weak var view: MTKView?
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var frameEpoch: UInt32 = 0
    private var frameDiagnosticTrace: PrimaryMediaTrace?
    private var framePresentationReceipt: VideoFramePresentationReceipt?
    private var presentationBindingGeneration = UUID()
    private var renderedEpoch: UInt32 = 0
    private var invalidationState = VideoSurfaceRenderInvalidationState()

    init(view: MTKView, device: MTLDevice) {
        self.view = view
        commandQueue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init()
    }

    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32) {
        present(pixelBuffer, presentationTime: presentationTime, epoch: epoch, diagnosticTrace: nil)
    }

    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32, diagnosticTrace: PrimaryMediaTrace?) {
        present(pixelBuffer, presentationTime: presentationTime, epoch: epoch,
                diagnosticTrace: diagnosticTrace, presentationReceipt: nil)
    }

    func present(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, epoch: UInt32,
                 diagnosticTrace: PrimaryMediaTrace?, presentationReceipt: VideoFramePresentationReceipt?) {
        lock.lock()
        frame = pixelBuffer
        frameEpoch = epoch
        frameDiagnosticTrace = diagnosticTrace
        framePresentationReceipt = presentationReceipt
        let shouldRequestDraw = invalidationState.request()
        lock.unlock()
        guard shouldRequestDraw else { return }
        DispatchQueue.main.async { [weak self] in self?.view?.setNeedsDisplay(self?.view?.bounds ?? .zero) }
    }

    func draw(in view: MTKView) {
        lock.lock()
        invalidationState.didDraw()
        let pixelBuffer = frame
        let epoch = frameEpoch
        let diagnosticTrace = frameDiagnosticTrace
        let receipt = framePresentationReceipt
        let bindingGeneration = presentationBindingGeneration
        lock.unlock()
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        guard let pixelBuffer else {
            if let pass = view.currentRenderPassDescriptor {
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = view.clearColor
                commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
            return
        }

        if epoch != renderedEpoch {
            renderedEpoch = epoch
            context.clearCaches()
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let drawableSize = view.drawableSize
        guard let placement = VideoRenderGeometry.aspectFill(
            sourceSize: image.extent.size,
            destinationSize: drawableSize
        ) else { return }
        let transformed = image
            .transformed(
                by: CGAffineTransform(
                    translationX: -image.extent.minX,
                    y: -image.extent.minY
                )
            )
            .transformed(by: CGAffineTransform(scaleX: placement.scale, y: placement.scale))
            .transformed(
                by: CGAffineTransform(
                    translationX: placement.origin.x,
                    y: placement.origin.y
                )
            )
        context.render(
            transformed,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: drawableSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        if let diagnosticTrace {
            let measurement = PrimaryDrawableMeasurement(trace: diagnosticTrace, pixelBuffer: pixelBuffer)
            drawable.addPresentedHandler { completed in
                measurement.presented(at: completed.presentedTime)
            }
        }
        if let receipt {
            let proof = VideoDrawablePresentationProof { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.lock.withLock({ self.presentationBindingGeneration == bindingGeneration })
                    else { return }
                    receipt.confirmPresented()
                }
            }
            drawable.addPresentedHandler { completed in proof.presented(at: completed.presentedTime) }
            commandBuffer.addCompletedHandler { completed in proof.completedGPU(succeeded: completed.status == .completed) }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // A cached frame may attach before SwiftUI gives the view its first
        // nonzero drawable. Resize must redraw it without another video packet.
        view.setNeedsDisplay(view.bounds)
    }

    func clear() {
        lock.withLock {
            frame = nil; frameDiagnosticTrace = nil; framePresentationReceipt = nil
            presentationBindingGeneration = UUID()
        }
        context.clearCaches()
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }

    func invalidatePresentationReceipts() {
        lock.withLock { framePresentationReceipt = nil; presentationBindingGeneration = UUID() }
    }
}
