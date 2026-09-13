import Foundation

private enum SpecFailure: Error {
    case message(String)
}

@main
private enum ApplicationTerminationCleanupSpec {
    static func main() async throws {
        var admission = ApplicationTerminationAdmission()
        guard admission.admitsWork, admission.begin(), !admission.admitsWork,
              !admission.begin()
        else {
            throw SpecFailure.message("termination admission must close exactly once")
        }

        let coordinator = await MainActor.run { ApplicationTerminationCleanupCoordinator() }
        let recorder = EventRecorder()

        let firstStarted = await MainActor.run {
            coordinator.begin(
                cleanup: {
                    await recorder.append("cleanup")
                },
                reply: {
                    Task { await recorder.append("reply") }
                }
            )
        }
        let duplicateStarted = await MainActor.run {
            coordinator.begin(
                cleanup: {
                    await recorder.append("duplicate-cleanup")
                },
                reply: {
                    Task { await recorder.append("duplicate-reply") }
                }
            )
        }

        guard firstStarted, !duplicateStarted else {
            throw SpecFailure.message("termination cleanup must start exactly once")
        }
        try await waitUntil { await recorder.values.count == 2 }
        let values = await recorder.values
        guard values == ["cleanup", "reply"] else {
            throw SpecFailure.message("termination must reply only after cleanup: \(values)")
        }

        guard CommandLine.arguments.count == 2 else {
            throw SpecFailure.message("expected the workspace root for app-lifetime wiring verification")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let appSourceURL = root.appendingPathComponent("macos/GalaxyBridgeMac/GalaxyBridgeMacApp.swift")
        let appSource = try String(contentsOf: appSourceURL, encoding: .utf8)
        guard appSource.contains("installCleanupHandler { [model, applicationWindows] in"),
              !appSource.contains("installCleanupHandler { [weak model, weak applicationWindows] in")
        else {
            throw SpecFailure.message("termination handler must retain cleanup owners until AppKit replies")
        }
        print("PASS application termination waits for device cleanup exactly once")
    }

    private static func waitUntil(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0 ..< 100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SpecFailure.message("timed out waiting for termination cleanup")
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
