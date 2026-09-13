import CoreMedia
import Foundation
import GalaxyBridgeCore

/// Solely owned by the input lease's final-release closure. Release external
/// storage synchronously BEFORE publishing native zero-reference settlement.
final class NativeMediaExternalRetention: @unchecked Sendable {
    private var retained: NativeMediaLease?
    init(_ retained: NativeMediaLease?) { self.retained = retained }
    func releaseAtFinalInputReference() { retained = nil }
}

/// Explicit legal byte capacities, not allocator rounding or opaque framework
/// memory. Data is immutable after construction. Heap-backed Data carries its
/// charge through the deallocator; inline bytes stay in the bounded work value.
/// Native consumers retain NativeMediaWork, not just its inline event fields.
enum NativeMediaBuffer {
    static func capacity(for count: Int) -> Int {
        // Also cover Data's fixed inline representation while the raw copy
        // overlaps construction of a small value (which may copy inline).
        count + MemoryLayout<Data>.size
    }

    static func make(count: Int, lease: NativeMediaLease,
                     fill: (UnsafeMutableRawBufferPointer) -> Void) -> Data {
        precondition(count > 0)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        fill(UnsafeMutableRawBufferPointer(start: pointer, count: count))
        return Data(bytesNoCopy: pointer, count: count, deallocator: .custom { pointer, _ in
            pointer.deallocate()
            withExtendedLifetime(lease) {}
        })
    }

    static func copy(_ data: Data, lease: NativeMediaLease) -> Data {
        make(count: data.count, lease: lease) { destination in
            data.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
    }
}

/// Two streaming passes with constant scalar state. In particular, no array of
/// start positions/NAL units and no growable sample Data. Legacy AnnexB remains
/// unchanged; this scanner has the same 4-byte-before-3-byte/no-start semantics.
enum NativeAnnexB {
    static func formatDescription(from data: Data, codec: ScrcpyCodec,
                                  work: NativeMediaWork) throws -> (CMVideoFormatDescription, NativeMediaLease)? {
        try data.withUnsafeBytes { bytes in
            var vps: Range<Int>?
            var sps: Range<Int>?
            var pps: Range<Int>?
            forEachNAL(in: bytes) { range in
                let type = codec == .h264 ? bytes[range.lowerBound] & 0x1f : (bytes[range.lowerBound] >> 1) & 0x3f
                if codec == .h264 {
                    if type == 7 && sps == nil { sps = range }
                    if type == 8 && pps == nil { pps = range }
                } else {
                    if type == 32 && vps == nil { vps = range }
                    if type == 33 && sps == nil { sps = range }
                    if type == 34 && pps == nil { pps = range }
                }
            }
            guard codec == .h264 || codec == .h265 else { throw VideoDecoderError.unsupportedCodec }
            guard let sps, let pps, codec == .h264 || vps != nil else { throw VideoDecoderError.missingParameterSets }
            // Fixed pointer/size buffers, plus the parameter bytes copied into
            // the native format description. No NAL Data views are constructed.
            let parameterBytes = sps.count + pps.count + (vps?.count ?? 0)
            let fixedCapacity = 3 * (MemoryLayout<UnsafePointer<UInt8>>.stride + MemoryLayout<Int>.stride)
            guard let storage = work.reserve(parameterBytes + fixedCapacity) else { return nil }
            var output: CMFormatDescription?
            let status = withUnsafeTemporaryAllocation(of: UnsafePointer<UInt8>.self, capacity: 3) { pointers in
                withUnsafeTemporaryAllocation(of: Int.self, capacity: 3) { sizes in
                    let base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    if let vps, codec == .h265 {
                        pointers.initializeElement(at: 0, to: base.advanced(by: vps.lowerBound))
                        pointers.initializeElement(at: 1, to: base.advanced(by: sps.lowerBound))
                        pointers.initializeElement(at: 2, to: base.advanced(by: pps.lowerBound))
                        sizes.initializeElement(at: 0, to: vps.count)
                        sizes.initializeElement(at: 1, to: sps.count)
                        sizes.initializeElement(at: 2, to: pps.count)
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                            parameterSetCount: 3, parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!,
                            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &output)
                    }
                    pointers.initializeElement(at: 0, to: base.advanced(by: sps.lowerBound))
                    pointers.initializeElement(at: 1, to: base.advanced(by: pps.lowerBound))
                    sizes.initializeElement(at: 0, to: sps.count)
                    sizes.initializeElement(at: 1, to: pps.count)
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 2, parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &output)
                }
            }
            guard status == noErr, let output else { throw VideoDecoderError.formatDescription(status) }
            return (output, storage)
        }
    }

    static func forEachNAL(in bytes: UnsafeRawBufferPointer, _ body: (Range<Int>) -> Void) {
        var index = 0
        var payloadStart: Int?
        while index + 3 <= bytes.count {
            let length: Int
            if index + 4 <= bytes.count, bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 { length = 4 }
            else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 { length = 3 }
            else { index += 1; continue }
            if let start = payloadStart, start < index { body(start..<index) }
            payloadStart = index + length
            index += length
        }
        if let start = payloadStart {
            if start < bytes.count { body(start..<bytes.count) }
        } else if !bytes.isEmpty { body(0..<bytes.count) }
    }

    static func lengthPrefixedSample(from data: Data, work: NativeMediaWork) -> (Data, NativeMediaLease)? {
        data.withUnsafeBytes { bytes in
            var count = 0
            forEachNAL(in: bytes) { count += 4 + $0.count }
            guard count > 0 else { work.attempt.fail(.invalidSize); return nil }
            // Both the exact sample allocation and its forthcoming CMBlockBuffer
            // copy coexist. Reserve both before either explicit allocation.
            guard let storage = work.reserve(NativeMediaBuffer.capacity(for: count) + count) else { return nil }
            let sample = NativeMediaBuffer.make(count: count, lease: storage) { output in
                var offset = 0
                forEachNAL(in: bytes) { range in
                    var length = UInt32(range.count).bigEndian
                    withUnsafeBytes(of: &length) { header in
                        output.baseAddress!.advanced(by: offset).copyMemory(from: header.baseAddress!, byteCount: 4)
                    }
                    offset += 4
                    output.baseAddress!.advanced(by: offset).copyMemory(
                        from: bytes.baseAddress!.advanced(by: range.lowerBound), byteCount: range.count)
                    offset += range.count
                }
            }
            return (sample, storage)
        }
    }
}
