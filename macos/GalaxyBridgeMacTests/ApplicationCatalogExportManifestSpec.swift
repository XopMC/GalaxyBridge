import Foundation

@main
private enum ApplicationCatalogExportManifestSpec {
    static func main() throws {
        let json = Data("""
        {"version":1,"applications":[
          {"package":"com.samsung.android.app.notes","component":"com.samsung.android.app.notes/.NotesActivity","label":"Samsung Notes","system":false,"icon":"icons/0.png"},
          {"package":"bad package","component":"bad/.Activity","label":"Bad","system":false,"icon":"../secret"}
        ]}
        """.utf8)
        let manifest = try ApplicationCatalogExportManifest.decode(json, maximumApplications: 10)
        guard manifest.applications.count == 1 else { fatalError("unsafe catalog records were not rejected") }
        let root = URL(fileURLWithPath: "/tmp/catalog", isDirectory: true)
        guard manifest.applications[0].iconURL(relativeTo: root)?.path == "/tmp/catalog/icons/0.png" else {
            fatalError("safe relative icon path did not resolve")
        }

        let unsupportedVersion = Data("{\"version\":2,\"applications\":[]}".utf8)
        do {
            _ = try ApplicationCatalogExportManifest.decode(unsupportedVersion)
            fatalError("unsupported manifest version was accepted")
        } catch ApplicationCatalogExportManifestError.unsupportedVersion {
            // Expected.
        }
        print("PASS bounded application catalog export manifest")
    }
}
