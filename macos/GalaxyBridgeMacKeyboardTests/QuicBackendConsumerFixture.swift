#if !GALAXYBRIDGE_APP_STORE && GB_QUIC_BACKEND_QA
import CryptoKit
import Foundation
import GalaxyBridgeCore
import GalaxyBridgeQuicBackend
import Testing
@testable import GalaxyBridgeMac

@_silgen_name("gb_backend_qa_component")
private func component(_ owner: UInt64, _ duration: UInt32, _ mode: UInt32, _ sequence: UInt64, _ index: UInt32) -> UInt32
@_silgen_name("gb_backend_qa_pools")
private func pools(_ owner: UInt64, _ values: UnsafeMutablePointer<UInt64>) -> UInt32
@_silgen_name("gb_backend_qa_transfer_usage")
private func transferUsage(_ owner: UInt64, _ values: UnsafeMutablePointer<UInt64>) -> UInt32
@_silgen_name("gb_backend_qa_time")
private func setTime(_ owner: UInt64, _ ns: UInt64, _ cleanup: UInt32) -> UInt32
@_silgen_name("gb_backend_qa_dropped")
private func dropped(_ owner: UInt64, _ count: UnsafeMutablePointer<UInt64>) -> UInt32

enum QuicBackendConsumerFixture {
    struct OwnershipFailure: Error { let message: String }
    static func stockMatches(_ observation: [UInt64], _ bytes: Data, direction: UInt64 = 1) -> Bool {
        guard observation.count == 8, observation[1] == direction, observation[2] == bytes.count else { return false }
        let digest = Array(SHA256.hash(data: bytes))
        return (0..<4).allSatisfy { word in
            observation[4 + word] == digest[(word*8)..<(word*8+8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
    }
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let frozen = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GB_QUIC_BACKEND_FIXTURE_PEER"]!).deletingLastPathComponent()

    struct MotionFixture { let file: URL; let video: QuicVideoFixture; let audio: QuicAudioFixture }
    static func preparedMotion(hevc: Bool) throws -> MotionFixture {
        let file = try fixtureFile(hevc ? "hevc-motion.gbf" : "h264-motion.gbf")
        // Six seconds of newly encoded synthetic pixels and actual AAC samples.
        // No compressed AU, key flag, or presentation timestamp is repeated.
        // Match the shipping producer's one-second periodic recovery fence.
        // Multiple genuine IDRs let the scored test keep pressure through all
        // bounded requests, then prove that the same session recovers after
        // capacity returns instead of relying on one lucky future keyframe.
        let video=try QuicCodecFixtureFactory.video(hevc:hevc,frameCount:360,width:640,height:360,keyframes:[0,60,120,180,240,300],motion:true)
        let audio=try QuicCodecFixtureFactory.audio(sampleCount:288_000)
        let videoRecords=QuicCodecFixtureFactory.stockVideo(video)
        var entries:[(UInt64,UInt8,Data)]=[(0,1,videoRecords.prefix(3).reduce(into:Data()) {$0.append($1)}),
            (0,2,Data([0,97,97,99])+QuicCodecFixtureFactory.stockPacket(audio.configuration,pts:0,flags:1<<62))]
        for (index,packet) in video.packets.enumerated() {entries.append((250_000_000+(packet.pts-1_000_000)*1000,1,videoRecords[index+3]))}
        for packet in audio.packets {entries.append((250_000_000+(packet.pts-1_000_000)*1000,2,QuicCodecFixtureFactory.stockPacket(packet.bytes,pts:packet.pts,flags:0)))}
        entries.sort {$0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0}
        guard entries.count<=768 else {throw QuicFixtureError.capacity}
        var bytes=Data("GBF1".utf8);bytes.append(contentsOf:[7,0,0,0]);append(UInt32(entries.count),to:&bytes)
        for (due,track,record) in entries {
            append(due,to:&bytes);bytes.append(contentsOf:[track,0,0,0]);append(UInt32(record.count),to:&bytes);bytes.append(record)
        }
        try bytes.write(to:file)
        print("qa-motion-source hevc=\(hevc) width=640 height=360 video=\(video.packets.count) audio=\(audio.packets.count) entries=\(entries.count) bytes=\(bytes.count) bitrate=\(video.packets.reduce(0){$0+$1.bytes.count}*8/6) keyBytes=\(video.packets.filter(\.key).map{ $0.bytes.count }) keyPTS=\(video.packets.filter(\.key).map(\.pts)) sha256=\(hash(bytes))")
        return MotionFixture(file:file,video:video,audio:audio)
    }

    static func prepared(hevc: Bool, sustained: Bool = false, audioEnabled: Bool = true, lateIDR: Bool = false) throws -> URL {
        let video = try syntheticVideoRecords(hevc: hevc)
        let audio = try syntheticAudioRecords()
        var entries: [(UInt64, UInt8, Data)] = []
        for (track, data) in [(UInt8(1), video), (UInt8(2), audio)] {
            if track == 2 && !audioEnabled { continue }
            var firstPTS: UInt64?
            var packets: [Data] = []
            for (ordinal, record) in data.enumerated() {
                // Keep the original PTS/bytes. This finite input schedule is
                // below native/G1 retained-slot capacity and within the existing
                // shared playout clock's unmodified late window.
                var due = UInt64(ordinal) * 50_000_000
                if ordinal > 0, record[0] & 0xc0 == 0 {
                    packets.append(record)
                    let pts = record.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & ((1 << 61) - 1)
                    if firstPTS == nil { firstPTS = pts }
                    due = 250_000_000 + (pts - firstPTS!) * 1000
                    if lateIDR && track == 1 && packets.count == 5 { due += 400_000_000 }
                }
                if !sustained || record.count < 12 || record[0] & 0xc0 != 0 { entries.append((due, track, record)) }
            }
            if sustained {
                // Finite two-second cadence fixture: reuse complete original
                // closed-GOP/AAC payloads and flags, declare fresh synthetic PTS.
                // This tests lifetime at60fps+48kHz AAC, not20Mbps image quality.
                for index in 0..<(track == 1 ? 120 : 94) {
                    let delta = track == 1 ? UInt64(index) * 1_000_000 / 60 : UInt64(index) * 1_024_000_000 / 48_000
                    var record = packets[index % packets.count]
                    let original = record.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    var pts = ((original & ~((1 << 61) - 1)) | (1_000_000 + delta)).bigEndian
                    withUnsafeBytes(of: &pts) { record.replaceSubrange(0..<8, with: $0) }
                    entries.append((250_000_000 + delta * 1000, track, record))
                }
            }
        }
        entries.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var output = Data("GBF1".utf8); output.append(contentsOf: [audioEnabled ? 7 : 5, 0, 0, 0])
        append(UInt32(entries.count), to: &output)
        for (due, track, bytes) in entries {
            append(due, to: &output); output.append(contentsOf: [track, 0, 0, 0]); append(UInt32(bytes.count), to: &output); output.append(bytes)
        }
        let file = try fixtureFile((hevc ? "hevc-aac" : "h264-aac") + (sustained ? "-60fps" : "") + (audioEnabled ? "" : "-muted-app") + (lateIDR ? "-late-idr" : "") + ".gbf")
        try output.write(to: file)
        return file
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func preparedStaticRecovery(hevc: Bool) throws -> URL {
        let video = try syntheticVideoRecords(hevc: hevc)
        let audio = try syntheticAudioRecords()
        guard video.count==8,audio.count>=3 else {throw QuicFixtureError.malformed}
        var entries:[(UInt64,UInt8,Data)]=video.prefix(3).enumerated().map {(UInt64($0.offset)*50_000_000,1,$0.element)}
        entries.append((0,2,audio[0]));entries.append((50_000_000,2,audio[1]))
        // Actual AAC anchors at250ms. The sole first independent image arrives
        // at450ms with ORIGINAL PTS, then no next video until600ms. Following
        // original VCL bytes use explicitly generated forward PTS, not a clock
        // reset, so their scheduling and AAC retain the existing common anchor.
        entries.append((450_000_000,1,video[3]))
        for index in 0..<4 {
            var packet=video[index+4]
            let word=packet.prefix(8).reduce(UInt64(0)){($0<<8)|UInt64($1)}
            var pts=((word & ~((1<<61)-1)) | (1_400_000+UInt64(index)*16_667)).bigEndian
            withUnsafeBytes(of:&pts){packet.replaceSubrange(0..<8,with:$0)}
            entries.append((600_000_000+UInt64(index)*16_667_000,1,packet))
        }
        for index in 0..<24 {
            var packet=audio[2];var pts=(UInt64(1_000_000)+UInt64(index)*21_334).bigEndian
            withUnsafeBytes(of:&pts){packet.replaceSubrange(0..<8,with:$0)}
            entries.append((250_000_000+UInt64(index)*21_334_000,2,packet))
        }
        entries.sort {$0.0 == $1.0 ? $0.1<$1.1:$0.0<$1.0}
        var output=Data("GBF1".utf8);output.append(contentsOf:[7,0,0,0]);append(UInt32(entries.count),to:&output)
        for(due,track,record)in entries {append(due,to:&output);output.append(contentsOf:[track,0,0,0]);append(UInt32(record.count),to:&output);output.append(record)}
        let file = try fixtureFile(hevc ? "hevc-static-recovery.gbf" : "h264-static-recovery.gbf")
        try output.write(to:file);print("qa-static-source hevc=\(hevc) entries=\(entries.count) sha256=\(hash(output))")
        return file
    }
    static func preparedDelayedLoss(hevc: Bool) throws -> (URL, [UInt64]) {
        let file = try fixtureFile(hevc ? "hevc-delayed-loss.gbf" : "h264-delayed-loss.gbf")
        let video=try QuicCodecFixtureFactory.video(hevc:hevc,frameCount:6,width:64,height:64,keyframes:[0,4],motion:true)
        let records=QuicCodecFixtureFactory.stockVideo(video)
        var entries:[(UInt64,Data)]=[(0,records.prefix(3).reduce(into:Data()) {$0.append($1)})]
        for (index,packet) in video.packets.enumerated() {entries.append((250_000_000+(packet.pts-1_000_000)*1000,records[index+3]))}
        var bytes=Data("GBF1".utf8);bytes.append(contentsOf:[5,0,0,0]);append(UInt32(entries.count),to:&bytes)
        for (due,record) in entries {append(due,to:&bytes);bytes.append(contentsOf:[1,0,0,0]);append(UInt32(record.count),to:&bytes);bytes.append(record)}
        try bytes.write(to:file)
        #expect(video.packets.map(\.key)==[true,false,false,false,true,false])
        return (file,video.packets.map(\.pts))
    }
    /// Encode owned synthetic input on this host. Codec bytes can differ between
    /// OS encoders, so validate the scenario's cadence instead of an old media hash.
    private static func syntheticVideoRecords(hevc: Bool) throws -> [Data] {
        let video = try QuicCodecFixtureFactory.video(hevc: hevc)
        guard video.packets.map(\.key) == [true, false, false, false, true],
              video.packets.map(\.pts) == [1_000_000, 1_016_667, 1_033_334, 1_050_001, 1_066_668],
              !video.configuration.isEmpty else { throw QuicFixtureError.malformed }
        return QuicCodecFixtureFactory.stockVideo(video)
    }

    private static func syntheticAudioRecords() throws -> [Data] {
        let audio = try QuicCodecFixtureFactory.audio()
        guard !audio.configuration.isEmpty, audio.packets.count >= 5,
              audio.packets.first?.pts == 1_000_000 else { throw QuicFixtureError.malformed }
        return [Data([0, 97, 97, 99]),
                QuicCodecFixtureFactory.stockPacket(audio.configuration, pts: 0, flags: 1 << 62)]
            + audio.packets.map { QuicCodecFixtureFactory.stockPacket($0.bytes, pts: $0.pts, flags: 0) }
    }

    private static func fixtureFile(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(".build/quic-consumer-fixtures")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var word = value.bigEndian; withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
    }

    /// The exact production C bridge is driven on one actual thread, with an
    /// authenticated QA peer and freshly encoded synthetic bytes. Native consumers are real.
    static func run(file: URL, native: ScrcpyNativeMediaOwner, seconds: TimeInterval = 2,
                    checkCommittedBorrowReleased: Bool = false,
                    checkDecodedInputLifetime: Bool = false,
                    checkDelayedNativeLoss: Bool = false,
                    recoveredOutput: @escaping @Sendable () -> Bool = { false },
                    rejection: Int = 0, impairment: UInt32 = 0,
                    until: @escaping @Sendable () -> Bool = { false },
                    media: @escaping @Sendable (QuicBackendBridge.AdmittedMedia) -> Void) async throws {
        let bytes = try Data(contentsOf: file)
        guard bytes.count >= 12 && [UInt8(5), UInt8(7)].contains(bytes[4]) else { throw OwnershipFailure(message: "invalid prepared fixture track set") }
        let launch = QuicBackendBridge.Launch(program: frozen.appendingPathComponent("gb-quic-backend-macos-arm64-qa").path,
            arguments: ["--stdio-fixture", "--fixture", file.path, "--sha256", hash(bytes), "--duration-ms", "5000"],
            peerIP: "127.0.0.1", sidecarSHA: Array(repeating: 4, count: 32), generation: 81,
            targetToken: 9, scid: 1, displayID: 0, captureKind: 0, enabled: bytes[4])
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let bridge = try QuicBackendBridge(launch)
                    try QuicBackendBridge.check(component(bridge.owner, 5000, impairment, impairment == 0 ? 0 : (impairment == 1 ? 1 : 2), impairment == 1 ? 1 : 0))
                    var failure: Error?
                    var operation = "start"
                    var previous = [UInt64]()
                    func observe(_ phase: String) {
                        var counts = [UInt64](repeating: 0, count: 8)
                        let status = counts.withUnsafeMutableBufferPointer { pools(bridge.owner, $0.baseAddress!) }
                        if counts != previous || phase == "failure" {
                            print("qa-native-pools phase=\(phase) status=\(status) receiverAU=\(counts[0])/\(counts[1]) receiverMetadata=\(counts[2])/\(counts[3]) payloadCopyAU=\(counts[4])/\(counts[5]) payloadCopyMetadata=\(counts[6])/\(counts[7]) nativeJobs=\(native.attempt.snapshot.jobs)")
                            previous = counts
                        }
                    }
                    do {
                        let end = ProcessInfo.processInfo.systemUptime + seconds
                        while ProcessInfo.processInfo.systemUptime < end && !until() {
                            observe("before-poll")
                            operation = "poll"
                            let poll = try bridge.poll()
                            guard poll.terminal == 0 else { throw QuicBackendError(status: poll.terminal) }
                            operation = "next"
                            while let event = try bridge.next() {
                                if event.kind == 2 {
                                    operation = "admit"
                                    if checkDecodedInputLifetime && event.record_kind == 5 && event.track == 1 {
                                        var clone: ScrcpyStreamEvent?
                                        do {
                                            let item = try bridge.admit(event, into: native)
                                            clone = item.work.event
                                            native.video.consume(item.work.event, epoch: item.identity.epoch, nativeWork: item.work)
                                            media(item)
                                        }
                                        let outputEnd = ProcessInfo.processInfo.systemUptime + 1
                                        while !until() && ProcessInfo.processInfo.systemUptime < outputEnd { Thread.sleep(forTimeInterval: 0.001) }
                                        guard until() else { throw OwnershipFailure(message: "actual decoded frame did not arrive") }
                                        var counts = [UInt64](repeating: 0, count: 8), domains = [UInt64](repeating: 0, count: 2)
                                        try counts.withUnsafeMutableBufferPointer { try QuicBackendBridge.check(pools(bridge.owner, $0.baseAddress!)) }
                                        try domains.withUnsafeMutableBufferPointer { try QuicBackendBridge.check(transferUsage(bridge.owner, $0.baseAddress!)) }
                                        guard domains == [0, 1] && counts[4] == 1 && counts[5] == event.bytes.length else {
                                            throw OwnershipFailure(message: "real Data clone must retain exact byte/storage charge: \(counts),\(domains)")
                                        }
                                        withExtendedLifetime(clone) {}; clone = nil
                                        try counts.withUnsafeMutableBufferPointer { try QuicBackendBridge.check(pools(bridge.owner, $0.baseAddress!)) }
                                        try domains.withUnsafeMutableBufferPointer { try QuicBackendBridge.check(transferUsage(bridge.owner, $0.baseAddress!)) }
                                        guard domains == [0, 0] && counts[4] == 0 && counts[5] == 0 && native.attempt.snapshot.decoded == 1 else {
                                            throw OwnershipFailure(message: "decoded output still owns compressed ticket: \(counts),\(domains)")
                                        }
                                        print("qa-real-c-input cloneStored=1 cloneBytes=\(event.bytes.length) finalStored=0 finalCopyBytes=0 decoded=1")
                                        break
                                    }
                                    if rejection != 0 {
                                        if rejection == 1 { native.retire() }
                                        else { try QuicBackendBridge.check(setTime(bridge.owner, try bridge.now() + 2_000_000_000, 0)) }
                                        do {
                                            _ = try bridge.admit(event, into: native)
                                            throw OwnershipFailure(message: "Rejected/expired native admission unexpectedly succeeded")
                                        } catch let error as QuicBackendError {
                                            guard error.status == (rejection == 1 ? 102 : 103) else { throw error }
                                        }
                                        guard gb_backend_event_release(bridge.owner, event.handle) == GB_INVALID_HANDLE else {
                                            throw OwnershipFailure(message: "Failed admission leaked borrowed event")
                                        }
                                        var counts = [UInt64](repeating: 0, count: 8)
                                        try counts.withUnsafeMutableBufferPointer { try QuicBackendBridge.check(pools(bridge.owner, $0.baseAddress!)) }
                                        guard counts[4...7].allSatisfy({ $0 == 0 }) else {
                                            throw OwnershipFailure(message: "Failed admission leaked native copy charge")
                                        }
                                        print("qa-rejected-admission mode=\(rejection) borrowed=0 copies=0")
                                        break
                                    }
                                    let admitted: QuicBackendBridge.AdmittedMedia
                                    do { admitted = try bridge.admit(event, into: native) }
                                    catch {
                                        print("native-admission-failure kind=\(event.record_kind) track=\(event.track) sequence=\(event.sequence) config=\(event.config) payload=\(event.bytes.length) attachedConfig=\(event.configuration.length) nativeJobs=\(native.attempt.snapshot.jobs) status=\((error as? QuicBackendError)?.status ?? 0)")
                                        throw error
                                    }
                                    if checkCommittedBorrowReleased {
                                        // Probe the actual lease registry, not committed-media eligibility.
                                        // An erroneous still-live event would be consumed here and fail
                                        // the awaited continuation, rather than a detached #expect context.
                                        let release = gb_backend_event_release(bridge.owner, event.handle)
                                        guard release == GB_INVALID_HANDLE else {
                                            throw OwnershipFailure(message: "Committed event remained registered: release=\(release)")
                                        }
                                        if event.record_kind == 5 {
                                            var counts = [UInt64](repeating: 0, count: 8)
                                            try counts.withUnsafeMutableBufferPointer { try QuicBackendBridge.check(pools(bridge.owner, $0.baseAddress!)) }
                                            var domains = [UInt64](repeating: 0, count: 2)
                                            try domains.withUnsafeMutableBufferPointer { try QuicBackendBridge.check(transferUsage(bridge.owner, $0.baseAddress!)) }
                                            guard counts[1] >= UInt64(event.bytes.length),
                                                  counts[4] >= 1 && counts[5] >= event.bytes.length else {
                                                throw OwnershipFailure(message: "Actual copied storage charge disappeared: \(counts)")
                                            }
                                            guard domains[0] == 0 && domains[1] > 0 && domains[1] <= 64 else {
                                                throw OwnershipFailure(message: "Native commit failed to transfer bounded credit: \(domains)")
                                            }
                                            print("qa-committed-borrow released=1 originalAU=\(counts[0]) sharedBytes=\(counts[1]) copyAU=\(counts[4]) copyBytes=\(counts[5]) transfer=\(domains[0]) stored=\(domains[1])")
                                        }
                                    }
                                    if admitted.identity.track == 1 {
                                        native.video.consume(admitted.work.event, epoch: admitted.identity.epoch, nativeWork: admitted.work)
                                    } else {
                                        native.audio.consume(admitted.work.event, epoch: admitted.identity.epoch, nativeWork: admitted.work)
                                    }
                                    media(admitted)
                                    if checkDelayedNativeLoss && event.record_kind == 5 && event.track == 1 && event.sequence == 5 {
                                        // Observe actual independent5 BEFORE acquiring an uncommitted6.
                                        // Otherwise this test's own wait can expire6 in status tick(now),
                                        // creating a legitimate unrelated dependency episode.
                                        let cutoff=ProcessInfo.processInfo.systemUptime+0.1
                                        while !recoveredOutput() && ProcessInfo.processInfo.systemUptime<cutoff {Thread.sleep(forTimeInterval:0.001)}
                                        guard recoveredOutput() else {throw OwnershipFailure(message:"actual independent5 output missing")}
                                        let status=try #require(native.attempt.takeMediaStatus().first {$0.identity.track==1})
                                        guard status.inputLostThrough==2 && status.inputDropped==1 && status.outputSequence==5 else {
                                            throw OwnershipFailure(message:"wrong actual delayed status: \(status.inputLostThrough)/\(status.inputDropped)/\(status.outputSequence)")
                                        }
                                        let before=try bridge.mediaHealth(1)
                                        try bridge.nativeMediaStatus(status);try bridge.nativeMediaStatus(status)
                                        let health=try bridge.mediaHealth(1)
                                        print("qa-delayed-native-boundary beforeEpisode=\(before.episode) beforeReason=\(before.reason) beforeDeclined=\(before.declined) afterEpisode=\(health.episode) afterReason=\(health.reason) afterDeclined=\(health.declined)")
                                        guard before.episode==0 && health.episode==0 && health.state==1 && health.reason==0 && health.declined==before.declined && health.admittedInputDropped==1 else {
                                            throw OwnershipFailure(message:"delayed status boundary: episode=\(health.episode) state=\(health.state) reason=\(health.reason) declined=\(health.declined) count=\(health.admittedInputDropped)")
                                        }
                                        print("qa-delayed-native-loss lost=2 count=1 committedOutput=5 duplicateCount=\(health.admittedInputDropped) episode=\(health.episode)")
                                    }
                                } else { try bridge.release(event) }
                                operation = "next"
                            }
                            if rejection != 0 && operation == "admit" { break }
                            Thread.sleep(forTimeInterval: 0.001)
                        }
                    } catch { observe("failure"); print("qa-native-terminal operation=\(operation)"); failure = error }
                    if impairment != 0 {
                        var count: UInt64 = 0
                        try QuicBackendBridge.check(dropped(bridge.owner, &count))
                        if count == 0 { failure = OwnershipFailure(message: "Requested actual fragment impairment did not occur") }
                        print("qa-native-impairment mode=\(impairment) dropped=\(count)")
                    }
                    native.retire()
                    try bridge.retire()
                    while !(try bridge.destroyIfSettled()) {
                        _ = try bridge.poll()
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    if bridge.cleanupFailed { throw QuicBackendError(status: UInt32(GB_CLEANUP)) }
                    if let failure { throw failure }
                    continuation.resume()
                } catch { native.retire(); continuation.resume(throwing: error) }
            }
        }
    }
}
#endif
