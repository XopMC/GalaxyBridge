#!/usr/bin/env swift
import AppKit
import Foundation

// Finder uses the same 780×640 point canvas at both display densities.
// Native app/folder icons remain real draggable files, not part of the artwork.
// The lower plain area tolerates Finder chrome kept visible by user preferences.
let canvas = NSSize(width: 780, height: 640)
guard CommandLine.arguments.count == 2 else {
    fatalError("usage: generate-dmg-artwork.swift OUTPUT.tiff")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
    NSRect(x: x, y: canvas.height - top - height, width: width, height: height)
}
func rounded(_ bounds: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
}
func text(_ value: String, _ bounds: NSRect, size: CGFloat, weight: NSFont.Weight,
          ink: NSColor, alignment: NSTextAlignment = .left, tracking: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    NSAttributedString(string: value, attributes: [
        .font: font, .foregroundColor: ink, .paragraphStyle: paragraph, .kern: tracking
    ]).draw(in: bounds)
}

func drawArtwork() {
    color(0xF5F6FA).setFill()
    NSRect(origin: .zero, size: canvas).fill()
    // Restrained One UI palette, generous spacing and soft rounded surfaces.
    text("GALAXY + MAC", rect(56, 31, 450, 20), size: 11, weight: .bold,
         ink: color(0x246BFD), tracking: 2.5)
    text("Galaxy Bridge", rect(54, 59, 500, 61), size: 43, weight: .bold, ink: color(0x151923))
    text("Ваш Galaxy. Ваш Mac.", rect(57, 122, 470, 28), size: 17, weight: .regular, ink: color(0x626B7C))
    rounded(rect(572, 73, 152, 34), radius: 17, fill: color(0xE6EEFF))
    text("Установка / Install", rect(572, 82, 152, 18), size: 12, weight: .semibold,
         ink: color(0x246BFD), alignment: .center)

    for x: CGFloat in [88, 468] {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0xB5C7EE, alpha: 0.28)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        rounded(rect(x, 202, 224, 174), radius: 34, fill: .white)
        NSGraphicsContext.restoreGraphicsState()
    }
    // Points match the Finder icon centers in build-macos-dmg-layout.py.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 348, y: canvas.height - 270))
    arrow.line(to: NSPoint(x: 432, y: canvas.height - 270))
    arrow.move(to: NSPoint(x: 415, y: canvas.height - 253))
    arrow.line(to: NSPoint(x: 432, y: canvas.height - 270))
    arrow.line(to: NSPoint(x: 415, y: canvas.height - 287))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0x246BFD).setStroke()
    arrow.stroke()

    text("Перетащите в «Программы»", rect(40, 413, 700, 35), size: 24, weight: .semibold,
         ink: color(0x171C28), alignment: .center)
    text("Drag Galaxy Bridge into Applications", rect(40, 452, 700, 26), size: 16, weight: .regular,
         ink: color(0x687286), alignment: .center)
    text("macOS 14+  ·  Apple Silicon", rect(40, 495, 700, 18), size: 11, weight: .medium,
         ink: color(0x8A93A4), alignment: .center)
}

let image = NSImage(size: canvas)
for scale in [1, 2] {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmap = CGContext(data: nil, width: Int(canvas.width) * scale, height: Int(canvas.height) * scale,
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
    drawArtwork()
    NSGraphicsContext.restoreGraphicsState()
    let representation = NSBitmapImageRep(cgImage: bitmap.makeImage()!)
    representation.size = canvas
    image.addRepresentation(representation)
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try image.tiffRepresentation(using: .lzw, factor: 1)!.write(to: output, options: .atomic)
let saved = try Data(contentsOf: output)
let representations = NSBitmapImageRep.imageReps(with: saved).compactMap { $0 as? NSBitmapImageRep }
guard Set(representations.map(\.pixelsWide)) == [780, 1560],
      representations.allSatisfy({ abs($0.size.width - canvas.width) < 0.1
          && abs($0.size.height - canvas.height) < 0.1 }) else {
    fatalError("Artwork lost a display density or its point-size metadata")
}
print("Generated One UI-inspired DMG artwork: 780×640 points, 1× and 2×")
