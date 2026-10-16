import Foundation

enum ShellCapabilityBridgeActivationTarget: Sendable {
    case production, internalBuild
    static func resolve(bundleIdentifier: String?) -> Self? {
        switch bundleIdentifier {
        case "com.xopmc.GalaxyBridge": .production
        case "com.xopmc.GalaxyBridge.internal": .internalBuild
        default: nil
        }
    }
    var packageName: String { self == .production ? "com.xopmc.galaxybridge" : "com.xopmc.galaxybridge.internal" }
    var runtimeMode: String { self == .production ? "production" : "internal" }
}

struct ShellCapabilityBridgeActivationReceipt: Decodable {
    let available: Bool
    let bootGeneration: String
    let state: String
    let errorCode: String
    enum CodingKeys: String, CodingKey {
        case available, state
        case bootGeneration = "boot_generation", errorCode = "error_code"
    }
    static func parse(_ output: String, generation: String) -> Self? {
        guard output.utf8.count <= 65_536, UUID(uuidString: generation)?.uuidString.lowercased() == generation,
              let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let receipt = try? JSONDecoder().decode(Self.self, from: Data(output[start...end].utf8)),
              receipt.bootGeneration == generation else { return nil }
        return receipt
    }
}
