#!/usr/bin/env swift
import AppKit
import Foundation

// Single artwork source for both apps. Coordinates describe the visible tile,
// not Android's larger adaptive layer (108 dp, visible viewport 72 dp).
// Keep the symbol inside the 66 dp safe circle; the launcher owns its mask.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let checkOnly = CommandLine.arguments.dropFirst().contains("--check")
let macRoot = "macos/GalaxyBridgeMac"
let androidRoot = "android/app/src/main/res"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

func rounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func tileShape(_ rect: NSRect) -> NSBezierPath {
    // Continuous superellipse: no abrupt join between straight sides and arcs.
    let path = NSBezierPath()
    for step in 0...512 {
        let angle = CGFloat(step) * 2 * .pi / 512
        let c = cos(angle), s = sin(angle)
        let point = NSPoint(
            x: rect.midX + rect.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 0.5),
            y: rect.midY + rect.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 0.5)
        )
        if step == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func background(in tile: NSRect, canvas: NSRect) {
    // Fill the overscan too; adaptive parallax must never expose transparency.
    color(0.17, 0.32, 0.94).setFill()
    canvas.fill()
    let gradient = NSGradient(starting: color(0.20, 0.49, 1), ending: color(0.26, 0.24, 0.89))!
    gradient.draw(
        from: NSPoint(x: tile.minX, y: tile.maxY),
        to: NSPoint(x: tile.maxX, y: tile.minY),
        options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation]
    )
}

func symbol(in tile: NSRect, monochrome: Bool = false) {
    NSGraphicsContext.saveGraphicsState()
    let transform = AffineTransform(
        translationByX: tile.minX, byY: tile.minY
    )
    (transform as NSAffineTransform).concat()
    let scale = NSAffineTransform()
    scale.scaleX(by: tile.width / 1024, yBy: tile.height / 1024)
    scale.concat()
    defer { NSGraphicsContext.restoreGraphicsState() }

    NSColor.white.setFill()
    // Mac display and base. Even-odd holes keep the foreground genuinely clear.
    let monitor = rounded(NSRect(x: 466, y: 388, width: 356, height: 304), radius: 44)
    monitor.append(rounded(NSRect(x: 506, y: 428, width: 276, height: 224), radius: 12))
    monitor.windingRule = .evenOdd
    monitor.fill()
    rounded(NSRect(x: 578, y: 337, width: 132, height: 57), radius: 12).fill()
    rounded(NSRect(x: 452, y: 311, width: 384, height: 36), radius: 18).fill()

    // Galaxy: a simple upright silhouette that remains legible at 16 px.
    let phone = rounded(NSRect(x: 204, y: 257, width: 240, height: 504), radius: 58)
    phone.append(rounded(NSRect(x: 244, y: 297, width: 160, height: 424), radius: 22))
    phone.windingRule = .evenOdd
    phone.fill()
    rounded(NSRect(x: 292, y: 322, width: 64, height: 14), radius: 7).fill()

    // The bridge joins the two devices; no text, badge, or platform-only motif.
    (monochrome ? NSColor.white : color(0.53, 0.99, 0.91)).setFill()
    rounded(NSRect(x: 374, y: 497, width: 169, height: 48), radius: 24).fill()
}

func bitmap(size: Int, draw: (NSRect) -> Void) -> Data {
    let pixels = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
    )!
    pixels.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()
    draw(canvas)
    NSGraphicsContext.restoreGraphicsState()
    return pixels.representation(using: .png, properties: [:])!
}

func brandedIcon(size: Int, dockMargin: Bool) -> Data {
    bitmap(size: size) { canvas in
        let margin = dockMargin ? canvas.width * 72 / 1024 : 0
        let tile = canvas.insetBy(dx: margin, dy: margin)
        NSGraphicsContext.saveGraphicsState()
        tileShape(tile).addClip()
        background(in: tile, canvas: canvas)
        symbol(in: tile)
        NSGraphicsContext.restoreGraphicsState()
    }
}

func adaptiveLayer(foreground: Bool, monochrome: Bool = false) -> Data {
    bitmap(size: 1080) { canvas in
        let viewport = canvas.insetBy(dx: 180, dy: 180)
        if foreground { symbol(in: viewport, monochrome: monochrome) }
        else { background(in: viewport, canvas: canvas) }
    }
}

var outputs: [String: Data] = [:]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    outputs["\(macRoot)/Assets.xcassets/AppIcon.appiconset/AppIcon-\(size).png"] = brandedIcon(size: size, dockMargin: true)
}
outputs["\(androidRoot)/drawable-nodpi/ic_galaxy_bridge_brand.png"] = outputs["\(macRoot)/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"]
outputs["\(androidRoot)/drawable-nodpi/ic_galaxy_bridge_foreground.png"] = adaptiveLayer(foreground: true)
outputs["\(androidRoot)/drawable-nodpi/ic_galaxy_bridge_monochrome.png"] = adaptiveLayer(foreground: true, monochrome: true)
outputs["\(androidRoot)/drawable-nodpi/ic_galaxy_bridge_background.png"] = adaptiveLayer(foreground: false)
for (density, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    let data = brandedIcon(size: size, dockMargin: false)
    outputs["\(androidRoot)/mipmap-\(density)/ic_galaxy_bridge.png"] = data
    outputs["\(androidRoot)/mipmap-\(density)/ic_galaxy_bridge_round.png"] = data
}

var stale: [String] = []
for (path, data) in outputs.sorted(by: { $0.key < $1.key }) {
    let destination = root.appendingPathComponent(path)
    if checkOnly {
        if (try? Data(contentsOf: destination)) != data { stale.append(path) }
    } else {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }
}
if !stale.isEmpty {
    fputs("FAIL: app icons differ from shared artwork:\n" + stale.joined(separator: "\n") + "\n", stderr)
    exit(1)
}

// iconutil is a packaging conversion, never a second artwork implementation.
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("gb-icon-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let iconset = temporary.appendingPathComponent("GalaxyBridge.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try outputs["\(macRoot)/Assets.xcassets/AppIcon.appiconset/AppIcon-\(size * scale).png"]!.write(to: iconset.appendingPathComponent(name))
    }
}
let icns = temporary.appendingPathComponent("GalaxyBridge.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", icns.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
let packagedIcon = root.appendingPathComponent("\(macRoot)/Resources/GalaxyBridge.icns")
let icnsData = try Data(contentsOf: icns)
if checkOnly {
    guard (try? Data(contentsOf: packagedIcon)) == icnsData else {
        fputs("FAIL: packaged ICNS differs from shared artwork\n", stderr)
        exit(1)
    }
} else { try icnsData.write(to: packagedIcon, options: .atomic) }
print("\(checkOnly ? "PASS verified" : "Generated") \(outputs.count) shared icon assets and ICNS")
