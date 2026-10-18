import Foundation
import Network

enum CompanionConnectionState: Equatable, Sendable {
    case connecting, connected, failed(String), transportInterrupted(String), authenticationRejected(String), disconnected
}
enum GBChannelKind { case control, events, files, audio, video, camera, internetProxy, enhancedStream }
struct GBOpenChannel { var kind: GBChannelKind = .control; var streamID = ""; var codec = "" }
enum Capability { case notificationActionResults, featureConfiguration, nearbyLink, internetGateway, privilegedBridge, captureRetirementProof, shellRuntimeIdentity, compositeDisplayState }
struct CapabilityUpdate { var available: [Capability] = []; var unavailableReasons: [String: String] = [:] }
struct CompanionConnectivityCapabilities {
    init(negotiated: Bool = false, nearbyLink: Bool = false, internetGateway: Bool = false, privilegedBridge: Bool = false,
        captureRetirementProof: Bool = false, shellRuntimeIdentity: Bool = false, compositeDisplayState: Bool = false,
        unavailableReasons: [String: String] = [:]) {}
}
struct RemoteError { var code = "" }
struct Pong { var echoedMonotonicTimeNs: UInt64 = 0 }
struct InternetStatus { var enabled = false; var leaseID = "" }
struct ShellResult { var available = false; var state = ""; var streamIds: [String] = [] }
struct GBEnvelope {
    enum Payload { case hello, error(RemoteError), pong(Pong), capabilityUpdate(CapabilityUpdate), internetSharingStatus(InternetStatus), shellBridgeResult(ShellResult), openChannel(GBOpenChannel) }
    var payload: Payload?; var protocolMajor = 0; var protocolMinor = 0; var deviceID = ""; var sessionID = ""; var messageID: UInt64 = 0
    var openChannel: GBOpenChannel { get { .init() } set { payload = .openChannel(newValue) } }
}
enum CompanionAuthenticationRejection { static func message(for code: String) -> String? { nil } }
struct Heartbeat { func receivePong(_ token: UInt64, now: Double) -> Double? { nil } }
final class Connection: @unchecked Sendable {
    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var currentPath: NWPath? { nil }
    var cancellations = 0
    func start(queue: DispatchQueue) {}
    func cancel() { cancellations += 1 }
}
struct Diagnostics {
    func connectionStarted() {}; func networkReady() {}; func authenticationPrepared() {}
    func authenticationPreparationFailed(_ error: Error) {}; func pathWaiting(_ error: NWError) {}
    func networkFailed(_ error: NWError) {}; func helloReceived() {}; func openChannelRequested() {}
    func sendFailed(_ error: Error) {}; func recordMatchedPong(roundTripMilliseconds: Double) {}
}
enum CompanionNetworkFailure { static func message(unsatisfiedReason: NWPath.UnsatisfiedReason?) -> String { "network waiting" } }
final class States: @unchecked Sendable {
    private let lock = NSLock(); private var states: [CompanionConnectionState] = []
    func append(_ state: CompanionConnectionState) { lock.lock(); defer { lock.unlock() }; states.append(state) }
    var values: [CompanionConnectionState] { lock.lock(); defer { lock.unlock() }; return states }
}
final class CompanionTLSClient: @unchecked Sendable {
    let diagnostics = Diagnostics(); let connection = Connection(); let queue = DispatchQueue(label: "gb-transport-test")
    var receivedHello = false; var deliveredTerminalAuthenticationFailure = false
    var deliveredTerminalTransportFailure = false; var heartbeatTimer: DispatchSourceTimer?
    let stateHandler: @Sendable (CompanionConnectionState) -> Void
    var channelKind: GBChannelKind = .control; var channelOpened = false
    let notificationActionCapabilityLock = NSLock(); var notificationActionResultsSupported = false
    var featureConfigurationSupported = false; var connectivityCapabilitiesState = CompanionConnectivityCapabilities()
    var rawStreamID: String?; var rawCodec: String?; var rawDataHandler: ((Data)->Void)?; var rawReady = false
    var rawReadyHandler: ()->Void = {}; var envelopeHandler: (GBEnvelope, Int)->Void = { _, _ in }
    let heartbeat = Heartbeat(); let hostID = "host"; let sessionID = "session"
    var sentKinds: [GBChannelKind] = []
    func startHeartbeat() {}; func nextMessageID() -> UInt64 { 1 }
    func send(_ envelope: GBEnvelope) throws { if case let .openChannel(request)? = envelope.payload { sentKinds.append(request.kind) } }
    init(_ sink: States) { stateHandler = { sink.append($0) } }
    func sendAuthentication() throws {}; func receive() {}
    // ACTUAL_TRANSPORT_ENTRY_POINTS
}
@main enum CompanionTransportInterruptionSpec {
    static func main() {
        let states = States(), client = CompanionTLSClient(States())
        let authenticated = CompanionTLSClient(states)
        authenticated.receivedHello = true
        authenticated.start()
        authenticated.connection.stateUpdateHandler?(.failed(.posix(.ETIMEDOUT)))
        precondition(states.values.count == 2, "Missing network failure callback")
        guard case .transportInterrupted = states.values[1] else {
            fatalError("Authenticated network failure was not distinguishable from a protocol failure")
        }
        authenticated.connection.stateUpdateHandler?(.cancelled)
        authenticated.connection.stateUpdateHandler?(.failed(.posix(.ECONNRESET)))
        precondition(states.values.count == 2, "Terminal network failure emitted a second session-retiring callback")
        let unauthStates = States(), unauth = CompanionTLSClient(unauthStates)
        unauth.start(); unauth.connection.stateUpdateHandler?(.failed(.tls(-9807)))
        guard case .failed = unauthStates.values.last! else { fatalError("Pre-authentication TLS failure was downgraded to auxiliary retry") }
        let rejectedStates = States(), rejected = CompanionTLSClient(rejectedStates)
        rejected.receivedHello = true; rejected.deliveredTerminalAuthenticationFailure = true
        rejected.start(); rejected.connection.stateUpdateHandler?(.failed(.posix(.ECONNRESET)))
        precondition(rejectedStates.values == [.connecting], "Network teardown masked terminal authentication rejection")
        let filesStates = States(), files = CompanionTLSClient(filesStates)
        files.channelKind = .files
        _ = files.handleControlEnvelope(GBEnvelope(payload: .hello), frameCount: 1)
        precondition(filesStates.values.isEmpty, "Files readiness fired on Hello before OpenChannel; pending manifest could claim CONTROL")
        _ = files.handleControlEnvelope(GBEnvelope(payload: .capabilityUpdate(.init())), frameCount: 1)
        precondition(files.sentKinds == [.files] && filesStates.values == [.connected],
            "Files readiness did not follow its OpenChannel send")
        _ = files.handleControlEnvelope(GBEnvelope(payload: .capabilityUpdate(.init())), frameCount: 1)
        precondition(files.sentKinds.count == 1 && filesStates.values.count == 1, "Duplicate capabilities repeated channel readiness")
        let controlStates = States(), control = CompanionTLSClient(controlStates)
        _ = control.handleControlEnvelope(GBEnvelope(payload: .hello), frameCount: 1)
        precondition(controlStates.values == [.connected] && control.sentKinds.isEmpty,
            "Control authentication no longer became ready on Hello")
        _ = client
        print("PASS actual TLS network state callbacks: post-Hello interruption, terminal deduplication, pre-auth TLS conservative failure, authentication rejection preserved")
    }
}
