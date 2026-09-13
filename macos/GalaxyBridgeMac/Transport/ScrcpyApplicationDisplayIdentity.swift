#if !GALAXYBRIDGE_APP_STORE
import Darwin
import Foundation

struct ScrcpyApplicationDisplayLaunchGeneration: Hashable, Sendable {
    fileprivate let value: UUID

    init() {
        value = UUID()
    }
}

struct ScrcpyApplicationDisplayIdentity: Equatable, Sendable {
    let displayID: Int32
    let launchGeneration: ScrcpyApplicationDisplayLaunchGeneration
}

struct ScrcpyNewDisplayAnnouncement: Equatable, Sendable {
    let width: Int32
    let height: Int32
    let density: Int32
    let displayID: Int32
}

enum ScrcpyOwnedProcessOutputEvent: Equatable, Sendable {
    case announcement(ScrcpyNewDisplayAnnouncement)
    case conflict
    case ended
}

struct ScrcpyNewDisplayOutputParser: Sendable {
    static let maximumPartialLineByteCount = 1_024

    private var partialLine: [UInt8] = []
    private var discardingOversizedLine = false
    private var acceptedDisplayID: Int32?
    private var conflicted = false

    var retainedPartialLineByteCount: Int { partialLine.count }

    mutating func append(_ bytes: Data) -> [ScrcpyOwnedProcessOutputEvent] {
        var events: [ScrcpyOwnedProcessOutputEvent] = []
        for byte in bytes {
            if byte == 0x0A {
                if !discardingOversizedLine {
                    events.append(contentsOf: parseCompletedLine())
                }
                partialLine.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
                continue
            }
            guard !discardingOversizedLine else { continue }
            guard partialLine.count < Self.maximumPartialLineByteCount else {
                partialLine.removeAll(keepingCapacity: true)
                discardingOversizedLine = true
                continue
            }
            partialLine.append(byte)
        }
        return events
    }

    mutating func finish() -> [ScrcpyOwnedProcessOutputEvent] {
        defer {
            partialLine.removeAll(keepingCapacity: false)
            discardingOversizedLine = false
        }
        guard !discardingOversizedLine, !partialLine.isEmpty else { return [] }
        return parseCompletedLine()
    }

    private mutating func parseCompletedLine() -> [ScrcpyOwnedProcessOutputEvent] {
        var bytes = partialLine
        if bytes.last == 0x0D { bytes.removeLast() }
        guard let line = String(bytes: bytes, encoding: .utf8),
              let announcement = Self.parse(line),
              !conflicted
        else { return [] }

        if let acceptedDisplayID {
            guard announcement.displayID != acceptedDisplayID else { return [] }
            conflicted = true
            return [.conflict]
        }
        acceptedDisplayID = announcement.displayID
        return [.announcement(announcement)]
    }

    private static func parse(_ line: String) -> ScrcpyNewDisplayAnnouncement? {
        let prefix = "[server] INFO: New display: "
        let idMarker = " (id="
        guard line.hasPrefix(prefix), line.hasSuffix(")") else { return nil }
        let body = line.dropFirst(prefix.count).dropLast()
        guard let idRange = body.range(of: idMarker),
              body[idRange.upperBound...].range(of: idMarker) == nil
        else { return nil }

        let dimensionsAndDensity = body[..<idRange.lowerBound]
        let displayIDText = body[idRange.upperBound...]
        guard let x = dimensionsAndDensity.firstIndex(of: "x"),
              let slash = dimensionsAndDensity[x...].firstIndex(of: "/"),
              dimensionsAndDensity[dimensionsAndDensity.index(after: x)...].firstIndex(of: "x") == nil,
              dimensionsAndDensity[dimensionsAndDensity.index(after: slash)...].firstIndex(of: "/") == nil,
              let width = positiveInt32(dimensionsAndDensity[..<x]),
              let height = positiveInt32(dimensionsAndDensity[dimensionsAndDensity.index(after: x)..<slash]),
              let density = positiveInt32(dimensionsAndDensity[dimensionsAndDensity.index(after: slash)...]),
              let displayID = positiveInt32(displayIDText)
        else { return nil }
        return ScrcpyNewDisplayAnnouncement(
            width: width,
            height: height,
            density: density,
            displayID: displayID
        )
    }

