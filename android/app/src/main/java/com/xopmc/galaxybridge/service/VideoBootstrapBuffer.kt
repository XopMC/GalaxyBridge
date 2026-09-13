package com.xopmc.galaxybridge.service

/** Retains only a complete, bounded GOP. A static screen produces no new
 * surface frames, so requesting an IDR alone cannot bootstrap a new viewer. */
internal class VideoBootstrapBuffer<T>(
    private val maxBytes: Int,
    private val maxFrames: Int,
    private val epoch: (T) -> Int,
    private val isConfiguration: (T) -> Boolean,
    private val isKeyFrame: (T) -> Boolean,
    private val size: (T) -> Int,
) {
    private var configuration: T? = null
    private val frames = ArrayList<T>()
    private var bytes = 0

    /** False asks the encoder for a fresh keyframe instead of retaining an
     * undecodable suffix when the memory bound is reached. */
    @Synchronized
    fun offer(frame: T): Boolean {
        if (isConfiguration(frame)) {
            configuration = frame
            frames.clear()
            bytes = 0
            return true
        }
        val config = configuration ?: return false
        if (epoch(frame) != epoch(config)) return false
        if (isKeyFrame(frame)) {
            frames.clear()
            bytes = 0
        } else if (frames.isEmpty()) return false
        if (frames.size >= maxFrames || size(frame) > maxBytes - bytes) {
            frames.clear()
            bytes = 0
            return false
        }
        frames.add(frame)
        bytes += size(frame)
        return true
    }

    @Synchronized
    fun snapshot(): List<T> {
        val config = configuration ?: return emptyList()
        return if (frames.isEmpty()) emptyList() else listOf(config) + frames
    }

    /** A new viewer joins live audio, not the historical GOP's timeline.
     * Decode the complete chain at the join time so even an idle image is
     * presented, without replaying seconds of history or mutating the cache. */
    fun snapshotForPresentation(nowUs: Long, retime: (T, Long) -> T): List<T> =
        snapshot().map { if (isConfiguration(it)) it else retime(it, nowUs) }

    @Synchronized
    fun clear() {
        configuration = null
        frames.clear()
        bytes = 0
    }
}
