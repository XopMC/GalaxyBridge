package com.xopmc.galaxybridge.nearby

import java.io.ByteArrayOutputStream

/** BLE is a byte stream of [uint32 BE length][opaque bootstrap frame]. No radio identity trust. */
internal class NearbyFrameDecoder {
    private val header = ByteArray(4)
    private var headerCount = 0
    private var expected = 0
    private val body = ByteArrayOutputStream()

    fun feed(bytes: ByteArray): List<ByteArray> {
        val frames = mutableListOf<ByteArray>()
        for (byte in bytes) {
            if (headerCount < 4) {
                header[headerCount++] = byte
                if (headerCount == 4) {
                    expected = header.fold(0L) { value, item -> (value shl 8) or (item.toLong() and 255) }.toInt()
                    require(expected in 1..MAX_FRAME) { "bootstrap_frame_size" }
                }
            } else {
                body.write(byte.toInt())
                if (body.size() == expected) {
                    frames += body.toByteArray()
                    body.reset()
                    headerCount = 0
                }
            }
        }
        return frames
    }

    companion object {
        const val MAX_FRAME = 65_536
        fun encode(frame: ByteArray): ByteArray {
            require(frame.size in 1..MAX_FRAME)
            return byteArrayOf((frame.size ushr 24).toByte(), (frame.size ushr 16).toByte(),
                (frame.size ushr 8).toByte(), frame.size.toByte()) + frame
        }
    }
}

interface NearbyGattSession : AutoCloseable {
    /** True only after an encrypted proof from the current handshake, not a replayable signed Hello. */
    val isAuthenticated: Boolean get() = false
    /** Authenticated bootstrap implementation supplies all protocol/crypto behavior. */
    fun receive(frame: ByteArray): List<ByteArray>
    override fun close()
}
