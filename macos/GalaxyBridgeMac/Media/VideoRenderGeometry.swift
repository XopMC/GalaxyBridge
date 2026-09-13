import CoreGraphics
import Foundation

struct VideoRenderPlacement: Equatable {
    let scale: CGFloat
    let scaledSize: CGSize
    let origin: CGPoint
}

enum VideoRenderGeometry {
    static func aspectFill(
        sourceSize: CGSize,
        destinationSize: CGSize
    ) -> VideoRenderPlacement? {
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              destinationSize.width.isFinite,
              destinationSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0,
              destinationSize.width > 0,
              destinationSize.height > 0
        else { return nil }

        let scale = max(
            destinationSize.width / sourceSize.width,
            destinationSize.height / sourceSize.height
        )
        let scaledSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        return VideoRenderPlacement(
            scale: scale,
            scaledSize: scaledSize,
            origin: CGPoint(
                x: (destinationSize.width - scaledSize.width) / 2,
                y: (destinationSize.height - scaledSize.height) / 2
            )
        )
    }
}
