import CoreMedia
import CoreVideo
import Foundation
import GalaxyBridgeCore
import Testing
import VideoToolbox
@testable import GalaxyBridgeMac

extension PrimaryMediaDiagnosticsTests {
    @Test @MainActor func realParserSessionDecoderCarriesTraceToSurface() async throws {
        let sample = try PrimaryEncodedFixture.make()
        for enabled in [false, true] {
            let diagnostics = enabled ? PrimaryMediaDiagnostics(generation: 55, sink: { _ in }) : nil
            let session = try ScrcpySession(serial: "synthetic-never-started",
                adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
                physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false)
            let frames = PrimaryFrameResult()
            let surface = VideoSurfaceModel()
            session.diagnosticDecodedFrameHandler = { pixel, time, epoch, trace in
                let wrapped = PrimaryFixturePixel(pixel)
                Task { @MainActor in
                    frames.count += 1
                    frames.width = CVPixelBufferGetWidth(wrapped.value)
                    frames.trace = trace
                    if let trace { trace.collector.mark(.appModel, trace: trace) }
                    surface.present(wrapped.value, presentationTime: time, epoch: epoch, diagnosticTrace: trace)
                }
            }
            var parser = ScrcpyPrimaryStreamParser(kind: .video, initialPreambleLength: 0, diagnostics: diagnostics)
            try session.beginNativeAttempt()
            var wire = Data([0x68, 0x32, 0x36, 0x34, 0x80, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, 64])
            wire.append(packet(header: UInt64(1) << 62, payload: sample.configuration))
            wire.append(packet(header: (UInt64(1) << 61) | 1_000_000, payload: sample.frame))
            try parser.consume(wire.prefix(7)) { event, trace in
                ScrcpyPrimaryMediaDelivery.deliver(event, trace: trace) { event, trace in session.handleVideo(event, diagnosticTrace: trace) }
            }
            try parser.consume(wire.dropFirst(7)) { event, trace in
                ScrcpyPrimaryMediaDelivery.deliver(event, trace: trace) { event, trace in session.handleVideo(event, diagnosticTrace: trace) }
            }
            for _ in 0..<200 where frames.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(frames.count == 1 && frames.width == 64 && surface.hasFrame)
            #expect((frames.trace != nil) == enabled)
            if let diagnostics {
                let summary = diagnostics.snapshot(now: ProcessInfo.processInfo.systemUptime)
                #expect(summary.counters[.parsedPackets] == 2)
                #expect(summary.counters[.configuration] == 1)
                #expect(summary.histograms[.relativePTS]?.sampleCount == 0)
                #expect(summary.histograms[.submitToCallback]?.sampleCount == 1)
                #expect(summary.histograms[.callbackToDelivery]?.sampleCount == 1)
                #expect(summary.histograms[.appModelToSurface]?.sampleCount == 1)
                #expect(summary.pending.values.allSatisfy { $0 == 0 })
                #expect(summary.counters[.queueImbalance] == 0)
            }
            await session.stopAndWaitForCleanup()
            #expect(session.nativeRetirementOutcome?.succeeded == true)
        }
    }

    @Test func parserErrorsPreserveFailureAndLeaveNoQueuedWork() {
        let meter = PrimaryMediaDiagnostics(generation: 1, sink: { _ in })
        var parser = ScrcpyPrimaryStreamParser(kind: .video, initialPreambleLength: 1, diagnostics: meter)
        #expect(throws: (any Error).self) { try parser.consume(Data([1])) { _, _ in Issue.record("bad preamble must not emit") } }
        #expect(meter.snapshot(now: 1).pending.values.allSatisfy { $0 == 0 })
        var reverseParser = ScrcpyPrimaryStreamParser(
            kind: .video,
            initialPreambleLength: 64,
            expectsLeadingDummyByte: false,
            diagnostics: meter
        )
        #expect(throws: Never.self) {
            try reverseParser.consume(Data(repeating: 0x41, count: 64)) { _, _ in
                Issue.record("device-name-only reverse preamble must not emit")
            }
        }
        parser.recordFailure()
        #expect(meter.snapshot(now: 1).counters[.failed] == 1)
        var malformed = ScrcpyPrimaryStreamParser(kind: .video, initialPreambleLength: 0, diagnostics: meter)
        #expect(throws: (any Error).self) { try malformed.consume(Data([0, 0, 0, 0])) { _, _ in Issue.record("bad codec must not emit") } }
        #expect(meter.snapshot(now: 1).pending.values.allSatisfy { $0 == 0 })
    }
}

private func packet(header: UInt64, payload: Data) -> Data {
    var header = header.bigEndian
    var length = UInt32(payload.count).bigEndian
    var result = withUnsafeBytes(of: &header) { Data($0) }
    withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
    result.append(payload)
    return result
}
@MainActor private final class PrimaryFrameResult { var count = 0; var width = 0; var trace: PrimaryMediaTrace? }
private struct PrimaryFixturePixel: @unchecked Sendable { let value: CVPixelBuffer; init(_ value: CVPixelBuffer) { self.value = value } }

/// A synthetic 64×64 encoder fixture. It does not sample a screen or any device.
private final class PrimaryEncodedFixture: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var sample: CMSampleBuffer?
    private var status: OSStatus = noErr
    static func make() throws -> (configuration: Data, frame: Data) {
        let result = PrimaryEncodedFixture()
        var encoder: VTCompressionSession?
        try check(VTCompressionSessionCreate(allocator: nil, width: 64, height: 64, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { reference, _, status, _, sample in
                guard let reference else { return }
                let result = Unmanaged<PrimaryEncodedFixture>.fromOpaque(reference).takeUnretainedValue()
                result.sample = sample; result.status = status; result.ready.signal()
            }, refcon: Unmanaged.passUnretained(result).toOpaque(), compressionSessionOut: &encoder))
        let session = try #require(encoder)
        defer { VTCompressionSessionInvalidate(session) }
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue))
        try check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse))
        var pixel: CVPixelBuffer?
        try check(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel))
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 96 : 128,
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        try check(VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
            presentationTimeStamp: CMTime(value: 1_000_000, timescale: 1_000_000), duration: .invalid,
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, sourceFrameRefcon: nil, infoFlagsOut: nil))
        try check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid))
        guard result.ready.wait(timeout: .now() + 3) == .success else { throw FixtureError.failed(-1) }
        try check(result.status)
        let sample = try #require(result.sample)
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var configuration = Data()
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            try check(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil))
            let bytes = try #require(pointer)
            configuration.append(contentsOf: [0, 0, 0, 1]); configuration.append(bytes, count: size)
        }
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        try check(avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) })
        var frame = Data(); var offset = 0
        while offset + 4 <= avcc.count {
            let size = avcc[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard offset + size <= avcc.count else { throw FixtureError.failed(-2) }
            frame.append(contentsOf: [0, 0, 0, 1]); frame.append(avcc[offset..<offset + size]); offset += size
        }
        return (configuration, frame)
    }
    private static func check(_ value: OSStatus) throws { if value != noErr { throw FixtureError.failed(value) } }
    private enum FixtureError: Error { case failed(OSStatus) }
}
