import Foundation

struct CatalogIconClientHarness {
    let iconCache: ApplicationIconCache?
    // ACTUAL_ICON
}
@main enum CatalogIconRefreshSpec {
    static func png(_ marker: UInt8) -> Data {
        Data([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,128,0,0,0,128,marker])
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-icon-refresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try ApplicationIconCache(rootURL: root)
        let client = CatalogIconClientHarness(iconCache: cache)
        let old = png(1), fresh = png(2), device = "synthetic-phone", package = "com.example.synthetic"
        try cache.store(old, deviceID: device, packageName: package)
        precondition(client.iconPNG(deviceID: device, packageName: package, export: [package:fresh]) == fresh,
                     "Fresh export must replace a stale cached icon")
        let persisted = try cache.iconPNG(deviceID: device, packageName: package)
        precondition(persisted == fresh)
        precondition(client.iconPNG(deviceID: device, packageName: package, export: [:]) == fresh)
        precondition(client.iconPNG(deviceID: device, packageName: package, export: [package:Data([1,2,3])]) == fresh,
                     "Malformed fresh data must retain a valid previous icon")
        let uncached = CatalogIconClientHarness(iconCache: nil)
        precondition(uncached.iconPNG(deviceID: device, packageName: package, export: [package:fresh]) == fresh)
        precondition(uncached.iconPNG(deviceID: device, packageName: package, export: [package:Data([1,2,3])]) == nil)
        precondition(client.iconPNG(deviceID: "other-synthetic-phone", packageName: package, export: [:]) == nil)
        print("PASS actual icon refresh: fresh export, persistence, malformed fallback, absent cache and device isolation")
    }
}
