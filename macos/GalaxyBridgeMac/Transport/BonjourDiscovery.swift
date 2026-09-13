import Combine
import Foundation
import Network
import OSLog

struct DiscoveredCompanion: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let endpointDescription: String
    let endpoint: NWEndpoint
    let identity: BonjourCompanionIdentity
}

@MainActor
final class BonjourDiscovery: ObservableObject {
    @Published private(set) var companions: [DiscoveredCompanion] = []
    @Published private(set) var errorDescription: String?

    private let browser = NWBrowser(
        for: .bonjourWithTXTRecord(type: "_galaxybridge._tcp", domain: nil),
        using: .tcp
    )
    private let logger = Logger(
        subsystem: "com.xopmc.GalaxyBridge",
        category: "BonjourDiscovery"
    )
    func start() {
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.logger.info("browser ready")
            case let .failed(error):
                self?.logger.error("browser failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in self?.errorDescription = error.localizedDescription }
            case .cancelled:
                self?.logger.info("browser cancelled")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let companions = results.compactMap(Self.companion(from:))
            self?.logger.info(
                "browser snapshot results=\(results.count, privacy: .public) valid=\(companions.count, privacy: .public)"
            )
            Task { @MainActor in
                self?.companions = companions.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: DispatchQueue(label: "com.xopmc.GalaxyBridge.bonjour"))
    }

    func stop() {
        browser.cancel()
    }

    nonisolated private static func companion(from result: NWBrowser.Result) -> DiscoveredCompanion? {
        guard case let .service(name, type, domain, interface) = result.endpoint else { return nil }
        let entries: [String: String]
        if case let .bonjour(txtRecord) = result.metadata {
            entries = ["id", "pkfp", "v", "name"].reduce(into: [:]) { parsed, key in
                if let value = txtRecord[key] { parsed[key] = value }
            }
        } else {
            entries = [:]
        }
        let advertisement = BonjourAdvertisementParser.parse(entries: entries)
        let endpoint = [name, type, domain, interface?.name].compactMap { $0 }.joined(separator: " ")
        return DiscoveredCompanion(
            id: "\(name).\(type).\(domain)",
            name: BonjourAdvertisementParser.displayName(
                txtName: advertisement.displayName,
                serviceName: name
            ),
            endpointDescription: endpoint,
            endpoint: result.endpoint,
            identity: advertisement.identity
        )
    }
}
