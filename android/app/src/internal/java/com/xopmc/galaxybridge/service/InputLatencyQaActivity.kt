package com.xopmc.galaxybridge.service

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import android.view.View

/**
 * Internal-only, content-free response marker for end-to-end input latency QA.
 * The view is completely static until a real touch reaches Android. Every
 * ACTION_DOWN then changes the full background and visible sequence exactly
 * once, allowing the Mac's presented-frame probe to correlate dispatch with a
 * real visual response instead of unrelated animation.
 */
class InputLatencyQaActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(InputLatencyQaView(this))
    }
}

internal data class InputLatencyQaState(
    val sequence: Long,
    val backgroundArgb: Int,
    val foregroundArgb: Int,
)

internal fun nextInputLatencyQaState(currentSequence: Long): InputLatencyQaState {
    val nextSequence = currentSequence.coerceAtLeast(0L) + 1L
    return if (nextSequence and 1L == 0L) {
        InputLatencyQaState(nextSequence, 0xff123b7a.toInt(), 0xffffffff.toInt())
    } else {
        InputLatencyQaState(nextSequence, 0xffffb000.toInt(), 0xff101318.toInt())
    }
}

internal fun inputLatencyQaMarker(sequence: Long, eventUptimeMillis: Long): String =
    "down_sequence=$sequence event_uptime_ms=$eventUptimeMillis"

private class InputLatencyQaView(activity: Activity) : View(activity) {
    private val backgroundPaint = Paint()
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 64f * resources.displayMetrics.scaledDensity
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    }
    private val detailPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 22f * resources.displayMetrics.scaledDensity
        textAlign = Paint.Align.CENTER
        typeface = Typeface.create(Typeface.MONOSPACE, Typeface.NORMAL)
    }
    private var state = InputLatencyQaState(
        sequence = 0,
        backgroundArgb = 0xff123b7a.toInt(),
        foregroundArgb = 0xffffffff.toInt(),
    )

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                state = nextInputLatencyQaState(state.sequence)
                Log.i(
                    "GBInputLatencyQA",
                    inputLatencyQaMarker(state.sequence, event.eventTime),
                )
                invalidate()
                return true
            }
            MotionEvent.ACTION_UP -> {
                performClick()
                return true
            }
            MotionEvent.ACTION_CANCEL -> return true
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(state.backgroundArgb)
        textPaint.color = state.foregroundArgb
        detailPaint.color = state.foregroundArgb
        val centerX = width / 2f
        val centerY = height / 2f
        canvas.drawText("INPUT ${state.sequence}", centerX, centerY, textPaint)
        canvas.drawText(
            "GALAXY BRIDGE LATENCY QA",
            centerX,
            centerY + textPaint.textSize + 28f,
            detailPaint,
        )
    }
}