    private static func positiveInt32<S: StringProtocol>(_ text: S) -> Int32? {
        guard !text.isEmpty,
              text.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
              let value = Int32(text),
              value > 0
        else { return nil }
        return value
    }
}

enum ScrcpyOwnedProcessOutputObserverError: Error, Equatable {
    case alreadyAttached
    case pipeConfigurationFailed(Int32)
}

/// Owns one launch's stdout pipe. The serial queue drains finite reads and the
/// parser retains at most one bounded partial line; raw process output is never
/// retained or logged.
final class ScrcpyOwnedProcessOutputObserver: @unchecked Sendable {
    private static let readByteCount = 4_096
    private static let maximumReadsPerDispatch = 16

    private let pipe = Pipe()
    private let queue: DispatchQueue
    private let eventHandler: @Sendable (ScrcpyOwnedProcessOutputEvent) -> Void
    private var parser = ScrcpyNewDisplayOutputParser()
    private var source: DispatchSourceRead?
    private weak var process: Process?
    private var attached = false
    private var finished = false
    private var parentWriteHandleClosed = false

    init(
        eventHandler: @escaping @Sendable (ScrcpyOwnedProcessOutputEvent) -> Void,
        queue: DispatchQueue? = nil
    ) throws {
        self.eventHandler = eventHandler
        self.queue = queue ?? DispatchQueue(
            label: "com.xopmc.GalaxyBridge.scrcpy-owned-output.\(UUID().uuidString)"
        )
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            throw ScrcpyOwnedProcessOutputObserverError.pipeConfigurationFailed(code)
        }
    }

    var isIdle: Bool {
        queue.sync { true }
    }

    func attach(to process: Process) throws {
        guard !attached else { throw ScrcpyOwnedProcessOutputObserverError.alreadyAttached }
        attached = true
        self.process = process
        process.standardOutput = pipe
        let source = DispatchSource.makeReadSource(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.drainAvailable(maximumReads: Self.maximumReadsPerDispatch, terminal: false)
        }
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        source.setCancelHandler {
            try? readHandle.close()
            try? writeHandle.close()
        }
        self.source = source
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                self?.drainAvailable(maximumReads: nil, terminal: true)
            }
        }
        source.resume()
    }

    func launchDidSucceed() {
        queue.async { [weak self] in self?.closeParentWriteHandle() }
    }

    func launchDidFail() {
        cancel()
    }

    func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !finished else { return }
            emit(parser.append(bytes))
        }
    }

    func cancel() {
        queue.async { self.finish() }
    }

    private func drainAvailable(maximumReads: Int?, terminal: Bool) {
        guard !finished else { return }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: Self.readByteCount)
        var reads = 0
        while maximumReads.map({ reads < $0 }) ?? true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                reads += 1
                emit(parser.append(Data(buffer.prefix(count))))
                continue
            }
            if count == 0 {
                emit(parser.finish())
                finish()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            finish()
            return
        }
        if terminal {
            emit(parser.finish())
            finish()
        }
    }

    private func emit(_ events: [ScrcpyOwnedProcessOutputEvent]) {
        for event in events { eventHandler(event) }
    }

    private func closeParentWriteHandle() {
        guard !parentWriteHandleClosed else { return }
        parentWriteHandleClosed = true
        try? pipe.fileHandleForWriting.close()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        process?.terminationHandler = nil
        process = nil
        eventHandler(.ended)
        if let source {
            source.cancel()
            self.source = nil
        } else {
            try? pipe.fileHandleForReading.close()
            closeParentWriteHandle()
        }
    }
}
#endif
