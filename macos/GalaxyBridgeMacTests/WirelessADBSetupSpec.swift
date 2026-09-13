import Foundation

@main
enum WirelessADBSetupSpec {
    static func main() throws {
        let services = WirelessADBService.parse("""
        List of discovered mdns services
        adb-s24-pair _adb-tls-pairing._tcp 192.168.42.126:37001
        adb-s24-connect _adb-tls-connect._tcp. 192.168.42.126:40009
        adb-fold _adb-tls-connect._tcp 192.168.42.40:39643
        unrelated _http._tcp 192.168.42.1:80
        hostile _adb-tls-pairing._tcp 8.8.8.8:5555
        broken _adb-tls-pairing._tcp 192.168.42.40:0
        injected _adb-tls-pairing._tcp 192.168.42.40:40000 extra
        adb-s24-pair _adb-tls-pairing._tcp 192.168.42.126:37001
        """)
        precondition(services.count == 3)
        precondition(services.filter { $0.kind == .pairing }.count == 1)
        precondition(services.first { $0.kind == .connection }?.endpoint == "192.168.42.126:40009")
        precondition(WirelessADBPairingCode("123456")?.value == "123456")
        for invalid in ["", "12345", "1234567", "１２３４５６", "12345\n", "12 345", "12345;", "123456\n"] {
            precondition(WirelessADBPairingCode(invalid) == nil, "Invalid code was accepted")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gb-pair-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("adb")
        // Assert the secret is NOT on argv and is read from stdin by the real runner.
        try """
        #!/bin/sh
        [ "$#" = 2 ] && [ "$1" = pair ] && [ "$2" = 192.168.42.126:37001 ] || exit 19
        read code
        if [ "$code" = 123456 ]; then
          printf 'Successfully paired to 192.168.42.126:37001 [guid=adb-s24]\n'
        else
          printf 'Failed: invalid pairing code %s\n' "$code"
          exit 1
        fi
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let client = try ADBClient(testingExecutableURL: fake)
        try client.pair(service: services[0], code: WirelessADBPairingCode("123456")!)
        do {
            try client.pair(service: services[0], code: WirelessADBPairingCode("000000")!)
            preconditionFailure("Rejected code incorrectly succeeded")
        } catch WirelessADBSetupError.pairingRejected { }
        do {
            try client.pair(service: services[1], code: WirelessADBPairingCode("123456")!)
            preconditionFailure("Connection port is not a pairing port")
        } catch WirelessADBSetupError.invalidService { }
        print("Wireless ADB discovery, strict codes, stdin secrecy and rejection checks passed")
    }
}
