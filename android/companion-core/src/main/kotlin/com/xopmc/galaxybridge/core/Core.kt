package com.xopmc.galaxybridge.core

import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.min

class FrameTooLargeException(val actual: Int, val maximum: Int) :
    IllegalArgumentException("frame length $actual exceeds $maximum")

object ControlFrameCodec {
    fun encode(payload: ByteArray): ByteArray =
        ByteBuffer.allocate(Int.SIZE_BYTES + payload.size)
            .putInt(payload.size)
            .put(payload)
            .array()
}

class ControlFrameDecoder(private val maxPayloadLength: Int) {
    private var buffer = byteArrayOf()

    init {
        require(maxPayloadLength >= 0)
    }

    fun append(bytes: ByteArray): List<ByteArray> {
        buffer += bytes
        val frames = mutableListOf<ByteArray>()
        var consumed = 0
        while (buffer.size - consumed >= Int.SIZE_BYTES) {
            val length = ByteBuffer.wrap(buffer, consumed, Int.SIZE_BYTES).int
            if (length < 0 || length > maxPayloadLength) {
                throw FrameTooLargeException(length, maxPayloadLength)
            }
            val frameSize = Int.SIZE_BYTES + length
            if (buffer.size - consumed < frameSize) break
            frames += buffer.copyOfRange(consumed + Int.SIZE_BYTES, consumed + frameSize)
            consumed += frameSize
        }
        if (consumed > 0) buffer = buffer.copyOfRange(consumed, buffer.size)
        return frames
    }
}

object MediaPacketFlags {
    const val CONFIGURATION: UByte = 1u
    const val KEY_FRAME: UByte = 2u
}

class MediaPacket(
    val flags: UByte,
    val epoch: UInt,
    val presentationTimeUs: ULong,
    val payload: ByteArray,
)

object MediaPacketCodec {
    const val HEADER_LENGTH = 17

    fun encode(packet: MediaPacket): ByteArray =
        ByteBuffer.allocate(HEADER_LENGTH + packet.payload.size)
            .put(packet.flags.toByte())
            .putInt(packet.epoch.toInt())
            .putLong(packet.presentationTimeUs.toLong())
            .putInt(packet.payload.size)
            .put(packet.payload)
            .array()
}

class MediaPacketDecoder(private val maxPayloadLength: Int) {
    private var buffer = byteArrayOf()

    init {
        require(maxPayloadLength >= 0)
    }

    fun append(bytes: ByteArray): List<MediaPacket> {
        buffer += bytes
        val packets = mutableListOf<MediaPacket>()
        var consumed = 0
        while (buffer.size - consumed >= MediaPacketCodec.HEADER_LENGTH) {
            val header = ByteBuffer.wrap(buffer, consumed, MediaPacketCodec.HEADER_LENGTH)
            val flags = header.get().toUByte()
            val epoch = header.int.toUInt()
            val pts = header.long.toULong()
            val length = header.int
            if (length < 0 || length > maxPayloadLength) {
                throw FrameTooLargeException(length, maxPayloadLength)
            }
            val packetSize = MediaPacketCodec.HEADER_LENGTH + length
            if (buffer.size - consumed < packetSize) break
            packets += MediaPacket(
                flags,
                epoch,
                pts,
                buffer.copyOfRange(consumed + MediaPacketCodec.HEADER_LENGTH, consumed + packetSize),
            )
            consumed += packetSize
        }
        if (consumed > 0) buffer = buffer.copyOfRange(consumed, buffer.size)
        return packets
    }
}

class ReconnectBackoff {
    private val delays = longArrayOf(1_000, 2_000, 5_000, 10_000, 30_000)
    private var attempt = 0

    fun nextDelayMillis(): Long = delays[min(attempt++, delays.lastIndex)]

    fun reset() {
        attempt = 0
    }
}

enum class TransportKind(val priority: Int) {
    USB_ADB(3),
    WIRELESS_ADB(2),
    COMPANION_LAN(1),
}

object TransportSelector {
    fun preferred(transports: Set<TransportKind>): TransportKind? = transports.maxByOrNull { it.priority }
}

enum class Capability {
    SCREEN,
    INPUT,
    AUDIO,
    CLIPBOARD_READ,
    CLIPBOARD_WRITE,
    FILES,
    NOTIFICATIONS,
    SMS,
    CALLS,
    CAMERA,
    VIRTUAL_DISPLAY,
    RECORDING,
}

data class TransportSnapshot(
    val kind: TransportKind,
    val isConnected: Boolean,
    val capabilities: Set<Capability>,
)

object CapabilityResolver {
    fun routes(snapshots: List<TransportSnapshot>): Map<Capability, TransportKind> {
        val routes = mutableMapOf<Capability, TransportKind>()
        snapshots.filter { it.isConnected }.forEach { snapshot ->
            snapshot.capabilities.forEach { capability ->
                val current = routes[capability]
                if (current == null || snapshot.kind.priority > current.priority) {
                    routes[capability] = snapshot.kind
                }
            }
        }
        return routes
    }
}

