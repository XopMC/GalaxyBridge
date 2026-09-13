import Foundation

@main
enum CameraAppGroupIdentifierSpec {
    static func main() throws {
        try expectEqual(
            CameraAppGroupIdentifier.resolve(configuredValue: "TEAM123.group.com.xopmc.GalaxyBridge"),
            "TEAM123.group.com.xopmc.GalaxyBridge",
            "the runtime identifier must exactly preserve the expanded entitlement value"
        )
        try expectEqual(
            CameraAppGroupIdentifier.resolve(configuredValue: "$(TeamIdentifierPrefix)group.com.xopmc.GalaxyBridge"),
            nil,
            "an unexpanded build-setting placeholder must not be passed to FileManager"
        )
        try expectEqual(
            CameraAppGroupIdentifier.resolve(configuredValue: "  "),
            nil,
            "an empty app-group setting must fall back safely"
        )
        try expectEqual(
            CameraAppGroupIdentifier.resolve(configuredValue: nil),
            nil,
            "a package without an app-group setting must fall back safely"
        )
        print("PASS Camera App Group runtime identifier")
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
        guard actual == expected else {
            throw SpecFailure(message: "\(message): expected \(expected), got \(actual)")
        }
    }
}

private struct SpecFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
