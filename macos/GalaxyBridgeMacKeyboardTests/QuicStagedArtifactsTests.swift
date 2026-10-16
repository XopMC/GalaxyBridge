#if !GALAXYBRIDGE_APP_STORE
import Foundation
import GalaxyBridgeCore
import Testing
@testable import GalaxyBridgeMac

@Suite(.serialized)
struct QuicStagedArtifactsTests {
    @Test func removalAcceptsOnlyOneMatchingOwnedPair() throws {
        let helper = "/data/local/tmp/gb-quic-abcdef-18446744073709551615-backend"
        let producer = "/data/local/tmp/gb-quic-abcdef-18446744073709551615-producer.jar"
        #expect(try ADBClient.quicArtifactRemovalArguments(helperPath: helper, producerPath: producer)
            == ["rm", "-f", "--", helper, producer])
        for (invalidHelper, invalidProducer) in [
            (helper, "/data/local/tmp/gb-quic-abcdef-2-producer.jar"),
            (helper + ";id", producer),
            (helper.replacingOccurrences(of: "abcdef", with: "*"), producer),
            (helper.replacingOccurrences(of: "abcdef", with: "../abcdef"), producer),
            (helper.replacingOccurrences(of: "abcdef", with: "0"), producer),
            (helper.replacingOccurrences(of: "18446744073709551615", with: "18446744073709551616"), producer),
        ] {
            #expect(throws: ADBClientError.self) {
                try ADBClient.quicArtifactRemovalArguments(helperPath: invalidHelper, producerPath: invalidProducer)
            }
        }
    }

    @Test(arguments: ["helper", "producer", "chmod", "address", "success"])
    func stagingRollbackAndOwnershipTransferAreExact(stage: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gb-quic-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("adb"), log = directory.appendingPathComponent("commands")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let contents = """
        #!/bin/sh
        printf '%s\\n' "$*" >> \(quote(log.path))
        if [ "$3" = 'push' ]; then
          case "$6" in
            *-backend) [ \(quote(stage)) != 'helper' ] ;;
            *-producer.jar) [ \(quote(stage)) != 'producer' ] ;;
            *) exit 64 ;;
          esac
          exit $?
        fi
        case "$4" in
          *"'chmod'"*) [ \(quote(stage)) != 'chmod' ]; exit $? ;;
          *"'ip'"*)
            [ \(quote(stage)) != 'address' ] || exit 23
            printf '%s\\n' '1: wlan0 inet 192.168.1.7/24 scope global wlan0'
            exit 0 ;;
          *"'rm'"*) exit 0 ;;
        esac
        exit 64
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let adb = try ADBClient(testingExecutableURL: script)
        func stageLaunch() throws -> QuicBackendBridge.Launch {
            try QuicRuntimeArtifacts.stageVerifiedArtifacts(adb: adb, serial: "fixture-selected",
                configuration: .init(scid: 0xabc), selection: .init(targetToken: 9), generation: 77,
                helper: directory.appendingPathComponent("helper"), producer: directory.appendingPathComponent("producer"))
        }
        if stage == "success" {
            let launch = try stageLaunch()
            #expect(!(try String(contentsOf: log, encoding: .utf8)).contains("'rm'"), "successful staging transfers ownership without unlinking live files")
            let cleanup = try #require(launch.cleanupStagedArtifacts)
            try await cleanup()
        } else {
            #expect(throws: ADBClientError.self) { try stageLaunch() }
        }
        let commands = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        let removals = commands.filter { $0.contains("'rm'") }
        #expect(commands.filter { $0.contains(" push -q ") }.count == (stage == "helper" ? 1 : 2))
        #expect(commands.contains { $0.contains("'chmod'") } == !["helper", "producer"].contains(stage))
        #expect(commands.contains { $0.contains("'ip'") } == ["address", "success"].contains(stage))
        #expect(removals == ["-s fixture-selected shell 'rm' '-f' '--' '/data/local/tmp/gb-quic-abc-77-backend' '/data/local/tmp/gb-quic-abc-77-producer.jar'"])
        #expect(commands.allSatisfy { !$0.contains("*") && !$0.contains("rm -rf") })
    }
}
#endif
