#if !GALAXYBRIDGE_APP_STORE
import Darwin
import Foundation

/// An explicit cancellation channel bridges detached Swift tasks to their child.
final class ADBProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Tracks only processes created by this runtime. It never installs or replaces
/// Process.terminationHandler, which scrcpy display identity owns separately.
final class ADBProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var processes: [UUID: Process] = [:]
    func start(_ process: Process) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { throw CancellationError() }
        let token = UUID()
        try process.run()
        processes[token] = process
        return token
    }
    func finished(_ token: UUID) { lock.lock(); processes.removeValue(forKey: token); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return processes.count }
    func drainAndCancel(timeout: TimeInterval) {
        lock.lock(); accepting = false; lock.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while count > 0, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
        lock.lock(); let children = Array(processes.values); lock.unlock()
        for process in children { Self.stopAndReap(process) }
    }
    static func stopAndReap(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        // SIGKILL cannot be ignored; wait only on this exact child after forcing
        // exit, never on a persisted PID or an unrelated adb daemon.
        process.waitUntilExit()
    }
}

/// Blocking process boundary: invoke from a worker task, never from UI work.
/// Both pipes are drained while the child runs; retained output and elapsed time
/// are bounded. A descendant holding a pipe open cannot extend the deadline.
struct ADBCommandRunner: Sendable {
    enum Failure: Error, Equatable {
        case timedOut
        case outputLimitExceeded
        case invalidLimits
        case pipeReadFailed(Int32)
    }

    struct Result: Sendable {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    let executableURL: URL
    var environment: [String: String]? = nil
    var argumentPrefix: [String] = []
    var processRegistry: ADBProcessRegistry? = nil
    var cancellation: ADBProcessCancellation? = nil

    func run(
        arguments: [String],
        input: Data = Data(),
        timeout: TimeInterval = 10,
        outputLimit: Int = 4 * 1024 * 1024
    ) throws -> Result {
        guard timeout.isFinite, timeout > 0, outputLimit > 0, input.count <= 4096 else {
            throw Failure.invalidLimits
        }
        let process = Process()
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.executableURL = executableURL
        if let environment { process.environment = environment }
        process.arguments = argumentPrefix + arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
        let descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw Failure.pipeReadFailed(errno)
            }
        }
        // Suppress SIGPIPE for this descriptor only if a command rejects stdin.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw Failure.pipeReadFailed(errno)
        }
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            try? stdin.fileHandleForWriting.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        if cancellation?.isCancelled == true { throw CancellationError() }
        let token: UUID?
        if let processRegistry { token = try processRegistry.start(process) }
        else { try process.run(); token = nil }
        defer {
            ADBProcessRegistry.stopAndReap(process)
            if let token { processRegistry?.finished(token) }
        }
        if !input.isEmpty { try stdin.fileHandleForWriting.write(contentsOf: input) }
        try stdin.fileHandleForWriting.close()
        var captured = [Data(), Data()]
        var retained = 0
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            if cancellation?.isCancelled == true { throw CancellationError() }
            let wasRunning = process.isRunning
            // Fair, finite reads on each descriptor even if one floods forever.
            for index in descriptors.indices {
                for _ in 0..<16 {
                    let count = Darwin.read(descriptors[index], &buffer, buffer.count)
                    if count > 0 {
                        guard count <= outputLimit - retained else { throw Failure.outputLimitExceeded }
                        captured[index].append(contentsOf: buffer.prefix(count))
                        retained += count
                    } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else if errno != EINTR {
                        throw Failure.pipeReadFailed(errno)
                    }
                }
            }
            // Child exit closes its writing ends; one final read pass follows
            // the observed exit. Do not wait for EOF from unrelated descendants.
            if !wasRunning { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return Result(stdout: captured[0], stderr: captured[1], exitCode: process.terminationStatus)
    }
}
#endif
