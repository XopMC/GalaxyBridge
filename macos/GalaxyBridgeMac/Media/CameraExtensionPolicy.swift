import Foundation
import SystemExtensions

enum CameraExtensionPolicy {
    static func shouldReplace(existingVersion: String, existingBuild: String, incomingVersion: String, incomingBuild: String) -> Bool {
        guard let versionOrder = compare(incomingVersion, existingVersion),
              let buildOrder = compare(incomingBuild, existingBuild) else { return false }
        return versionOrder == .orderedDescending || (versionOrder == .orderedSame && buildOrder == .orderedDescending)
    }

    static func completionStatusKey(_ result: OSSystemExtensionRequest.Result) -> String {
        switch result {
        case .completed: "CAMERA_EXTENSION_READY"
        case .willCompleteAfterReboot: "CAMERA_EXTENSION_RESTART_REQUIRED"
        @unknown default: "CAMERA_EXTENSION_NOT_INSTALLED"
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        func components(_ value: String) -> [UInt64]? {
            let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !pieces.isEmpty else { return nil }
            var values: [UInt64] = []
            for piece in pieces {
                guard !piece.isEmpty, piece.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = UInt64(piece) else { return nil }
                values.append(number)
            }
            return values
        }
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
}
