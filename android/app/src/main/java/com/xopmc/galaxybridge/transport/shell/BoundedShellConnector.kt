package com.xopmc.galaxybridge.transport.shell

import java.io.IOException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/** A caller-side deadline independent of the blocking native connect call.
 * Closing the exact prepared socket is cancellation; no late success is admitted.
 * Even a broken platform connect cannot create an unbounded number of workers. */
internal object BoundedShellConnector {
    private val workers = ThreadPoolExecutor(4, 4, 10, TimeUnit.SECONDS, ArrayBlockingQueue(32),
        { task -> Thread(task, "GalaxyBridge-shell-connect").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy()).apply { allowCoreThreadTimeOut(true) }

    fun connect(timeoutMillis: Long = 3_000, cancelled: () -> Boolean, close: () -> Unit, connect: () -> Unit) {
        require(timeoutMillis in 1..3_000)
        val abandoned = AtomicBoolean(false)
        val task = FutureTask {
            try { connect() } finally { if (abandoned.get()) runCatching(close) }
        }
        var admitted = false
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        try {
            if (cancelled() || Thread.currentThread().isInterrupted) throw IOException("shell_connect_cancelled")
            workers.execute(task)
            while (true) {
                if (cancelled() || Thread.currentThread().isInterrupted) throw IOException("shell_connect_cancelled")
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) throw IOException("shell_connect_timeout")
                try {
                    task.get(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(20)), TimeUnit.NANOSECONDS)
                    if (cancelled()) throw IOException("shell_connect_cancelled")
                    if (System.nanoTime() >= deadline) throw IOException("shell_connect_timeout")
                    admitted = true
                    return
                } catch (_: TimeoutException) { /* Check cancellation and absolute deadline again. */ }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            throw IOException("shell_connect_cancelled")
        } catch (_: RejectedExecutionException) {
            throw IOException("shell_connect_busy")
        } catch (error: ExecutionException) {
            throw IOException("shell_connect_failed", error.cause)
        } finally {
            if (!admitted) {
                abandoned.set(true)
                runCatching(close)
                task.cancel(true)
                workers.remove(task)
            }
        }
    }
}

internal object ShellSocketRetirement {
    fun close(shutdownInput: () -> Unit, shutdownOutput: () -> Unit, close: () -> Unit) {
        // Os.close alone need not wake another thread retaining a kernel socket
        // reference in read/connect. Attempt both shutdown directions first.
        runCatching(shutdownInput)
        runCatching(shutdownOutput)
        runCatching(close)
    }
}

internal enum class ShellActivationStage(val code: String) {
    PREPARE("prepare"), CONNECT("connect"), PEER_UID("peer_uid"), PEER_PID("peer_pid"),
    TIMEOUT("timeout"), OWNER_WRITE("owner_write"), OWNER_READ("owner_read"), READY_CHECK("ready_check"), PROMOTE("promote")
}
internal class ShellActivationFailure(val stage: ShellActivationStage, cause: Throwable) :
    IOException("shell_activation_failed", cause)

/** Only fixed stage/category codes cross the diagnostic boundary; never Throwable messages. */
internal object ShellActivationDiagnostics {
    private val nativeErrors = listOf(
        "eacces" to listOf("EACCES", "Permission denied"),
        "eperm" to listOf("EPERM", "Operation not permitted"),
        "econnrefused" to listOf("ECONNREFUSED", "Connection refused"),
        "enoent" to listOf("ENOENT", "No such file or directory"),
        "timeout" to listOf("ETIMEDOUT", "Connection timed out"),
        "reset" to listOf("ECONNRESET", "Connection reset by peer"),
        "epipe" to listOf("EPIPE", "Broken pipe")
    ).map { (category, phrases) -> category to phrases.map {
        Regex("(?<![a-zA-Z0-9_])" + Regex.escape(it) + "(?![a-zA-Z0-9_])", RegexOption.IGNORE_CASE)
    } }
    private fun nativeMessageCategory(causes: List<Throwable>): String? {
        // Android connectLocal may throw IOException(strerror(errno)) with no
        // ErrnoException cause. Inspect a bounded prefix; emit only whitelist codes.
        for (cause in causes.filterIsInstance<IOException>()) {
            val message = cause.message?.take(512) ?: continue
            nativeErrors.firstOrNull { (_, patterns) -> patterns.any { it.containsMatchIn(message) } }?.let { return it.first }
        }
        return null
    }
    fun publicCode(error: Throwable): String {
        val failure = error as? ShellActivationFailure ?: return "shell_activation_failed"
        val causes = generateSequence(failure.cause) { it.cause }.take(8).toList()
        val errno = causes.filterIsInstance<android.system.ErrnoException>().firstOrNull()?.errno
        val nativeMessage = nativeMessageCategory(causes)
        val category = when (errno) {
            android.system.OsConstants.EPERM -> "eperm"
            android.system.OsConstants.EACCES -> "eacces"
            android.system.OsConstants.ENOENT -> "enoent"
            android.system.OsConstants.ECONNREFUSED -> "econnrefused"
            android.system.OsConstants.ETIMEDOUT -> "timeout"
            android.system.OsConstants.ECONNRESET -> "reset"
            android.system.OsConstants.EPIPE -> "epipe"
            null -> when {
                causes.any { it is java.net.SocketTimeoutException || it.message == "shell_connect_timeout" } -> "timeout"
                causes.any { it.message == "shell_connect_cancelled" } -> "cancelled"
                causes.any { it.message == "shell_connect_busy" } -> "busy"
                causes.any { it is UnsupportedOperationException } -> "unsupported"
                causes.any { it is SecurityException } -> "security"
                causes.any { it is java.io.EOFException } -> "eof"
                causes.any { it is IllegalStateException || it is IllegalArgumentException } -> "rejected"
                nativeMessage != null -> nativeMessage
                causes.any { it is IOException } -> "io"
                else -> "other"
            }
            else -> "errno_other"
        }
        return "shell_activation_${failure.stage.code}_$category"
    }
}

/** Retains a factory result until accepted, and retires descriptors returned after cancellation. */
internal object BoundedShellResource {
    fun <T : Any> open(timeoutMillis: Long = 3_000, cancelled: () -> Boolean,
        retire: (T) -> Unit, factory: () -> T): T {
        val pending = java.util.concurrent.atomic.AtomicReference<T?>()
        BoundedShellConnector.connect(timeoutMillis, cancelled, {
            pending.getAndSet(null)?.let { retire(it) }
        }) { pending.set(factory()) }
        return pending.getAndSet(null) ?: throw IOException("shell_open_cancelled")
    }
}