enum class DeviceSessionState {
    DISCOVERED,
    PAIRING,
    CONNECTING,
    CONNECTED,
    DEGRADED,
    RECONNECTING,
    DISCONNECTED,
    REVOKED,
}

class InvalidSessionTransition(from: DeviceSessionState, to: DeviceSessionState) :
    IllegalStateException("invalid session transition $from -> $to")

class DeviceSessionStateMachine(initialState: DeviceSessionState) {
    var state: DeviceSessionState = initialState
        private set

    fun transitionTo(next: DeviceSessionState) {
        if ((state to next) !in allowedTransitions) throw InvalidSessionTransition(state, next)
        state = next
    }

    private companion object {
        val allowedTransitions = setOf(
            DeviceSessionState.DISCOVERED to DeviceSessionState.PAIRING,
            DeviceSessionState.DISCOVERED to DeviceSessionState.CONNECTING,
            DeviceSessionState.DISCOVERED to DeviceSessionState.DISCONNECTED,
            DeviceSessionState.DISCOVERED to DeviceSessionState.REVOKED,
            DeviceSessionState.PAIRING to DeviceSessionState.CONNECTING,
            DeviceSessionState.PAIRING to DeviceSessionState.DISCONNECTED,
            DeviceSessionState.PAIRING to DeviceSessionState.REVOKED,
            DeviceSessionState.CONNECTING to DeviceSessionState.CONNECTED,
            DeviceSessionState.CONNECTING to DeviceSessionState.RECONNECTING,
            DeviceSessionState.CONNECTING to DeviceSessionState.DISCONNECTED,
            DeviceSessionState.CONNECTING to DeviceSessionState.REVOKED,
            DeviceSessionState.CONNECTED to DeviceSessionState.DEGRADED,
            DeviceSessionState.CONNECTED to DeviceSessionState.RECONNECTING,
            DeviceSessionState.CONNECTED to DeviceSessionState.DISCONNECTED,
            DeviceSessionState.CONNECTED to DeviceSessionState.REVOKED,
            DeviceSessionState.DEGRADED to DeviceSessionState.CONNECTED,
            DeviceSessionState.DEGRADED to DeviceSessionState.RECONNECTING,
            DeviceSessionState.DEGRADED to DeviceSessionState.DISCONNECTED,
            DeviceSessionState.DEGRADED to DeviceSessionState.REVOKED,
            DeviceSessionState.RECONNECTING to DeviceSessionState.CONNECTED,
            DeviceSessionState.RECONNECTING to DeviceSessionState.DEGRADED,
            DeviceSessionState.RECONNECTING to DeviceSessionState.DISCONNECTED,
            DeviceSessionState.RECONNECTING to DeviceSessionState.REVOKED,
            DeviceSessionState.DISCONNECTED to DeviceSessionState.DISCOVERED,
            DeviceSessionState.DISCONNECTED to DeviceSessionState.CONNECTING,
            DeviceSessionState.DISCONNECTED to DeviceSessionState.REVOKED,
            DeviceSessionState.REVOKED to DeviceSessionState.PAIRING,
        )
    }
}

data class DisplayGeometry(val pixelWidth: Int, val pixelHeight: Int) {
    init {
        require(pixelWidth > 0 && pixelHeight > 0)
    }
}

data class PixelPoint(val x: Int, val y: Int)

data class NormalizedPoint(val x: Double, val y: Double) {
    fun pixelPoint(geometry: DisplayGeometry): PixelPoint {
        val safeX = if (x.isFinite()) x.coerceIn(0.0, 1.0) else 0.0
        val safeY = if (y.isFinite()) y.coerceIn(0.0, 1.0) else 0.0
        return PixelPoint(
            min((safeX * geometry.pixelWidth).toInt(), geometry.pixelWidth - 1),
            min((safeY * geometry.pixelHeight).toInt(), geometry.pixelHeight - 1),
        )
    }
}

class ClipboardItemIdentity(
    val originDeviceID: UUID,
    val sequence: Long,
    val contentSha256: ByteArray,
) {
    override fun equals(other: Any?): Boolean =
        other is ClipboardItemIdentity &&
            originDeviceID == other.originDeviceID &&
            sequence == other.sequence &&
            contentSha256.contentEquals(other.contentSha256)

    override fun hashCode(): Int =
        31 * (31 * originDeviceID.hashCode() + sequence.hashCode()) + contentSha256.contentHashCode()
}

class ClipboardLoopSuppressor(private val localDeviceID: UUID, private val capacity: Int = 256) {
    private var sequence = 1L
    private val seen = LinkedHashSet<ClipboardItemIdentity>()

    init {
        require(capacity > 0)
    }

    fun markPublished(content: ByteArray): ClipboardItemIdentity =
        ClipboardItemIdentity(localDeviceID, sequence++, sha256(content)).also(::remember)

    fun shouldAccept(identity: ClipboardItemIdentity): Boolean {
        if (identity.originDeviceID == localDeviceID || identity in seen) return false
        remember(identity)
        return true
    }

    private fun remember(identity: ClipboardItemIdentity) {
        if (!seen.add(identity)) return
        if (seen.size > capacity) seen.remove(seen.first())
    }
}

fun sha256(content: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(content)
