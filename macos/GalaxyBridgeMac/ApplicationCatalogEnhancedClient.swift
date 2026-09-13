#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeEnhancedCore

struct ApplicationCatalogEnhancedClient: Sendable {
    let adb: ADBClient
    let iconCache: ApplicationIconCache?

    init(adb: ADBClient, iconCache: ApplicationIconCache? = try? ApplicationIconCache()) {
        self.adb = adb
        self.iconCache = iconCache
    }

    func load(deviceID: String, serial: String) throws -> [ApplicationCatalogItem] {
        let serverURL = try ScrcpyServerLocator.locate()
        try adb.push(
            serial: serial,
            localURL: serverURL,
            remotePath: ScrcpyLaunchConfiguration.remoteServerPath
        )
        let applications = try adb.scrcpyApplications(serial: serial)
        let export = loadIconExport(serial: serial)

        return applications.compactMap { application in
            guard application.componentName != nil else { return nil }
            let iconPNG = iconPNG(
                deviceID: deviceID,
                packageName: application.packageName,
                export: export
            )
            return ApplicationCatalogItem(
                packageName: application.packageName,
                componentName: application.componentName,
                label: application.label,
                iconPNG: iconPNG,
                isSystem: application.isSystem
            )
        }
        .sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private func loadIconExport(serial: String) -> [String: Data] {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let localRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyBridge-AppCatalog-\(requestID)", isDirectory: true)
        var remotePath: String?
        defer {
            try? FileManager.default.removeItem(at: localRoot)
            if let remotePath {
                try? adb.removeApplicationCatalogExport(serial: serial, remotePath: remotePath)
            }
        }
        do {
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
            remotePath = try adb.exportApplicationCatalog(serial: serial, requestID: requestID)
            try adb.pull(serial: serial, remotePath: "\(remotePath!)/.", localURL: localRoot)
            let manifestData = try Data(
                contentsOf: localRoot.appendingPathComponent("manifest.json"),
                options: [.mappedIfSafe]
            )
            let manifest = try ApplicationCatalogExportManifest.decode(manifestData)
            return Dictionary(uniqueKeysWithValues: manifest.applications.compactMap { application in
                guard let iconURL = application.iconURL(relativeTo: localRoot),
                      let data = try? Data(contentsOf: iconURL, options: [.mappedIfSafe]),
                      data.count <= 4 * 1_024 * 1_024
                else { return nil }
                return (application.packageName, data)
            })
        } catch {
            return [:]
        }
    }

    private func iconPNG(
        deviceID: String,
        packageName: String,
        export: [String: Data]
    ) -> Data? {
        if let iconCache,
           let cached = try? iconCache.iconPNG(deviceID: deviceID, packageName: packageName) {
            return cached
        }
        guard let iconData = export[packageName] else { return nil }
        try? iconCache?.store(iconData, deviceID: deviceID, packageName: packageName)
        return (try? iconCache?.iconPNG(deviceID: deviceID, packageName: packageName)) ?? iconData
    }
}
#endif
