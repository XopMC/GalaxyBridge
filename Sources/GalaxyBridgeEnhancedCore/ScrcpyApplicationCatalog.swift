import Foundation

public struct ScrcpyApplication: Equatable, Sendable {
    public let packageName: String
    public let componentName: String?
    public let label: String
    public let isSystem: Bool

    public init(
        packageName: String,
        componentName: String? = nil,
        label: String,
        isSystem: Bool
    ) {
        self.packageName = packageName
        self.componentName = componentName
        self.label = label
        self.isSystem = isSystem
    }
}

public enum ScrcpyApplicationTargetError: Error, Equatable {
    case invalidPackageName
}

public struct ScrcpyApplicationTarget: Equatable, Sendable {
    public let packageName: String

    public init(packageName: String) throws {
        guard ScrcpyPackageName.isValid(packageName) else {
            throw ScrcpyApplicationTargetError.invalidPackageName
        }
        self.packageName = packageName
    }
}

public enum ScrcpyApplicationListParser {
    public static func parse(_ output: String) -> [ScrcpyApplication] {
        var result: [ScrcpyApplication] = []
        var pendingLongLabel: (label: String, isSystem: Bool)?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* ") || line.hasPrefix("- ") {
                let isSystem = line.hasPrefix("* ")
                let body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let package = body.split(whereSeparator: \.isWhitespace).last.map(String.init),
                   ScrcpyPackageName.isValid(package) {
                    let label = String(body.dropLast(package.count))
                        .trimmingCharacters(in: .whitespaces)
                    if !label.isEmpty {
                        result.append(.init(packageName: package, label: label, isSystem: isSystem))
                        pendingLongLabel = nil
                    }
                } else if !body.isEmpty {
                    pendingLongLabel = (body, isSystem)
                }
                continue
            }

            if let pending = pendingLongLabel, ScrcpyPackageName.isValid(line) {
                result.append(
                    .init(
                        packageName: line,
                        label: pending.label,
                        isSystem: pending.isSystem
                    )
                )
                pendingLongLabel = nil
            }
        }

        var seen = Set<String>()
        return result.filter { seen.insert($0.packageName).inserted }
    }
}

public enum ScrcpyLaunchableComponentParser {
    public static func parse(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let component = String(rawLine).trimmingCharacters(in: .whitespaces)
            let parts = component.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let packageName = String(parts[0])
            let activityName = String(parts[1])
            guard ScrcpyPackageName.isValid(packageName),
                  !activityName.isEmpty,
                  activityName.allSatisfy({ $0.isLetter || $0.isNumber || "_.$".contains($0) })
            else { continue }
            result[packageName, default: component] = component
        }
        return result
    }
}

private enum ScrcpyPackageName {
    static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isLetter || first == "_" else { return false }
            return part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
    }
}
