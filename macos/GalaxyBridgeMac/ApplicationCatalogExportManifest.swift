import Foundation

enum ApplicationCatalogExportManifestError: Error, Equatable {
    case payloadTooLarge
    case unsupportedVersion
    case tooManyApplications
}

struct ApplicationCatalogExportApplication: Equatable, Sendable {
    let packageName: String
    let componentName: String
    let label: String
    let isSystem: Bool
    let iconPath: String?

    func iconURL(relativeTo rootURL: URL) -> URL? {
        guard let iconPath,
              iconPath.range(of: #"^icons/[0-9]+\.png$"#, options: .regularExpression) != nil
        else { return nil }
        return rootURL.appendingPathComponent(iconPath, isDirectory: false)
    }
}

struct ApplicationCatalogExportManifest: Equatable, Sendable {
    let applications: [ApplicationCatalogExportApplication]

    static func decode(
        _ data: Data,
        maximumBytes: Int = 2 * 1_024 * 1_024,
        maximumApplications: Int = 2_048
    ) throws -> Self {
        guard data.count <= maximumBytes else {
            throw ApplicationCatalogExportManifestError.payloadTooLarge
        }
        let raw = try JSONDecoder().decode(RawManifest.self, from: data)
        guard raw.version == 1 else {
            throw ApplicationCatalogExportManifestError.unsupportedVersion
        }
        guard raw.applications.count <= maximumApplications else {
            throw ApplicationCatalogExportManifestError.tooManyApplications
        }
        var seen = Set<String>()
        let applications = raw.applications.compactMap { raw -> ApplicationCatalogExportApplication? in
            guard isPackageName(raw.package),
                  isComponent(raw.component, for: raw.package),
                  !raw.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  raw.label.utf8.count <= 512,
                  seen.insert(raw.package).inserted
            else { return nil }
            let safeIconPath: String?
            if let icon = raw.icon,
               icon.range(of: #"^icons/[0-9]+\.png$"#, options: .regularExpression) != nil {
                safeIconPath = icon
            } else {
                safeIconPath = nil
            }
            return .init(
                packageName: raw.package,
                componentName: raw.component,
                label: raw.label,
                isSystem: raw.system,
                iconPath: safeIconPath
            )
        }
        return Self(applications: applications)
    }

    private static func isPackageName(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isLetter || first == "_" else { return false }
            return part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
    }

    private static func isComponent(_ value: String, for packageName: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == Substring(packageName),
              !parts[1].isEmpty
        else { return false }
        return parts[1].allSatisfy { $0.isLetter || $0.isNumber || "_.$".contains($0) }
    }

    private struct RawManifest: Decodable {
        let version: Int
        let applications: [RawApplication]
    }

    private struct RawApplication: Decodable {
        let package: String
        let component: String
        let label: String
        let system: Bool
        let icon: String?
    }
}
