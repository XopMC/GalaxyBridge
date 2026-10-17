#if !GALAXYBRIDGE_APP_STORE
import Darwin
import Foundation

/// One bounded command/acknowledgement at a time. Blocking pipe I/O stays off
/// MainActor; a timeout retains the owner so its EOF restoration can settle.
final class DisplayPowerControllerProcess: @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let queue = DispatchQueue(label: "com.xopmc.GalaxyBridge.panel-controller")
    private var inputClosed = false
    private var outputClosed = false
    private var poisoned = false
    private var receivedValidHeader = false
    private var mutationMayHaveApplied = false
    private var knownStartupFailure = false
    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process; self.input = input; self.output = output
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    func exchange(_ command: UInt8?, timeout: TimeInterval = 8) async throws -> DisplayPowerControllerAcknowledgement {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if var command {
                        guard !poisoned, !inputClosed, process.isRunning else { throw ProcessError.controllerEOF }
                        if command <= 2 { mutationMayHaveApplied = true }
                        guard Darwin.write(input.fileDescriptor, &command, 1) == 1 else { throw ProcessError.controllerWriteFailed }
                    }
                    let line = try readLine(timeout: timeout)
                    let acknowledgement = try DisplayPowerControllerAcknowledgement.decode(line)
                    receivedValidHeader = true
                    continuation.resume(returning: acknowledgement)
                } catch {
                    if command == nil, !receivedValidHeader, !mutationMayHaveApplied,
                       error is DisplayPowerControllerAcknowledgement.StartupFailure {
                        knownStartupFailure = true
                    }
                    poisoned = true; continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Called only after independent same-phone PID/start and restoration proof.
    /// A lost USB shell exit code is then a transport failure, not panel evidence.
    func retireAfterIndependentProof() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if !inputClosed { try input.close(); inputClosed = true }
                    ADBProcessRegistry.stopAndReap(process)
                    if !outputClosed { try output.close(); outputClosed = true }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func closeAndWait(timeout: TimeInterval = 8, confirmedRestoredFailure: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if !inputClosed { try input.close(); inputClosed = true }
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                    guard !process.isRunning else { throw ProcessError.controllerCleanupUnsettled }
                    process.waitUntilExit()
                    guard process.terminationReason == .exit,
                          process.terminationStatus == 0 || (process.terminationStatus == 1 &&
                              (confirmedRestoredFailure || (knownStartupFailure && !receivedValidHeader && !mutationMayHaveApplied))) else { throw ProcessError.controllerRestorationFailed }
                    if !outputClosed { try output.close(); outputClosed = true }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func readLine(timeout: TimeInterval) throws -> Data {
        var line = Data(), byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while line.count <= 4096 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ProcessError.controllerTimeout }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 8000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw ProcessError.controllerTimeout }
            let count = Darwin.read(output.fileDescriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { throw ProcessError.controllerEOF }
            if byte == 10 { return line }
            line.append(byte)
        }
        throw ProcessError.controllerLineTooLarge
    }
    enum ProcessError: Error {
        case controllerEOF, controllerWriteFailed, controllerTimeout, controllerLineTooLarge
        case controllerCleanupUnsettled, controllerRestorationFailed
    }
}
#endif
