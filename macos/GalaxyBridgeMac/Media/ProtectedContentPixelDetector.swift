import CoreVideo
import Foundation

enum ProtectedContentPixelDetector {
    private static let blackThreshold: UInt8 = 24
    private static let minimumBlackFraction = 0.985
    private static let gridSize = 32

    /// Samples luma sparsely and returns only an aggregate decision. Pixel values are
    /// never copied, logged, cached, or retained after this call.
    static func isUniformlyBlack(_ pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        if CVPixelBufferIsPlanar(pixelBuffer) {
            guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
                  let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            else { return false }
            return sampleEightBitLuma(
                base: base,
                width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            )
        }

        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent8,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return false }
        return sampleEightBitLuma(
            base: base,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
    }

    private static func sampleEightBitLuma(
        base: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> Bool {
        guard width > 0, height > 0, bytesPerRow >= width else { return false }
        let columns = min(gridSize, width)
        let rows = min(gridSize, height)
        var black = 0
        var sampled = 0
        for rowIndex in 0 ..< rows {
            let y = min(height - 1, rowIndex * height / rows)
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for columnIndex in 0 ..< columns {
                let x = min(width - 1, columnIndex * width / columns)
                sampled += 1
                if row[x] <= blackThreshold { black += 1 }
            }
        }
        return sampled > 0 && Double(black) / Double(sampled) >= minimumBlackFraction
    }
}
