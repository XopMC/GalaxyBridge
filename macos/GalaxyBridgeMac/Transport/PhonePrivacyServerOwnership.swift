#if !GALAXYBRIDGE_APP_STORE
import Foundation

struct PhonePrivacyServerOwnership {
    let resourceID: String
    let remoteJarPath: String
    init(identifier: UUID = UUID()) {
        resourceID = identifier.uuidString.lowercased()
        remoteJarPath = "/data/local/tmp/galaxybridge-privacy-\(resourceID).jar"
    }

    func serverArguments(replacingSharedClasspath arguments: [String], cleanupEnabled: Bool = true) throws -> [String] {
        guard arguments.filter({ $0.hasPrefix("CLASSPATH=") }).count == 1,
              arguments.filter({ $0.hasPrefix("cleanup=") }) == ["cleanup=\(cleanupEnabled ? "true" : "false")"], arguments.contains("video=false"),
              arguments.contains("audio=false"), arguments.contains("power_on=false"),
              !arguments.contains(where: { $0.hasPrefix("new_display=") })
        else { throw OwnershipError.invalidLaunch }
        return arguments.map { $0.hasPrefix("CLASSPATH=") ? "CLASSPATH=\(remoteJarPath)" : $0 }
    }

    static func cleanupChildren(_ output: String, parentPID: Int32) -> [Int32] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int32(fields[0]), pid > 1,
                  Int32(fields[1]) == parentPID,
                  fields.contains("com.genymobile.scrcpy.CleanUp") else { return nil }
            return pid
        }
    }

    static func cleanupChildren(_ output: String, parentPIDs: [Int32]) -> [Int32] {
        // The shell wrapper retains the same server class and SCID in ARGS.
        // Retirement intentionally matches both; discovery follows each
        // candidate's direct children and deduplicates the actual cleanup PID.
        Set(parentPIDs.flatMap { cleanupChildren(output, parentPID: $0) }).sorted()
    }

    enum ForwardState: Equatable { case absent, owned, unrelated, unavailable }

    static func requiresRouteSettlement(current: String, requested: String, controlReady: Bool) -> Bool {
        current != requested || !controlReady
    }

    static func forwardState(_ output: String, serial: String, port: UInt16, socketName: String) -> ForwardState {
        let local = "tcp:\(port)"
        var matches: [[Substring]] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.contains(Substring(local)) else { continue }
            guard fields.count == 3, fields[1] == Substring(local) else { return .unavailable }
            matches.append(fields)
        }
        guard !matches.isEmpty else { return .absent }
        guard matches.count == 1, matches[0][0] == Substring(serial),
              matches[0][2] == Substring("localabstract:\(socketName)") else { return .unrelated }
        return .owned
    }

    enum OwnershipError: Error { case invalidLaunch }
}

struct PhonePrivacyCleanupIdentity: Equatable, Sendable {
    let pid: Int32
    let startTime: UInt64

    static func parseStat(_ stat: String) -> PhonePrivacyCleanupIdentity? {
        guard let close = stat.lastIndex(of: ")"),
              let pid = stat.split(separator: " ").first.flatMap({ Int32($0) }), pid > 1 else { return nil }
        let fields = stat[stat.index(after: close)...].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 20, let started = UInt64(fields[19]) else { return nil }
        return .init(pid: pid, startTime: started)
    }
}

enum PhonePrivacyCleanupProbe: Equatable {
    case gone
    case unavailable
    case process(PhonePrivacyCleanupIdentity, owned: Bool, zombie: Bool)

    static func parse(_ output: String) -> PhonePrivacyCleanupProbe {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first == "GONE" { return .gone }
        guard lines.count >= 3, let identity = PhonePrivacyCleanupIdentity.parseStat(lines[2]) else { return .unavailable }
        let exactCleanupClass = lines[1].split(whereSeparator: \.isWhitespace).contains("com.genymobile.scrcpy.CleanUp")
        let statSuffix = lines[2].lastIndex(of: ")").map { lines[2][lines[2].index(after: $0)...] }
        let zombie = statSuffix?.split(whereSeparator: \.isWhitespace).first == "Z"
        return .process(identity, owned: lines[0] == "OWNED" && exactCleanupClass, zombie: zombie)
    }

    func settled(expected: PhonePrivacyCleanupIdentity) throws -> Bool {
        switch self {
        case .gone: return true
        case .unavailable: throw ProbeError.identityUnavailable
        case let .process(observed, owned, zombie):
            guard observed.pid == expected.pid else { throw ProbeError.identityUnavailable }
            if observed.startTime != expected.startTime { return true } // PID reused; never signal it.
            if zombie { return true }
            guard owned else { throw ProbeError.identityUnavailable }
            return false
        }
    }
    enum ProbeError: Error { case identityUnavailable }
}
#endif
