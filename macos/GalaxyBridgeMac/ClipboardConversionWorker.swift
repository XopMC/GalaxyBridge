import AppKit
import Foundation
import CryptoKit

enum ClipboardPeerIdentity {
    static func fingerprint(publicKey: Data, tlsFingerprint: Data) -> Data {
        var bytes = Data("galaxybridge-clipboard-peer-v1\0".utf8)
        bytes.append(publicKey); bytes.append(tlsFingerprint)
        return Data(SHA256.hash(data: bytes))
    }
}

enum MacClipboardImageSource: Sendable {
    case png(Data)
    case encoded(Data)
}

/// Immutable bytes belong to one pasteboard occurrence. No live pasteboard or
/// image object crosses into the conversion worker.
struct MacClipboardSnapshot: Sendable {
    let occurrence: Int
    let pasteboardTypes: [String]
    let text: String?
    let image: MacClipboardImageSource?
}

enum MacClipboardImageEncoder {
    static func pngData(from source: MacClipboardImageSource) -> Data? {
        switch source {
        case let .png(data): return data
        case let .encoded(data):
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }
    }
}

/// One serial conversion and at most one replaceable pending snapshot. Bursts
/// cannot accumulate image conversions or publish an older clipboard occurrence.
final class MacClipboardConversionWorker: @unchecked Sendable {
    struct Result: Sendable {
        let occurrence: Int
        let candidate: MacClipboardPayloadCandidate
        fileprivate let revision: UUID
    }
    private struct Work {
        let snapshot: MacClipboardSnapshot
        let revision: UUID
        let completion: @Sendable (Result) -> Void
    }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let encodeImage: @Sendable (MacClipboardImageSource) -> Data?
    private var revision = UUID()
    private var pending: Work?
    private var scheduled = false
    private var stopped = false

    init(queue: DispatchQueue = DispatchQueue(label: "com.xopmc.GalaxyBridge.clipboard-conversion", qos: .utility),
         encodeImage: @escaping @Sendable (MacClipboardImageSource) -> Data? = MacClipboardImageEncoder.pngData) {
        self.queue = queue
        self.encodeImage = encodeImage
    }

    func submit(_ snapshot: MacClipboardSnapshot, hasDestination: Bool,
                completion: @escaping @Sendable (Result) -> Void) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        revision = UUID()
        pending = MacClipboardPayloadPolicy.isEligible(pasteboardTypes: snapshot.pasteboardTypes, hasDestination: hasDestination)
            ? Work(snapshot: snapshot, revision: revision, completion: completion) : nil
        let start = pending != nil && !scheduled
        if start { scheduled = true }
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }

    /// Recheck when a completion eventually reaches MainActor. Its pasteboard
    /// occurrence must also still match the live change count at that boundary.
    func isCurrent(_ result: Result) -> Bool {
        lock.withLock { !stopped && revision == result.revision }
    }

    func invalidate() {
        lock.withLock { revision = UUID(); pending = nil }
    }

    func stop() {
        lock.withLock { stopped = true; revision = UUID(); pending = nil }
    }

    private func drain() {
        while true {
            let work: Work? = lock.withLock {
                guard !stopped, let work = pending else { scheduled = false; return nil }
                pending = nil
                return work
            }
            guard let work else { return }
            let candidate = autoreleasepool {
                MacClipboardPayloadPolicy.candidate(
                    pasteboardTypes: work.snapshot.pasteboardTypes, text: work.snapshot.text,
                    png: work.snapshot.image.flatMap(encodeImage))
            }
            guard let candidate else { continue }
            let result = Result(occurrence: work.snapshot.occurrence, candidate: candidate, revision: work.revision)
            if isCurrent(result) { work.completion(result) }
        }
    }
}
