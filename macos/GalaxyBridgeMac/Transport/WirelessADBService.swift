#if !GALAXYBRIDGE_APP_STORE
import Foundation

struct WirelessADBService: Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Sendable { case pairing, connection }
    let name: String
    let kind: Kind
    let endpoint: String
    var id: String { "\(name)|\(kind.rawValue)|\(endpoint)" }
    var host: String { String(endpoint.split(separator: ":")[0]) }

    /// Discovery only locates a service. It is never evidence of Companion trust.
    static func parse(_ output: String) -> [Self] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, WirelessADBReconnectPolicy.isLocalEndpoint(fields[2]) else { return nil }
            let kind: Kind
            switch fields[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
            case "_adb-tls-pairing._tcp": kind = .pairing
            case "_adb-tls-connect._tcp": kind = .connection
            default: return nil
            }
            let service = Self(name: fields[0], kind: kind, endpoint: fields[2])
            return seen.insert(service.id).inserted ? service : nil
        }
    }

    /// Converts the one resolved Bonjour service reported by `dns-sd -L` into
    /// the same strictly validated endpoint format used by ADB commands.
    static func parseBonjourResolution(name: String, kind: Kind, output: String) -> Self? {
        let pattern = #"can be reached at\s+([^\s:]+):(\d+)"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(
            in: output, range: NSRange(output.startIndex..., in: output)
        ), let hostRange = Range(match.range(at: 1), in: output),
              let portRange = Range(match.range(at: 2), in: output),
              let port = UInt16(output[portRange]), port > 0 else { return nil }
        let endpoint = "\(output[hostRange]):\(port)"
        guard WirelessADBReconnectPolicy.isLocalEndpoint(endpoint) else { return nil }
        return Self(name: name, kind: kind, endpoint: endpoint)
    }
}

struct WirelessADBPairingCode: Sendable {
    let value: String
    init?(_ value: String) {
        guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        self.value = value
    }
}

enum WirelessADBSetupError: Error, LocalizedError {
    case invalidService, pairingRejected, connectionNotReady
    var errorDescription: String? {
        switch self {
        case .invalidService: String(localized: "WIFI_SETUP_REFRESH_CODE")
        case .pairingRejected: String(localized: "WIFI_SETUP_CODE_REJECTED")
        case .connectionNotReady: String(localized: "WIFI_SETUP_CONNECT_RETRY")
        }
    }
}

extension ADBClient {
    func wirelessServices() throws -> [WirelessADBService] {
        WirelessADBService.parse(try mdnsServices())
    }

    func pair(service: WirelessADBService, code: WirelessADBPairingCode, cancellation: ADBProcessCancellation? = nil) throws {
        guard service.kind == .pairing, WirelessADBReconnectPolicy.isLocalEndpoint(service.endpoint) else {
            throw WirelessADBSetupError.invalidService
        }
        // ADB supports reading a pairing code from stdin. Never place the code
        // in argv, persisted settings or a propagated process-error message.
        do {
            let result = try runCommand(
                arguments: ["pair", service.endpoint], input: Data((code.value + "\n").utf8),
                timeout: 15, outputLimit: 16_384, cancellation: cancellation
            )
            guard result.exitCode == 0,
                  String(decoding: result.stdout, as: UTF8.self).contains("Successfully paired to \(service.endpoint)")
            else { throw WirelessADBSetupError.pairingRejected }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Even a hostile or broken peer may echo the secret. Expose only
            // this content-free recovery instruction to UI and diagnostics.
            throw WirelessADBSetupError.pairingRejected
        }
    }
}
#endif
