import Foundation

private enum SpecFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message): message
        }
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw SpecFailure.message("\(message): expected \(expected), got \(actual)")
    }
}

@main
private enum EnhancedSessionDiagnosticsSpec {
    static func main() throws {
        var diagnostics = EnhancedSessionDiagnostics()

        let failure = "H.264 fallback: adb is unavailable"
        try expectEqual(
            diagnostics.transition(deviceID: "phone", state: .failed(failure), currentDiagnostic: nil),
            failure,
            "an enhanced failure must be presented"
        )
        try expectEqual(
            diagnostics.transition(deviceID: "phone", state: .streaming("h265"), currentDiagnostic: failure),
            nil,
            "successful streaming must clear its own stale failure"
        )

        let unrelated = "Camera permission was denied"
        _ = diagnostics.transition(deviceID: "phone", state: .failed(failure), currentDiagnostic: nil)
        try expectEqual(
            diagnostics.transition(deviceID: "phone", state: .streaming("h265"), currentDiagnostic: unrelated),
            unrelated,
            "enhanced recovery must not erase an unrelated diagnostic"
        )

        _ = diagnostics.transition(deviceID: "old", state: .failed(failure), currentDiagnostic: nil)
        diagnostics.migrate(from: "old", to: "new")
        try expectEqual(
            diagnostics.transition(deviceID: "new", state: .streaming("h265"), currentDiagnostic: failure),
            nil,
            "logical device migration must preserve recovery ownership"
        )

        print("PASS enhanced session diagnostics clear only after their transport recovers")
    }
}
