import CoreGraphics
import Foundation

@main
enum VideoRenderGeometrySpec {
    static func main() throws {
        let portrait = try require(
            VideoRenderGeometry.aspectFill(
                sourceSize: CGSize(width: 1_080, height: 2_400),
                destinationSize: CGSize(width: 500, height: 1_000)
            ),
            "portrait placement"
        )
        try expectApproximately(portrait.scale, 500 / 1_080, "portrait fill uses the larger scale")
        try expectApproximately(portrait.scaledSize.width, 500, "portrait fills destination width")
        try expect(portrait.scaledSize.height >= 1_000, "portrait fill cannot leave horizontal bars")
        try expectApproximately(portrait.origin.x, 0, "portrait crop remains horizontally centered")
        try expect(portrait.origin.y < 0, "portrait mismatch crops excess height equally")
        try expectApproximately(
            portrait.scaledSize.width / portrait.scaledSize.height,
            1_080 / 2_400,
            "portrait fill preserves source aspect ratio"
        )

        let landscape = try require(
            VideoRenderGeometry.aspectFill(
                sourceSize: CGSize(width: 2_400, height: 1_080),
                destinationSize: CGSize(width: 1_000, height: 500)
            ),
            "landscape placement"
        )
        try expectApproximately(landscape.scaledSize.height, 500, "landscape fills destination height")
        try expect(landscape.scaledSize.width >= 1_000, "landscape fill cannot leave vertical bars")
        try expect(landscape.origin.x < 0, "landscape mismatch crops excess width equally")
        try expectApproximately(landscape.origin.y, 0, "landscape crop remains vertically centered")
        try expectApproximately(
            landscape.scaledSize.width / landscape.scaledSize.height,
            2_400 / 1_080,
            "landscape fill preserves source aspect ratio"
        )

        try expect(
            VideoRenderGeometry.aspectFill(sourceSize: .zero, destinationSize: CGSize(width: 500, height: 1_000)) == nil,
            "invalid source size must not create an infinite transform"
        )
        try expect(
            VideoRenderGeometry.aspectFill(sourceSize: CGSize(width: 500, height: 1_000), destinationSize: .zero) == nil,
            "invalid destination size must not create an infinite transform"
        )

        print("PASS Metal video aspect-fill covers the viewer without bars or distortion")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpecFailure(message: message) }
    }

    private static func expectApproximately(
        _ actual: CGFloat,
        _ expected: CGFloat,
        _ message: String,
        epsilon: CGFloat = 0.000_001
    ) throws {
        try expect(abs(actual - expected) <= epsilon, "\(message): expected \(expected), got \(actual)")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SpecFailure(message: "missing \(message)") }
        return value
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
