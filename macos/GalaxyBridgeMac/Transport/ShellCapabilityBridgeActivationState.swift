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
              output.split(whereSeparator: \.isNewline).filter({ $0.hasPrefix("Broadcast completed:") }).count == 1,
              let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Broadcast completed:") }) else { return nil }
        // am prints an Intent { ... } banner before the receipt. Only the
        // successful completion line carries the receiver's JSON result.
        let prefix = "Broadcast completed: result=0, data=\""
        guard line.hasPrefix(prefix), line.hasSuffix("\""),
              let receipt = try? JSONDecoder().decode(Self.self, from: Data(line.dropFirst(prefix.count).dropLast().utf8)),
              receipt.bootGeneration == generation else { return nil }
        return receipt
    }
}
