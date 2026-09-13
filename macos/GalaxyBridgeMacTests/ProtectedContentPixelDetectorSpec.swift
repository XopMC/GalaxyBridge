import CoreVideo
import Foundation

@main
private enum ProtectedContentPixelDetectorSpec {
    static func main() throws {
        let black = try pixelBuffer(width: 64, height: 64, value: 16)
        let darkGray = try pixelBuffer(width: 64, height: 64, value: 42)
        let mostlyBlackWithVisibleTile = try pixelBuffer(width: 64, height: 64, value: 16) { x, y in
            x >= 16 && x < 48 && y >= 16 && y < 48 ? 180 : 16
        }

        try expect(
            ProtectedContentPixelDetector.isUniformlyBlack(black),
            "video-range black must be recognized without retaining frame content"
        )
        try expect(
            !ProtectedContentPixelDetector.isUniformlyBlack(darkGray),
            "a dark but visible frame must not be hidden"
        )
        try expect(
            !ProtectedContentPixelDetector.isUniformlyBlack(mostlyBlackWithVisibleTile),
            "visible content inside a black frame must not be misclassified"
        )
        print("PASS protected-content pixel detector distinguishes uniform black from visible dark frames")
    }

    private static func pixelBuffer(
        width: Int,
        height: Int,
        value: UInt8,
        valueAt: ((Int, Int) -> UInt8)? = nil
    ) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &optional
        )
        guard status == kCVReturnSuccess, let buffer = optional else {
            throw SpecFailure("could not create pixel buffer: \(status)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpecFailure("missing base address") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width { row[x] = valueAt?(x, y) ?? value }
        }
        return buffer
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message) }
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
