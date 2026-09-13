import Foundation

struct AudioPresentationTimeline {
    static let defaultLeadTime: TimeInterval = 0.060
    static let maximumLateTime: TimeInterval = 0.100
    static let maximumFutureTime: TimeInterval = 2.0

    private(set) var basePresentationTimeUs: UInt64?
    private(set) var baseHostTime: TimeInterval?
    private(set) var lastPresentationTimeUs: UInt64?

    mutating func reset() {
        basePresentationTimeUs = nil
        baseHostTime = nil
        lastPresentationTimeUs = nil
    }

    mutating func targetHostTime(
        presentationTimeUs: UInt64?,
        now: TimeInterval,
        leadTime: TimeInterval = Self.defaultLeadTime
    ) -> TimeInterval? {
        guard let presentationTimeUs else { return nil }

        if let lastPresentationTimeUs,
           presentationTimeUs < lastPresentationTimeUs {
            return rebase(presentationTimeUs: presentationTimeUs, now: now, leadTime: leadTime)
        }

        guard let basePresentationTimeUs, let baseHostTime else {
            return rebase(presentationTimeUs: presentationTimeUs, now: now, leadTime: leadTime)
        }

        let deltaSeconds = Double(presentationTimeUs - basePresentationTimeUs) / 1_000_000
        let target = baseHostTime + deltaSeconds
        if target < now - Self.maximumLateTime || target > now + Self.maximumFutureTime {
            return rebase(presentationTimeUs: presentationTimeUs, now: now, leadTime: 0.010)
        }
        lastPresentationTimeUs = presentationTimeUs
        return target
    }

    private mutating func rebase(
        presentationTimeUs: UInt64,
        now: TimeInterval,
        leadTime: TimeInterval
    ) -> TimeInterval {
        let hostTime = now + max(0, leadTime)
        basePresentationTimeUs = presentationTimeUs
        baseHostTime = hostTime
        lastPresentationTimeUs = presentationTimeUs
        return hostTime
    }
}
