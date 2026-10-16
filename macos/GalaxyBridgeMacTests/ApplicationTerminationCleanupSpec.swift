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

        try await verifyHangingCleanupHasABoundedReply()
        try await verifySuccessfulCleanupCancelsItsDeadline()

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
        print("PASS application termination: normal drain, bounded uncooperative cleanup, late completion/deadline, exactly one reply")
    }

    @MainActor
    private static func verifyHangingCleanupHasABoundedReply() async throws {
        let deadline = UncooperativeGate()
        let cleanupRelease = UncooperativeGate()
        let events = MainEventRecorder()
        let coordinator = ApplicationTerminationCleanupCoordinator(waitForDeadline: { await deadline.wait() })
        guard coordinator.begin(cleanup: {
            events.values.append("cleanup-started")
            await cleanupRelease.wait() // Models filesystem/TCC work that ignores task cancellation.
            events.values.append("late-cleanup")
        }, reply: { events.values.append("reply") }) else {
            throw SpecFailure.message("first termination attempt must start")
        }
        try await waitUntil { await MainActor.run { events.values == ["cleanup-started"] } }
        await deadline.open()
        try await waitUntil { await MainActor.run { events.values == ["cleanup-started", "reply"] } }
        guard !coordinator.begin(cleanup: { events.values.append("restarted") }, reply: { events.values.append("duplicate") }) else {
            throw SpecFailure.message("deadline reply must not reopen termination admission")
        }
        await cleanupRelease.open()
        try await waitUntil { await MainActor.run { events.values.contains("late-cleanup") } }
        guard events.values == ["cleanup-started", "reply", "late-cleanup"] else {
            throw SpecFailure.message("late cleanup cannot reply a second time: \(events.values)")
        }
    }

    @MainActor
    private static func verifySuccessfulCleanupCancelsItsDeadline() async throws {
        let deadline = UncooperativeGate()
        let deadlineReturned = UncooperativeGate()
        let events = MainEventRecorder()
        let coordinator = ApplicationTerminationCleanupCoordinator(waitForDeadline: {
            await deadline.wait()
            await deadlineReturned.open()
        })
        coordinator.begin(cleanup: { events.values.append("cleanup") }, reply: { events.values.append("reply") })
        try await waitUntil { await MainActor.run { events.values == ["cleanup", "reply"] } }
        await deadline.open()
        await deadlineReturned.wait()
        // MainActor ordering settles the resumed late-deadline callback before reading.
        await Task.yield()
        guard events.values == ["cleanup", "reply"] else {
            throw SpecFailure.message("a cancelled late deadline cannot duplicate a successful reply")
        }
    }

    private static func waitUntil(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0 ..< 100 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SpecFailure.message("timed out waiting for termination cleanup")
    }
}

@MainActor
private final class MainEventRecorder {
    var values: [String] = []
}

private actor UncooperativeGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private actor EventRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
