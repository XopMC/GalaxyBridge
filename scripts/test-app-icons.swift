#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let android = root.appendingPathComponent("android/app/src/main/res")
let mac = root.appendingPathComponent("macos/GalaxyBridgeMac/Assets.xcassets/AppIcon.appiconset")

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func png(_ url: URL, size: Int) throws -> NSBitmapImageRep {
    let data = try Data(contentsOf: url)
    guard let image = NSBitmapImageRep(data: data) else { fatalError("Invalid PNG: \(url.path)") }
    require(image.pixelsWide == size && image.pixelsHigh == size, "Wrong dimensions: \(url.lastPathComponent)")
    require(image.hasAlpha, "Missing alpha channel: \(url.lastPathComponent)")
    return image
}

// About and Dock use byte-identical canonical artwork, not two approximations.
let canonical = try Data(contentsOf: mac.appendingPathComponent("AppIcon-1024.png"))
let about = try Data(contentsOf: android.appendingPathComponent("drawable-nodpi/ic_galaxy_bridge_brand.png"))
require(canonical == about, "Android About and Mac icon differ")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let icon = try png(mac.appendingPathComponent("AppIcon-\(size).png"), size: size)
    require(icon.colorAt(x: 0, y: 0)!.alphaComponent == 0, "Dock corners need transparency")
    require(icon.colorAt(x: size / 2, y: size / 2)!.alphaComponent > 0.99, "Icon center must be opaque")
}
for (density, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    for suffix in ["", "_round"] {
        _ = try png(android.appendingPathComponent("mipmap-\(density)/ic_galaxy_bridge\(suffix).png"), size: size)
    }
}

let foreground = try png(android.appendingPathComponent("drawable-nodpi/ic_galaxy_bridge_foreground.png"), size: 1080)
let monochrome = try png(android.appendingPathComponent("drawable-nodpi/ic_galaxy_bridge_monochrome.png"), size: 1080)
let background = try png(android.appendingPathComponent("drawable-nodpi/ic_galaxy_bridge_background.png"), size: 1080)
var ink = 0
for y in 0..<1080 {
    for x in 0..<1080 {
        let a = foreground.colorAt(x: x, y: y)!.alphaComponent
        let mono = monochrome.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        require(abs(a - mono.alphaComponent) < 0.005, "Themed icon must retain symbol alpha")
        require(background.colorAt(x: x, y: y)!.alphaComponent > 0.99, "Adaptive background has a transparent hole")
        if a > 0.01 {
            ink += 1
            // Android's guaranteed safe zone is a centered 66 dp circle in 108 dp.
            let dx = Double(x) + 0.5 - 540, dy = Double(y) + 0.5 - 540
            require(dx * dx + dy * dy <= 330 * 330, "Symbol clips under a supported adaptive mask")
            require(min(mono.redComponent, mono.greenComponent, mono.blueComponent) > 0.99, "Themed symbol must be tintable white")
        }
    }
}
require(ink > 40_000 && ink < 180_000, "Foreground is missing or contains a background tile")
func adaptiveMappingsAreValid(_ xml: String) throws -> Bool {
    let document = try XMLDocument(xmlString: xml)
    guard let root = document.rootElement(), root.name == "adaptive-icon" else { return false }
    return ["background", "foreground", "monochrome"].allSatisfy { layer in
        let elements = root.elements(forName: layer)
        return elements.count == 1 && elements[0].attribute(
            forLocalName: "drawable", uri: "http://schemas.android.com/apk/res/android"
        )?.stringValue == "@drawable/ic_galaxy_bridge_\(layer)"
    }
}
for file in ["ic_galaxy_bridge.xml", "ic_galaxy_bridge_round.xml"] {
    let xml = try String(contentsOf: android.appendingPathComponent("mipmap-anydpi-v26/\(file)"), encoding: .utf8)
    let valid = try adaptiveMappingsAreValid(xml)
    require(valid, "Adaptive layers must map to their corresponding artwork")
    let swapped = xml.replacingOccurrences(of: "_background", with: "_temporary")
        .replacingOccurrences(of: "_foreground", with: "_background")
        .replacingOccurrences(of: "_temporary", with: "_foreground")
    let swappedValid = try adaptiveMappingsAreValid(swapped)
    require(!swappedValid, "Verifier failed to reject swapped adaptive layers")
}
print("PASS shared artwork, 17 icon sizes, adaptive safe circle, opaque overscan, themed alpha and About parity")
