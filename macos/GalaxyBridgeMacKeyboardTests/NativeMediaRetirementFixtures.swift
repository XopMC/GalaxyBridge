import Foundation
import CoreMedia
import CoreVideo
import GalaxyBridgeCore
import Testing
@testable import GalaxyBridgeMac

final class NativeFixtureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class NativeFixtureBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func update(_ action: (inout Value) -> Void) { lock.withLock { action(&storage) } }
}

final class NativeFixtureCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []
    private var opened = false
    var count: Int { lock.withLock { pending.count } }
    func receive(_ completion: @escaping @Sendable () -> Void) {
        let run = lock.withLock { if opened { return true }; pending.append(completion); return false }
        if run { completion() }
    }
    func open() {
        let actions = lock.withLock { opened = true; let actions = pending; pending.removeAll(); return actions }
        actions.forEach { $0() }
    }
}

enum NativeFixtures {
    static func withOversizedNALBacking(count: Int, freed: NativeFixtureCount, body: (ScrcpyStreamEvent) -> Void) {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: count * 2, alignment: 16)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count * 2)
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 0, to: count, by: 4) {
            bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 1; bytes[offset + 3] = 0x65
        }
        let backing = Data(bytesNoCopy: pointer, count: count * 2, deallocator: .custom { pointer, _ in
            pointer.deallocate(); freed.increment()
        })
        let view = backing.prefix(count)
        body(.packet(.init(isConfiguration: false, isKeyFrame: true, presentationTimeUs: 123, payload: view)))
    }
    static func packet(_ packet: QuicEncodedPacket) -> ScrcpyStreamEvent {
        .packet(.init(isConfiguration: false, isKeyFrame: packet.key, presentationTimeUs: packet.pts, payload: packet.bytes))
    }
    static func configuration(_ bytes: Data) -> ScrcpyStreamEvent {
        .packet(.init(isConfiguration: true, isKeyFrame: false, presentationTimeUs: nil, payload: bytes))
    }
    static func videoEvents(_ fixture: QuicVideoFixture) throws -> [ScrcpyStreamEvent] {
        var parser = ScrcpyStreamDecoder(kind: .video, maxPayloadLength: 4 * 1024 * 1024)
        return try QuicCodecFixtureFactory.stockVideo(fixture).flatMap { try parser.append($0) }
    }
    static func until(isolation: isolated (any Actor)? = #isolation, _ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw QuicFixtureError.timeout
    }
    static func marker(_ pixel: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixel, 0) else { return 0 }
        return base.assumingMemoryBound(to: UInt8.self)[32 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + 32]
    }
    @MainActor static func session() throws -> ScrcpySession {
        try ScrcpySession(serial: "native-fixture-no-launch", adb: ADBClient(testingExecutableURL: URL(fileURLWithPath: "/usr/bin/true")),
                          physicalDisplayPolicy: .leaveUnchanged, automaticDisplayManagement: false)
    }
}

final class NativeFixtureSuspension {
    private let queue: DispatchQueue
    private var suspended = true
    init(_ queue: DispatchQueue) { self.queue = queue; queue.suspend() }
    func resume() { if suspended { suspended = false; queue.resume() } }
    deinit { resume() }
}

final class NativeFixtureActorDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@MainActor @Sendable () -> Void] = []
    var count: Int { lock.withLock { pending.count } }
    func receive(_ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { pending.append(action) } }
    @MainActor func release() {
        let actions = lock.withLock { let actions = pending; pending.removeAll(); return actions }
        actions.forEach { $0() }
    }
}
