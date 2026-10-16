package com.xopmc.galaxybridge.transport.shell

import android.os.IBinder
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import android.system.StructTimeval
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** Owns the Helper-created socket-pair endpoint; no abstract connect or public port. */
internal class ShellFDChannel private constructor(private val descriptor: ParcelFileDescriptor,
    private val outputDescriptor: ParcelFileDescriptor) : AutoCloseable {
    val input: InputStream = ParcelFileDescriptor.AutoCloseInputStream(descriptor)
    val output: OutputStream = ParcelFileDescriptor.AutoCloseOutputStream(outputDescriptor)
    private val closed = AtomicBoolean(false)
    fun timeout(millis: Long) {
        val value = StructTimeval.fromMillis(millis)
        Os.setsockoptTimeval(descriptor.fileDescriptor, OsConstants.SOL_SOCKET, OsConstants.SO_RCVTIMEO, value)
        Os.setsockoptTimeval(descriptor.fileDescriptor, OsConstants.SOL_SOCKET, OsConstants.SO_SNDTIMEO, value)
    }
    fun shutdownOutput() { Os.shutdown(descriptor.fileDescriptor, OsConstants.SHUT_WR) }
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { Os.shutdown(descriptor.fileDescriptor, OsConstants.SHUT_RDWR) }
        runCatching { output.close() }; runCatching { input.close() }
    }
    companion object {
        fun adopt(descriptor: ParcelFileDescriptor): ShellFDChannel {
            var duplicate: ParcelFileDescriptor? = null
            try {
                duplicate = ParcelFileDescriptor.dup(descriptor.fileDescriptor)
                return ShellFDChannel(descriptor, duplicate)
            } catch (error: Exception) {
                duplicate?.let(::retireParcel); retireParcel(descriptor); throw error
            }
        }
        fun retireParcel(descriptor: ParcelFileDescriptor) {
            runCatching { Os.shutdown(descriptor.fileDescriptor, OsConstants.SHUT_RDWR) }
            runCatching { descriptor.close() }
        }
    }
}

internal object ShellBinderEndpoint {
    const val DESCRIPTOR = "com.xopmc.galaxybridge.shellbridge.v1"
    const val OPEN_OWNER = 1
    const val OPEN_STREAM = 2
    fun open(bridge: IBinder, generation: String, token: String, streamID: String? = null,
        lifetime: IBinder? = null, cancelled: () -> Boolean): ShellFDChannel {
        // Both sockets are created in the Helper's UID/SELinux context. The
        // Helper may set timeouts on its own retained endpoint; shell only uses
        // the explicitly transferred peer endpoint.
        val pair = ParcelFileDescriptor.createSocketPair()
        val local = pair[0]; val peer = pair[1]
        val peerClaimed = AtomicBoolean(false)
        val peerClosed = AtomicBoolean(false)
        fun closePeerCopy() { if (peerClosed.compareAndSet(false, true)) runCatching { peer.close() } }
        try {
            BoundedShellConnector.connect(cancelled = cancelled, close = { ShellFDChannel.retireParcel(local) }) {
                check(peerClaimed.compareAndSet(false, true)) { "shell_open_cancelled" }
                val request = Parcel.obtain(); val reply = Parcel.obtain()
                try {
                    request.writeInterfaceToken(DESCRIPTOR)
                    request.writeString(generation); request.writeString(token)
                    if (streamID == null) request.writeStrongBinder(requireNotNull(lifetime)) else request.writeString(streamID)
                    peer.writeToParcel(request, 0)
                    // Parcel owns its duplicate now. Never shutdown the sent peer:
                    // that would also shut down the shell's received endpoint.
                    closePeerCopy()
                    check(!cancelled()) { "shell_open_cancelled" }
                    check(bridge.transact(if (streamID == null) OPEN_OWNER else OPEN_STREAM, request, reply, 0)) { "shell_binder_transaction_rejected" }
                    reply.readException()
                    check(reply.dataAvail() == 0) { "shell_binder_reply_invalid" }
                } finally { closePeerCopy(); reply.recycle(); request.recycle() }
            }
            return ShellFDChannel.adopt(local)
        } catch (error: Exception) {
            ShellFDChannel.retireParcel(local)
            throw error
        } finally {
            // If the bounded worker never started, the caller still owns peer.
            // Otherwise only that worker may close it during serialization.
            if (peerClaimed.compareAndSet(false, true)) closePeerCopy()
        }
    }
}
