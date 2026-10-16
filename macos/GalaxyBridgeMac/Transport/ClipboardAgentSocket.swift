#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeEnhancedCore
import Network

final class ClipboardAgentSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.clipboard-agent.\(UUID().uuidString)")
    private let readyHandler: @Sendable (Bool) -> Void
    private let messageHandler: @Sendable (ScrcpyClipboardAgentMessage) -> Void
    private let failureHandler: @Sendable (Error) -> Void
    private var decoder = ScrcpyClipboardAgentDecoder()

    init(
        port: UInt16,
        readyHandler: @escaping @Sendable (Bool) -> Void,
        messageHandler: @escaping @Sendable (ScrcpyClipboardAgentMessage) -> Void,
        failureHandler: @escaping @Sendable (Error) -> Void
    ) {
        connection = NWConnection(
            host: .ipv4(IPv4Address.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: ScrcpyTCPParameters.make()
        )
        self.readyHandler = readyHandler
        self.messageHandler = messageHandler
        self.failureHandler = failureHandler
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                receive()
            case let .failed(error): failureHandler(error)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() { connection.cancel() }

    func setText(_ value: String, changeID: String) -> Bool {
        guard let frame = ScrcpyClipboardAgentMessage.textCommand(value, changeID: changeID) else { return false }
        queue.async { [weak self] in
            guard let self else { return }
            self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if let error { self?.failureHandler(error) }
            })
        }
        return true
    }

    private func consume(_ data: Data) throws {
        let waitingForPreamble = decoder.supportsOccurrences == nil
        let messages = try decoder.append(data)
        if waitingForPreamble, let supportsOccurrences = decoder.supportsOccurrences {
            readyHandler(supportsOccurrences)
        }
        for message in messages { messageHandler(message) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            do {
                if let data {
                    try consume(data)
                }
                if let error { throw error }
                if complete { throw ScrcpyControlSocketError.closed }
                receive()
            } catch {
                failureHandler(error)
                connection.cancel()
            }
        }
    }
}
#endif
