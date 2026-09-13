import Foundation

public struct DisplayGeometry: Equatable, Sendable {
    public let pixelWidth: Int32
    public let pixelHeight: Int32

    public init(pixelWidth: Int32, pixelHeight: Int32) {
        precondition(pixelWidth > 0 && pixelHeight > 0)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct PixelPoint: Equatable, Sendable {
    public let x: Int32
    public let y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

public struct NormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func pixelPoint(in geometry: DisplayGeometry) -> PixelPoint {
        let normalizedX = x.isFinite ? min(max(x, 0), 1) : 0
        let normalizedY = y.isFinite ? min(max(y, 0), 1) : 0
        return PixelPoint(
            x: min(Int32(normalizedX * Double(geometry.pixelWidth)), geometry.pixelWidth - 1),
            y: min(Int32(normalizedY * Double(geometry.pixelHeight)), geometry.pixelHeight - 1)
        )
    }
}
