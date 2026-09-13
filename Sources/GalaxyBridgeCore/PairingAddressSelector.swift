import Foundation

public struct PairingAddressCandidate: Equatable, Sendable {
    public let interfaceName: String
    public let address: String

    public init(interfaceName: String, address: String) {
        self.interfaceName = interfaceName
        self.address = address
    }
}

public enum PairingAddressSelector {
    public static func select(
        candidates: [PairingAddressCandidate],
        hostname: String?
    ) -> [String] {
        let ordered = candidates.compactMap { candidate -> RankedAddress? in
            guard isLANInterface(candidate.interfaceName),
                  let scope = scope(of: candidate.address)
            else { return nil }
            return RankedAddress(candidate: candidate, scope: scope)
        }.sorted { left, right in
            if left.scope != right.scope { return left.scope.rawValue < right.scope.rawValue }
            if left.candidate.interfaceName != right.candidate.interfaceName {
                return left.candidate.interfaceName < right.candidate.interfaceName
            }
            return left.candidate.address < right.candidate.address
        }

        var result: [String] = []
        var seen = Set<String>()
        for ranked in ordered where seen.insert(ranked.candidate.address).inserted {
            result.append(ranked.candidate.address)
            if result.count == PairingQRCode.maximumAddressCount { return result }
        }

        if let hostname = sanitized(hostname), seen.insert(hostname).inserted {
            result.append(hostname)
        }
        return Array(result.prefix(PairingQRCode.maximumAddressCount))
    }

    private enum AddressScope: Int {
        case privateIPv4
        case uniqueLocalIPv6
        case linkLocalIPv4
        case linkLocalIPv6
    }

    private struct RankedAddress {
        let candidate: PairingAddressCandidate
        let scope: AddressScope
    }

    private static func isLANInterface(_ name: String) -> Bool {
        guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else {
            return false
        }
        return name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    private static func scope(of address: String) -> AddressScope? {
        if let octets = ipv4Octets(address) {
            if octets[0] == 10 ||
                (octets[0] == 172 && (16 ... 31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168) {
                return .privateIPv4
            }
            if octets[0] == 169 && octets[1] == 254 {
                return .linkLocalIPv4
            }
            return nil
        }

        let unscoped = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        guard unscoped.contains(":"),
              let firstHextetText = unscoped.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first,
              let firstHextet = UInt16(firstHextetText, radix: 16)
        else { return nil }
        if firstHextet & 0xFE00 == 0xFC00 { return .uniqueLocalIPv6 }
        if firstHextet & 0xFFC0 == 0xFE80 { return .linkLocalIPv6 }
        return nil
    }

    private static func ipv4Octets(_ address: String) -> [Int]? {
        let components = address.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return nil }
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else { return nil }
        return octets
    }

    private static func sanitized(_ hostname: String?) -> String? {
        guard let hostname = hostname?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostname.isEmpty,
              hostname.utf8.count <= 255,
              hostname.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0)
              })
        else { return nil }
        return hostname
    }
}
