import Foundation
import Network

struct AdmissionPeer { let deviceID: String }
@MainActor final class PairedInternetRelay {
    let peer: AdmissionPeer
    let endpoint: NWEndpoint
    let username = String(repeating: "a", count: 64), password = String(repeating: "b", count: 64)
    var localPort: UInt16?
    var activeFlowCount = 0
    var stopped = false
    init(_ id: String, address: String, port: UInt16) {
        peer = AdmissionPeer(deviceID: id)
        endpoint = .hostPort(host: .ipv4(IPv4Address(address)!), port: 443)
        localPort = port
    }
    func start() async throws -> UInt16 { guard let localPort, !stopped else { throw URLError(.cancelled) }; return localPort }
    func stop() { stopped = true; localPort = nil }
}
@MainActor final class PairedDNSRelay {
    init(selectGateway: @escaping (Set<String>) -> PairedInternetRelay?) {}
    func start() async throws -> UInt16 { 43120 }
    func setHealthyPeers(_ ids: Set<String>) {}
    func stop() {}
}

@main enum InternetTunnelAdmissionSpec {
    @MainActor static func main() async throws {
        do {
            gb_fixture_reject_admission(0)
            let driver = InternetTunnelDriver()
            let a = PairedInternetRelay("A", address: "192.0.2.1", port: 43121)
            let b = PairedInternetRelay("B", address: "192.0.2.2", port: 43122)
            try await driver.start(gatewayRelays: [a], userApproved: true)
            precondition(gb_gateway_flow_port(101, 1) == 43121)
            gb_fixture_reject_admission(1)
            do {
                try await driver.start(gatewayRelays: [a, b], userApproved: true)
                preconditionFailure("Off-link B was admitted")
            } catch let rejection as InternetTunnelAdmissionRejection {
                precondition(rejection.retainedRelays == [ObjectIdentifier(a)], "Receipt must identify only the exact established relay")
            }
            precondition(gb_fixture_update_count() == 2 && gb_fixture_last_gateway() == 1,
                "Rejected admission must revalidate the exact old helper topology")
            precondition(driver.hasActiveTopology && driver.gatewayDeviceIDs == ["A", nil] && !a.stopped)
            precondition(gb_gateway_flow_port(101, 1) == 43121, "Rejected B must not break A's established flow")
            gb_gateway_flow_release(101)
            gb_fixture_reject_admission(0)
            try await driver.start(gatewayRelays: [a, b], userApproved: true)
            driver.updatePolicy(.balanced); driver.setHealthyPeers(["A", "B"])
            precondition(gb_gateway_flow_port(201, 1) == 43121 && gb_gateway_flow_port(202, 1) == 43122)
            driver.updatePolicy(.fixed(0)); driver.setHealthyPeers([])
            try await driver.start(gatewayRelays: [b], userApproved: true)
            precondition(!b.stopped && gb_gateway_flow_port(202, 1) == 43122,
                "A fixed unavailable peer must leave B's established native flow pinned to its live relay")
            precondition(gb_gateway_flow_port(203, 1) == 0, "Fixed unavailable A must not admit a new flow on B")
            gb_gateway_flow_release(201); gb_gateway_flow_release(202)
            await driver.stop()
        }
        for failure in [2, 3, 4] {
            gb_fixture_reject_admission(0)
            let driver = InternetTunnelDriver()
            let a = PairedInternetRelay("A", address: "192.0.2.1", port: 43121)
            let b = PairedInternetRelay("B", address: "192.0.2.2", port: 43122)
            try await driver.start(gatewayRelays: [a], userApproved: true)
            gb_fixture_reject_admission(Int32(failure))
            do {
                try await driver.start(gatewayRelays: [a, b], userApproved: true)
                preconditionFailure("Failed admission succeeded")
            } catch is InternetTunnelAdmissionRejection {
                preconditionFailure("A destroyed or unverified helper lease must never issue a preservation receipt")
            } catch {}
            if failure == 4 {
                precondition(!driver.hasActiveTopology && a.stopped, "A real worker exit must retire the old topology")
            }
            await driver.stop()
        }
        print("PASS actual internet driver/native pool: exact-relay admission rollback, helper ownership revalidation, destructive/unverified rejection fails closed, established-flow retention and closed new-flow policy; inert helper/worker boundaries")
    }
}
