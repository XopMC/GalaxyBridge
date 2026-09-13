import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

final class GalaxyBridgeCameraProviderSource: NSObject, CMIOExtensionProviderSource {
    private let deviceSource = GalaxyBridgeCameraDeviceSource()

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func installDevice(on provider: CMIOExtensionProvider) throws {
        try provider.addDevice(deviceSource.device)
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { result.manufacturer = "GalaxyBridge" }
        return result
    }

    func setProviderProperties(_ properties: CMIOExtensionProviderProperties) throws {}
}

final class GalaxyBridgeCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private let streamSource: GalaxyBridgeCameraStreamSource

    override init() {
        streamSource = GalaxyBridgeCameraStreamSource()
        super.init()
        device = CMIOExtensionDevice(
            localizedName: "GalaxyBridge Camera",
            deviceID: UUID(uuidString: "7D47F304-E0D7-4B11-AB01-47414C415859")!,
            legacyDeviceID: "com.xopmc.GalaxyBridge.Camera",
            source: self
        )
        let stream = CMIOExtensionStream(
            localizedName: "GalaxyBridge Camera 1080p",
            streamID: UUID(uuidString: "7D47F304-E0D7-4B11-AB01-53545245414D")!,
            direction: .source,
            clockType: .hostTime,
            source: streamSource
        )
        streamSource.stream = stream
        try? device.addStream(stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceModel, .deviceTransportType, .deviceIsSuspended]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceModel) { result.model = "Samsung Galaxy via GalaxyBridge" }
        if properties.contains(.deviceTransportType) { result.transportType = 0 }
        if properties.contains(.deviceIsSuspended) { result.suspended = false }
        return result
    }

    func setDeviceProperties(_ properties: CMIOExtensionDeviceProperties) throws {}
}

final class GalaxyBridgeCameraStreamSource: NSObject, CMIOExtensionStreamSource {
    weak var stream: CMIOExtensionStream?
    private let reader = CameraRingReader()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.CameraExtension.frames")
    private lazy var formatDescription: CMVideoFormatDescription = {
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: 1_920,
            height: 1_080,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return description!
    }()

    lazy var formats: [CMIOExtensionStreamFormat] = [
        CMIOExtensionStreamFormat(
            formatDescription: formatDescription,
            maxFrameDuration: CMTime(value: 1, timescale: 30),
            minFrameDuration: CMTime(value: 1, timescale: 30),
            validFrameDurations: nil
        ),
    ]

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { result.frameDuration = CMTime(value: 1, timescale: 30) }
        return result
    }

    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.publishNextFrame() }
        self.timer = timer
        timer.resume()
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
    }

    private func publishNextFrame() {
        guard let stream,
              let frame = reader.latestSample(),
              let sample = makeSample(frame.pixelBuffer, hostTimeNanoseconds: frame.hostTimeNanoseconds)
        else { return }
        stream.send(
            sample,
            discontinuity: frame.sourceEpochChanged ? .time : [],
            hostTimeInNanoseconds: frame.hostTimeNanoseconds
        )
    }

    private func makeSample(
        _ pixelBuffer: CVPixelBuffer,
        hostTimeNanoseconds: UInt64
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(
                value: Int64(clamping: hostTimeNanoseconds),
                timescale: 1_000_000_000
            ),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return sample
    }
}
