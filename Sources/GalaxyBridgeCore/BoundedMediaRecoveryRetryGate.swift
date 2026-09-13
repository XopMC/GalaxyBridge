public struct BoundedMediaRecoveryRetryGate: Sendable {
    private var lastRetriedEpisode: UInt64 = 0

    public init() {}

    /// Retry each exhausted native episode once, without restarting transport.
    /// Native recovery owns three timed opportunities and cannot exhaust the
    /// next episode before its 1750ms budget. Capping retries per outage would
    /// permanently freeze a live stream when both initial cycles lose an IDR.
    /// Keep the monotonic watermark through healthy/config changes; a new
    /// transport owns a new gate. Attempt count is advisory: a stalled owner
    /// can miss a request window and exhaust with fewer than three requests.
    public mutating func retryEpisode(
        state: UInt32,
        reason: UInt32,
        attempt _: UInt32,
        episode: UInt64
    ) -> UInt64? {
        guard state == 3,
              reason == 5,
              episode > lastRetriedEpisode
        else { return nil }
        lastRetriedEpisode = episode
        return episode
    }
}
