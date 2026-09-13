package com.xopmc.galaxybridge.service

import android.app.Activity
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.View
import com.xopmc.galaxybridge.BuildConfig
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/** Shell/DUMP-only generated A/V source, absent from all release and public variants.
 * No media input, network, files, focus requests, permissions, volume or settings changes. */
class AudioVideoQaActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private var track: AudioTrack? = null
    private var motion: AudioVideoQaView? = null
    private var started = false
    private val deadline = Runnable { stopFixture(); finish() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!BuildConfig.DEBUG || BuildConfig.DISTRIBUTION != "internal" || savedInstanceState != null) {
            finish()
            return
        }
        motion = AudioVideoQaView(this).also(::setContentView)
    }

    override fun onStart() {
        super.onStart()
        if (isFinishing || started) { finish(); return }
        started = true
        try {
            val pcm = audioVideoQaTone()
            val output = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .setAllowedCapturePolicy(AudioAttributes.ALLOW_CAPTURE_BY_ALL)
                    .build())
                .setAudioFormat(AudioFormat.Builder()
                    .setSampleRate(QA_AUDIO_SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build())
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(pcm.size * Short.SIZE_BYTES)
                .build()
            track = output
            check(output.state != AudioTrack.STATE_UNINITIALIZED)
            check(output.write(pcm, 0, pcm.size) == pcm.size)
            check(output.state == AudioTrack.STATE_INITIALIZED)
            motion?.start()
            handler.postDelayed(deadline, QA_AUDIO_DURATION_SECONDS * 1_000L)
            output.play()
            Log.i(TAG, "started duration_seconds=$QA_AUDIO_DURATION_SECONDS tone_hz=440 amplitude=0.01")
        } catch (error: RuntimeException) {
            Log.w(TAG, "start_failed type=${error.javaClass.simpleName}")
            stopFixture()
            finish()
        }
    }

    override fun onStop() {
        stopFixture()
        super.onStop()
    }

    override fun onDestroy() {
        stopFixture()
        super.onDestroy()
    }

    private fun stopFixture() {
        handler.removeCallbacks(deadline)
        motion?.stop()
        val output = track
        track = null
        if (output != null) {
            try { output.stop() } catch (_: RuntimeException) { }
            try {
                output.release()
                Log.i(TAG, "released")
            } catch (_: RuntimeException) { Log.w(TAG, "release_failed") }
        }
    }

    private companion object { const val TAG = "GalaxyBridgeAudioVideoQA" }
}

internal const val QA_AUDIO_SAMPLE_RATE = 48_000
internal const val QA_AUDIO_DURATION_SECONDS = 30

/** Fixed 1.0% full-scale 440 Hz PCM; bounded 2.88 MB mono buffer and 5 ms edge ramps. */
internal fun audioVideoQaTone(): ShortArray {
    val count = QA_AUDIO_SAMPLE_RATE * QA_AUDIO_DURATION_SECONDS
    val rampFrames = QA_AUDIO_SAMPLE_RATE / 200
    return ShortArray(count) { index ->
        val ramp = min(1.0, min(index, count - 1 - index).toDouble() / rampFrames)
        (Short.MAX_VALUE * 0.01 * ramp * sin(2.0 * PI * 440 * index / QA_AUDIO_SAMPLE_RATE)).toInt().toShort()
    }
}

private class AudioVideoQaView(activity: Activity) : View(activity), Choreographer.FrameCallback {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var active = false
    private var startMillis = 0L

    fun start() {
        if (active) return
        startMillis = SystemClock.elapsedRealtime()
        active = true
        Choreographer.getInstance().postFrameCallback(this)
    }

    fun stop() {
        active = false
        Choreographer.getInstance().removeFrameCallback(this)
    }

    override fun onDetachedFromWindow() { stop(); super.onDetachedFromWindow() }

    override fun doFrame(frameTimeNanos: Long) {
        if (!active) return
        invalidate()
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun onDraw(canvas: Canvas) {
        val elapsed = (SystemClock.elapsedRealtime() - startMillis).coerceAtLeast(0)
        canvas.drawColor(Color.rgb(12, 20, 36))
        paint.color = Color.rgb(60, 150, 255)
        val x = (elapsed % 2_000) / 2_000f * width
        canvas.drawRect(x, height * 0.35f, x + width * 0.12f, height * 0.8f, paint)
        paint.color = Color.WHITE
        paint.textSize = 24f * resources.displayMetrics.density
        canvas.drawText("SYNTHETIC A/V QA", 24f, height * 0.13f, paint)
        paint.textSize = 18f * resources.displayMetrics.density
        canvas.drawText("440 Hz / 1% / 30 seconds", 24f, height * 0.21f, paint)
        canvas.drawText("${elapsed / 1_000}.${(elapsed % 1_000).toString().padStart(3, '0')} s", 24f, height * 0.29f, paint)
    }
}
