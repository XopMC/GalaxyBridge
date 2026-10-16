import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Preserve the received PNG representation. Creating an NSImage and asking
/// NSPasteboard to serialize it expands screenshots into TIFF on the UI thread.
@MainActor
enum MacClipboardImageWriter {
    static func write(_ png: Data, to pasteboard: NSPasteboard) -> Bool {
        guard !png.isEmpty, png.count <= MacClipboardPayloadPolicy.maximumImageBytes,
              let source = CGImageSourceCreateWithData(png as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 100_000_000
        else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(png, forType: .png)
    }
}
