package com.xopmc.galaxybridge.service

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.PI
import kotlin.math.sin

/** Neutral, shell-only hardware fixture; absent from Direct and Play APKs. */
class InteractionQaActivity : Activity() {
    private var audio: AudioTrack? = null
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 64, 32, 32)
        }
        column.addView(TextView(this).apply { text = "Galaxy Bridge local interaction QA"; textSize = 22f })
        val input = EditText(this).apply {
            hint = "Type neutral test text here"
            setSingleLine(false)
            importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        }
        column.addView(input, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 240))
        column.addView(Button(this).apply {
            text = "Copy neutral text"
            setOnClickListener {
                getSystemService(ClipboardManager::class.java)
                    .setPrimaryClip(ClipData.newPlainText("Local QA", input.text.toString()))
            }
        })
        column.addView(Button(this).apply {
            text = "Play quiet 440 Hz tone for 5 seconds"
            setOnClickListener { playTone() }
        })
        setContentView(column)
    }

    private fun playTone() {
        stopTone()
        val samples = ShortArray(48_000) { (sin(2 * PI * 440 * it / 48_000) * 1024).toInt().toShort() }
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(48_000)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(samples.size * 2).build()
        audio = track
        track.write(samples, 0, samples.size)
        track.setLoopPoints(0, samples.size, -1)
        track.play()
        handler.postDelayed({ if (audio === track) stopTone() }, 5_000)
    }

    private fun stopTone() {
        audio?.let { runCatching { it.stop() }; it.release() }
        audio = null
        handler.removeCallbacksAndMessages(null)
    }

    override fun onDestroy() {
        stopTone()
        super.onDestroy()
    }
}
