import AppKit
import Foundation
import Testing
@testable import GalaxyBridgeMac

@Suite(.serialized)
@MainActor
struct ClipboardImageWriterTests {
    @Test func remotePNGKeepsExactBytesAsPreferredRepresentation() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2,
            pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        memset(pixels, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(MacClipboardImageWriter.write(png, to: board))
        #expect(board.data(forType: .png) == png)
        // macOS advertises automatic TIFF aliases for a PNG pasteboard item.
        // The representation we supply must remain the original PNG bytes.
        #expect(board.availableType(from: [.png, .tiff]) == .png)
        #expect(NSImage(pasteboard: board) != nil)
    }

    @Test func largeCompressedPNGWithinAndroidBudgetRemainsSupported() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8192,
            pixelsHigh: 8192, bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        memset(bytes, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count < MacClipboardPayloadPolicy.maximumImageBytes)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(MacClipboardImageWriter.write(png, to: board))
        #expect(board.data(forType: .png) == png)
    }

    @Test func invalidOrOversizeImageDoesNotClearCurrentClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("keep this text", forType: .string)
        let revision = board.changeCount
        for data in [Data("invalid PNG".utf8), Data(repeating: 0, count: 4 * 1024 * 1024 + 1)] {
            #expect(!MacClipboardImageWriter.write(data, to: board))
            #expect(board.changeCount == revision)
            #expect(board.string(forType: .string) == "keep this text")
        }
    }
}
