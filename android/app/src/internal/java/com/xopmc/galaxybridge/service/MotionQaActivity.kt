package com.xopmc.galaxybridge.service

import android.app.Activity
import android.net.wifi.WifiManager
import android.os.Bundle
import android.util.Log
import android.view.Choreographer
import android.view.View
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import kotlin.math.max

/**
 * Internal-only, content-free motion source used to reproduce streaming congestion.
 * It requires android.permission.DUMP in the internal manifest, so only shell/system
 * callers can launch it. The production flavors never contain this activity.
 */
class MotionQaActivity : Activity() {
    private var latencyLock: WifiManager.WifiLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.BLACK
        window.navigationBarColor = Color.BLACK
        setContentView(MotionQaView(this))
    }

    override fun onStart() {
        super.onStart()
        // Explicit, shell-only experiment. Never change the default motion
        // fixture or claim that this foreground-only API works in background.
        if (intent.getBooleanExtra("qa_wifi_low_latency", false)) {
            try {
                val wifi = applicationContext.getSystemService(WifiManager::class.java)
                    ?: throw IllegalStateException("Wi-Fi service unavailable")
                val lock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "GalaxyBridge:MotionQA")
                lock.setReferenceCounted(false)
                latencyLock = lock
                lock.acquire()
                Log.i("GalaxyBridgeMotionQA", "wifi_low_latency_requested=1 held=${if (lock.isHeld) 1 else 0}")
            } catch (_: RuntimeException) {
                releaseLatencyLock()
                Log.w("GalaxyBridgeMotionQA", "wifi_low_latency_requested=1 unavailable=1")
            }
        }
    }

    override fun onStop() {
        try {
            releaseLatencyLock()
        } finally {
            super.onStop()
        }
    }

    private fun releaseLatencyLock() {
        val lock = latencyLock
        latencyLock = null
        try {
            if (lock?.isHeld == true) lock.release()
        } catch (_: RuntimeException) {
            Log.w("GalaxyBridgeMotionQA", "wifi_low_latency_release_failed=1")
        }
    }
}

internal data class MotionFrameState(
    val frameNumber: Long,
    val elapsedMillis: Long,
    val offsetPixels: Int,
)

internal fun motionFrameState(
    frameTimeNanos: Long,
    startTimeNanos: Long,
    cellSizePixels: Int,
): MotionFrameState {
    val safeCellSize = max(1, cellSizePixels)
    val elapsedNanos = (frameTimeNanos - startTimeNanos).coerceAtLeast(0L)
    val elapsedMillis = elapsedNanos / 1_000_000L
    val frameNumber = elapsedNanos / 16_666_667L
    val period = safeCellSize * 2L
    val offset = ((elapsedMillis * 180L / 1_000L) % period).toInt()
    return MotionFrameState(frameNumber, elapsedMillis, offset)
}

private class MotionQaView(activity: Activity) : View(activity), Choreographer.FrameCallback {
    private val darkPaint = Paint().apply { color = Color.rgb(12, 15, 20) }
    private val lightPaint = Paint().apply { color = Color.rgb(205, 216, 229) }
    private val accentPaint = Paint().apply { color = Color.rgb(55, 132, 255) }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 54f * resources.displayMetrics.scaledDensity
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    }
    private val smallTextPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 20f * resources.displayMetrics.scaledDensity
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
    }
    private val cellSize = (64f * resources.displayMetrics.density).toInt().coerceAtLeast(1)
    private var startTimeNanos = 0L
    private var state = MotionFrameState(0L, 0L, 0)
    private var scheduled = false

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        startTimeNanos = 0L
        scheduleFrame()
    }

    override fun onDetachedFromWindow() {
        scheduled = false
        Choreographer.getInstance().removeFrameCallback(this)
        super.onDetachedFromWindow()
    }

    override fun doFrame(frameTimeNanos: Long) {
        scheduled = false
        if (startTimeNanos == 0L) startTimeNanos = frameTimeNanos
        state = motionFrameState(frameTimeNanos, startTimeNanos, cellSize)
        invalidate()
        scheduleFrame()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(Color.BLACK)

        val offset = state.offsetPixels - (cellSize * 2)
        var row = -2
        var y = offset
        while (y < height + cellSize * 2) {
            var column = -2
            var x = offset
            while (x < width + cellSize * 2) {
                val paint = if ((row + column) and 1 == 0) lightPaint else darkPaint
                canvas.drawRect(
                    x.toFloat(),
                    y.toFloat(),
                    (x + cellSize).toFloat(),
                    (y + cellSize).toFloat(),
                    paint,
                )
                x += cellSize
                column += 1
            }
            y += cellSize
            row += 1
        }

        val bannerHeight = 150f * resources.displayMetrics.density
        canvas.drawRect(0f, 0f, width.toFloat(), bannerHeight, accentPaint)
        val seconds = state.elapsedMillis / 1_000.0
        canvas.drawText("FRAME ${state.frameNumber}", 32f, textPaint.textSize + 24f, textPaint)
        canvas.drawText(
            String.format(java.util.Locale.ROOT, "%.3f s  LOCAL MOTION QA", seconds),
            36f,
            textPaint.textSize + smallTextPaint.textSize + 44f,
            smallTextPaint,
        )
    }

    private fun scheduleFrame() {
        if (!scheduled && isAttachedToWindow) {
            scheduled = true
            Choreographer.getInstance().postFrameCallback(this)
        }
    }
}
