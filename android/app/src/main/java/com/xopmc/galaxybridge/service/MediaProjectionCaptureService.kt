package com.xopmc.galaxybridge.service

import android.app.Activity
import android.app.KeyguardManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.SystemClock
import android.os.Bundle
import android.util.DisplayMetrics
import android.view.Surface
import android.view.Display
import android.util.Log
import androidx.core.content.ContextCompat
import com.xopmc.galaxybridge.core.CompanionScreenPrivacyPolicy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt

data class EncodedVideoFrame(
    val flags: Int,
    val epoch: Int,
    val presentationTimeUs: Long,
    val payload: ByteArray,
    val sequence: Long = 0,
)

internal class ProjectionAvailabilityTracker {
    @Volatile
    var capturing: Boolean = false
        private set

    @Volatile
    var unavailableReason: String? = CompanionScreenPrivacyPolicy.MEDIA_PROJECTION_CONSENT_REQUIRED
        private set

    @Synchronized
    fun captureStarted() {
        capturing = true
        unavailableReason = null
    }

    @Synchronized
    fun projectionStopped(deviceLocked: Boolean) {
        capturing = false
        unavailableReason = CompanionScreenPrivacyPolicy.projectionUnavailableReason(deviceLocked)
    }

    @Synchronized
    fun captureEnded() {
        capturing = false
        if (unavailableReason == null) {
            unavailableReason = CompanionScreenPrivacyPolicy.MEDIA_PROJECTION_CONSENT_REQUIRED
        }
    }
}

object EncodedVideoBus {
    private val bootstrap = VideoBootstrapBuffer<EncodedVideoFrame>(
        maxBytes = 8 * 1024 * 1024, maxFrames = 240,
        epoch = { it.epoch },
        isConfiguration = { it.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 },
        isKeyFrame = { it.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0 },
        size = { it.payload.size },
    )
    fun bootstrapFrames(): List<EncodedVideoFrame> = bootstrap.snapshotForPresentation(System.nanoTime() / 1_000) {
        frame, now -> frame.copy(presentationTimeUs = now)
    }
    private val sequence = AtomicLong()
    @Volatile internal var keyFrameRequest: (() -> Unit)? = null
    fun requestKeyFrame() { keyFrameRequest?.invoke() }
    private val frameBuffer = RealtimeMediaFrameBuffer<EncodedVideoFrame>(capacity = 4)
    private val mutableCaptureState = MutableStateFlow(false)
    private val mutableUnavailableReason = MutableStateFlow<String?>(
        CompanionScreenPrivacyPolicy.MEDIA_PROJECTION_CONSENT_REQUIRED,
    )
    private val availability = ProjectionAvailabilityTracker()
    val frames = frameBuffer.frames
    val captureState = mutableCaptureState.asStateFlow()
    val unavailableReason = mutableUnavailableReason.asStateFlow()

    @Volatile
    var latestConfiguration: EncodedVideoFrame? = null
        private set

    internal fun emit(frame: EncodedVideoFrame) {
        val sequenced = frame.copy(sequence = sequence.incrementAndGet())
        if (frame.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) latestConfiguration = sequenced
        if (!bootstrap.offer(sequenced)) requestKeyFrame()
        frameBuffer.offer(sequenced)
    }

    @Synchronized
    internal fun setCapturing(capturing: Boolean) {
        if (capturing) availability.captureStarted() else availability.captureEnded()
        publishAvailability()
    }

    @Synchronized
    internal fun projectionStopped(deviceLocked: Boolean) {
        availability.projectionStopped(deviceLocked)
        publishAvailability()
    }

    private fun publishAvailability() {
        mutableCaptureState.value = availability.capturing
        mutableUnavailableReason.value = availability.unavailableReason
        if (!availability.capturing) {
            latestConfiguration = null
            bootstrap.clear()
        }
    }
}

data class EncodedAudioFrame(
    val flags: Int,
    val epoch: Int,
    val presentationTimeUs: Long,
    val payload: ByteArray,
)

object EncodedAudioBus {
    private val frameBuffer = RealtimeMediaFrameBuffer<EncodedAudioFrame>(capacity = 8)
    private val mutableCaptureState = MutableStateFlow(false)
    val frames = frameBuffer.frames
    val captureState = mutableCaptureState.asStateFlow()

    @Volatile
    var latestConfiguration: EncodedAudioFrame? = null
        private set

    internal fun emit(frame: EncodedAudioFrame) {
        if (frame.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) latestConfiguration = frame
        frameBuffer.offer(frame)
    }

    internal fun setCapturing(capturing: Boolean) {
        mutableCaptureState.value = capturing
        if (!capturing) latestConfiguration = null
    }

    internal fun rebaseEpoch(epoch: Int) {
        latestConfiguration?.copy(epoch = epoch)?.let(::emit)
    }
}

internal class MediaProjectionSessionGuard {
    private var generation = 0L

    fun beginSession(): Long {
        generation += 1
        return generation
    }

    fun invalidateCurrentSession() {
        generation += 1
    }

    inline fun runIfCurrent(sessionGeneration: Long, action: () -> Unit) {
        if (sessionGeneration == generation) action()
    }
}

internal class AudioPresentationTimebase(
    private val originTimeUs: Long,
    sampleRate: Int,
) {
    private val sampleRate = sampleRate.toLong().also { require(it > 0) }

    fun presentationTimeUs(frameOffset: Long): Long {
        require(frameOffset >= 0)
        val wholeSeconds = frameOffset / sampleRate
        val remainingFrames = frameOffset % sampleRate
        val wholeMicroseconds = saturatingMultiply(wholeSeconds, MICROSECONDS_PER_SECOND)
        val fractionalMicroseconds = remainingFrames * MICROSECONDS_PER_SECOND / sampleRate
        return saturatingAdd(
            originTimeUs,
            saturatingAdd(wholeMicroseconds, fractionalMicroseconds),
        )
    }

    fun advanceFrameOffset(current: Long, additionalFrames: Long): Long {
        require(current >= 0)
        require(additionalFrames >= 0)
        return saturatingAdd(current, additionalFrames)
    }

    private fun saturatingMultiply(left: Long, right: Long): Long =
        if (left == 0L || right == 0L) {
            0L
        } else if (left > Long.MAX_VALUE / right) {
            Long.MAX_VALUE
        } else {
            left * right
        }

    private fun saturatingAdd(left: Long, right: Long): Long =
        if (right > 0 && left > Long.MAX_VALUE - right) Long.MAX_VALUE else left + right

    private companion object {
        const val MICROSECONDS_PER_SECOND = 1_000_000L
    }
}

internal class MediaProjectionCodecSessionGuard<Codec : Any> {
    class Session<Codec : Any> internal constructor(
        internal val generation: Long,
        internal val codec: Codec,
        val epoch: Int,
    )

    private val lock = Any()
    private var generation = 0L
    private var currentSession: Session<Codec>? = null

    fun beginSession(codec: Codec, epoch: Int): Session<Codec> = synchronized(lock) {
        generation += 1
        Session(generation, codec, epoch).also { currentSession = it }
    }

    fun invalidateCurrentSession() = synchronized(lock) {
        generation += 1
        currentSession = null
    }

    fun isCurrent(session: Session<Codec>, callbackCodec: Codec): Boolean = synchronized(lock) {
        currentSession === session &&
            session.generation == generation &&
            session.codec === callbackCodec
    }

    fun handleOutput(
        session: Session<Codec>,
        callbackCodec: Codec,
        releaseOutput: () -> Unit,
        onCurrentReleaseFailure: (Throwable) -> Unit,
        emit: (epoch: Int) -> Unit,
    ) {
        try {
            runIfCurrent(session, callbackCodec) { emit(session.epoch) }
        } finally {
            runCatching(releaseOutput).exceptionOrNull()?.let { error ->
                runIfCurrent(session, callbackCodec) { onCurrentReleaseFailure(error) }
            }
        }
    }

    fun handleFormat(session: Session<Codec>, callbackCodec: Codec, emit: (epoch: Int) -> Unit) {
        runIfCurrent(session, callbackCodec) { emit(session.epoch) }
    }

    fun handleError(session: Session<Codec>, callbackCodec: Codec, stopCurrentService: () -> Unit) {
        runIfCurrent(session, callbackCodec, stopCurrentService)
    }

    private fun runIfCurrent(session: Session<Codec>, callbackCodec: Codec, action: () -> Unit) {
        synchronized(lock) {
            if (
                currentSession === session &&
                session.generation == generation &&
                session.codec === callbackCodec
            ) {
                action()
            }
        }
    }
}

class MediaProjectionCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var codecThread: HandlerThread? = null
    private var audioRecord: AudioRecord? = null
    private var audioThread: Thread? = null
    @Volatile private var audioRunning = false
    private val epoch = AtomicInteger(0)
    private val audioEpochLock = Any()
    private val projectionSessions = MediaProjectionSessionGuard()
    private val codecSessions = MediaProjectionCodecSessionGuard<MediaCodec>()
    private val displayRestarts = DisplayCaptureRestartCoordinator(DISPLAY_CHANGE_DEBOUNCE_MILLIS)
    private val mainHandler by lazy { Handler(mainLooper) }
    private var activeCaptureGeneration: Long? = null
    private var displayManager: DisplayManager? = null
    private var displayListener: DisplayManager.DisplayListener? = null
    private var pendingDisplayRestart: Runnable? = null
    private var pendingDisplayRequest: DisplayCaptureRestartCoordinator.RestartRequest? = null
    private var lastKeyFrameRequestAt = -1_000L

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, serviceNotification(capture = true))
        if (intent == null) return START_NOT_STICKY
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val resultData = intent.intentExtra(EXTRA_RESULT_DATA) ?: return START_NOT_STICKY
        if (resultCode != Activity.RESULT_OK) return START_NOT_STICKY
        stopCapture()
        startCapture(resultCode, resultData)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopCapture()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        observeDisplayGeometry()
    }

    private fun startCapture(resultCode: Int, resultData: Intent) {
        val manager = getSystemService(MediaProjectionManager::class.java)
        val nextProjection = manager.getMediaProjection(resultCode, resultData) ?: run {
            stopSelf()
            return
        }
        val sessionGeneration = projectionSessions.beginSession()
        projection = nextProjection
        nextProjection.registerCallback(
            object : MediaProjection.Callback() {
                override fun onStop() {
                    projectionSessions.runIfCurrent(sessionGeneration) {
                        val deviceLocked = getSystemService(KeyguardManager::class.java)
                            ?.isDeviceLocked == true
                        EncodedVideoBus.projectionStopped(deviceLocked)
                        stopSelf()
                    }
                }
            },
            Handler(mainLooper),
        )

        val transition = displayRestarts.beginCapture(currentDisplaySpec())
        activeCaptureGeneration = transition.captureGeneration
        registerDisplayListener(transition.captureGeneration)
        if (!startInitialVideoCapture(nextProjection, transition)) {
            stopSelf()
            return
        }
        GalaxyAccessibilityService.setRemoteKeyboardCaptureActive(true)
        startAudioCapture(nextProjection)
    }

    private fun startInitialVideoCapture(
        mediaProjection: MediaProjection,
        transition: DisplayCaptureRestartCoordinator.Transition,
    ): Boolean {
        val setup = encoderSetup(transition) ?: return false
        return runCatching {
            activateVideoEncoder(setup, transition)
            virtualDisplay = mediaProjection.createVirtualDisplay(
                "GalaxyBridge",
                setup.profile.width,
                setup.profile.height,
                transition.spec.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                setup.surface,
                null,
                mainHandler,
            )
            EncodedVideoBus.setCapturing(true)
        }.onFailure { error ->
            Log.e(TAG, "Unable to start display capture", error)
            releaseVideoEncoder()
        }.isSuccess
    }

    private fun restartVideoCapture(transition: DisplayCaptureRestartCoordinator.Transition): Boolean {
        val display = virtualDisplay ?: return false
        codecSessions.invalidateCurrentSession()
        runCatching { display.setSurface(null) }
        releaseVideoEncoder(invalidateSession = false)
        val setup = encoderSetup(transition) ?: return false
        return runCatching {
            activateVideoEncoder(setup, transition)
            display.resize(setup.profile.width, setup.profile.height, transition.spec.densityDpi)
            display.setSurface(setup.surface)
            EncodedVideoBus.setCapturing(true)
        }.onFailure { error ->
            Log.e(TAG, "Unable to resize display capture", error)
            releaseVideoEncoder()
        }.isSuccess
    }

    private fun activateVideoEncoder(
        setup: EncoderSetup,
        transition: DisplayCaptureRestartCoordinator.Transition,
    ) {
        encoder = setup.codec
        inputSurface = setup.surface
        codecThread = setup.callbackThread
        synchronized(audioEpochLock) {
            epoch.set(transition.epoch)
            EncodedAudioBus.rebaseEpoch(transition.epoch)
        }
        EncodedVideoBus.keyFrameRequest = {
            mainHandler.post {
                val now = SystemClock.uptimeMillis()
                if (encoder === setup.codec && now - lastKeyFrameRequestAt >= 250) {
                    lastKeyFrameRequestAt = now
                    runCatching {
                        setup.codec.setParameters(Bundle().apply {
                            putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                        })
                    }
                }
            }
        }
    }

    private fun encoderSetup(transition: DisplayCaptureRestartCoordinator.Transition): EncoderSetup? {
        val spec = transition.spec
        val profiles = listOf(
            captureProfile(spec.width, spec.height, MAX_DIMENSION, 60, 12_000_000),
            captureProfile(spec.width, spec.height, FALLBACK_MAX_DIMENSION, 30, 4_000_000),
        ).distinct()
        for (profile in profiles) {
            try {
                configureEncoder(profile, transition.epoch)?.let { return it }
            } catch (error: AsyncCodecPreparationCleanupException) {
                Log.e(TAG, "Video encoder cleanup failed; fallback is unsafe", error)
                return null
            }
        }
        return null
    }

    private fun registerDisplayListener(captureGeneration: Long) {
        val manager = getSystemService(DisplayManager::class.java)
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = Unit
            override fun onDisplayRemoved(displayId: Int) = Unit

            override fun onDisplayChanged(displayId: Int) {
                if (displayId == Display.DEFAULT_DISPLAY) observeDisplayGeometry(captureGeneration)
            }
        }
        displayManager = manager
        displayListener = listener
        manager.registerDisplayListener(listener, mainHandler)
    }

    private fun observeDisplayGeometry(expectedCaptureGeneration: Long? = activeCaptureGeneration) {
        val captureGeneration = expectedCaptureGeneration ?: return
        val spec = runCatching(::currentDisplaySpec).getOrElse { error ->
            Log.w(TAG, "Display geometry is temporarily unavailable", error)
            return
        }
        when (
            val observation = displayRestarts.observe(
                captureGeneration,
                spec,
                SystemClock.uptimeMillis(),
            )
        ) {
            DisplayCaptureRestartCoordinator.Observation.Ignored -> Unit
            DisplayCaptureRestartCoordinator.Observation.CancelPending -> cancelPendingDisplayRestart()
            is DisplayCaptureRestartCoordinator.Observation.Schedule -> scheduleDisplayRestart(observation.request)
        }
    }

    private fun scheduleDisplayRestart(request: DisplayCaptureRestartCoordinator.RestartRequest) {
        cancelPendingDisplayRestart()
        pendingDisplayRequest = request
        val callback = Runnable {
            if (pendingDisplayRequest !== request) return@Runnable
            pendingDisplayRequest = null
            pendingDisplayRestart = null
            val transition = displayRestarts.commit(request) ?: return@Runnable
            if (!restartVideoCapture(transition)) stopSelf()
        }
        pendingDisplayRestart = callback
        mainHandler.postDelayed(
            callback,
            (request.dueAtMillis - SystemClock.uptimeMillis()).coerceAtLeast(0),
        )
    }

    private fun cancelPendingDisplayRestart() {
        pendingDisplayRestart?.let(mainHandler::removeCallbacks)
        pendingDisplayRestart = null
        pendingDisplayRequest = null
    }

    @Suppress("DEPRECATION")
    private fun currentDisplaySpec(): CaptureDisplaySpec {
        val fallback = resources.displayMetrics
        val metrics = DisplayMetrics()
        val defaultDisplay = getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        if (defaultDisplay != null) defaultDisplay.getRealMetrics(metrics)
        val width = metrics.widthPixels.takeIf { it > 0 } ?: fallback.widthPixels
        val height = metrics.heightPixels.takeIf { it > 0 } ?: fallback.heightPixels
        val densityDpi = metrics.densityDpi.takeIf { it > 0 } ?: fallback.densityDpi
        return CaptureDisplaySpec(width, height, densityDpi)
    }

    private fun startAudioCapture(mediaProjection: MediaProjection) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            EncodedAudioBus.setCapturing(false)
            return
        }
        var pendingRecord: AudioRecord? = null
        var pendingCodec: MediaCodec? = null
        runCatching {
            val audioFormat = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(AUDIO_SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                .build()
            val playbackCapture = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val minimumBuffer = AudioRecord.getMinBufferSize(
                AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            require(minimumBuffer > 0)
            val bufferSize = maxOf(minimumBuffer * 2, AUDIO_INPUT_BUFFER_BYTES)
            val record = AudioRecord.Builder()
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferSize)
                .setAudioPlaybackCaptureConfig(playbackCapture)
                .build()
            pendingRecord = record
            check(record.state == AudioRecord.STATE_INITIALIZED)

            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            pendingCodec = codec
            val format = MediaFormat.createAudioFormat(
                MediaFormat.MIMETYPE_AUDIO_AAC,
                AUDIO_SAMPLE_RATE,
                AUDIO_CHANNELS,
            ).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, bufferSize)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            record.startRecording()
            check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING)
            val audioTimebase = AudioPresentationTimebase(
                originTimeUs = System.nanoTime() / 1_000L,
                sampleRate = AUDIO_SAMPLE_RATE,
            )

            audioRecord = record
            pendingRecord = null
            audioRunning = true
            EncodedAudioBus.setCapturing(true)
            audioThread = Thread(
                { pumpAudio(record, codec, audioTimebase) },
                "GalaxyBridgeAudioCodec",
            ).also { it.start() }
            pendingCodec = null
        }.onFailure { error ->
            runCatching { pendingRecord?.stop() }
            pendingRecord?.release()
            runCatching { pendingCodec?.stop() }
            pendingCodec?.release()
            Log.w(TAG, "Playback audio capture unavailable", error)
            stopAudioCapture()
        }
    }

    private fun pumpAudio(
        record: AudioRecord,
        codec: MediaCodec,
        audioTimebase: AudioPresentationTimebase,
    ) {
        val info = MediaCodec.BufferInfo()
        var submittedFrames = 0L
        try {
            while (audioRunning && !Thread.currentThread().isInterrupted) {
                val inputIndex = codec.dequeueInputBuffer(AUDIO_CODEC_TIMEOUT_US)
                if (inputIndex >= 0) {
                    val input = codec.getInputBuffer(inputIndex) ?: continue
                    input.clear()
                    val bytesRead = record.read(input, input.capacity(), AudioRecord.READ_BLOCKING)
                    if (bytesRead > 0) {
                        val presentationTimeUs = audioTimebase.presentationTimeUs(submittedFrames)
                        codec.queueInputBuffer(inputIndex, 0, bytesRead, presentationTimeUs, 0)
                        submittedFrames = audioTimebase.advanceFrameOffset(
                            current = submittedFrames,
                            additionalFrames = bytesRead.toLong() / (AUDIO_CHANNELS * PCM_BYTES_PER_SAMPLE),
                        )
                    } else {
                        codec.queueInputBuffer(inputIndex, 0, 0, 0, 0)
                    }
                }
                drainAudio(codec, info)
            }
        } catch (error: Throwable) {
            if (audioRunning) Log.w(TAG, "Playback audio encoder stopped", error)
        } finally {
            runCatching { record.stop() }
            record.release()
            runCatching { codec.stop() }
            codec.release()
            EncodedAudioBus.setCapturing(false)
        }
    }

    private fun drainAudio(codec: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            when (val outputIndex = codec.dequeueOutputBuffer(info, 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    codec.outputFormat.byteBufferOrNull("csd-0")?.remainingBytes()?.let { configuration ->
                        synchronized(audioEpochLock) {
                            EncodedAudioBus.emit(
                                EncodedAudioFrame(
                                    flags = MediaCodec.BUFFER_FLAG_CODEC_CONFIG,
                                    epoch = epoch.get(),
                                    presentationTimeUs = 0,
                                    payload = configuration,
                                ),
                            )
                        }
                    }
                }
                else -> if (outputIndex >= 0) {
                    val buffer = codec.getOutputBuffer(outputIndex)
                    if (buffer != null && info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val payload = ByteArray(info.size).also(buffer::get)
                        synchronized(audioEpochLock) {
                            EncodedAudioBus.emit(
                                EncodedAudioFrame(
                                    flags = info.flags,
                                    epoch = epoch.get(),
                                    presentationTimeUs = info.presentationTimeUs,
                                    payload = payload,
                                ),
                            )
                        }
                    }
                    codec.releaseOutputBuffer(outputIndex, false)
                }
            }
        }
    }

    private fun captureProfile(
        sourceWidth: Int,
        sourceHeight: Int,
        maximumDimension: Int,
        fps: Int,
        bitrate: Int,
    ): CaptureProfile {
        val longest = maxOf(sourceWidth, sourceHeight)
        val scale = minOf(1.0, maximumDimension.toDouble() / longest)
        return CaptureProfile(
            width = ((sourceWidth * scale).roundToInt() / 2 * 2).coerceAtLeast(2),
            height = ((sourceHeight * scale).roundToInt() / 2 * 2).coerceAtLeast(2),
            fps = fps,
            bitrate = bitrate,
        )
    }

    private fun configureEncoder(profile: CaptureProfile, captureEpoch: Int): EncoderSetup? = runCatching {
        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            profile.width,
            profile.height,
        ).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, profile.bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, profile.fps)
            // FRAME_RATE is a rate-control hint, not a surface-input cap.
            // Do not encode all 120 Hz display updates for a 60 fps stream.
            setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, profile.fps.toFloat())
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        }
        var codecSession: MediaProjectionCodecSessionGuard.Session<MediaCodec>? = null
        val prepared = AsyncCodecPreparer(
            createCodec = { MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC) },
            startCallbackThread = { HandlerThread("GalaxyBridgeVideoCodec").also { it.start() } },
            configureCodec = { codec ->
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            },
            createInputSurface = MediaCodec::createInputSurface,
            startCodec = MediaCodec::start,
            stopCodec = MediaCodec::stop,
            releaseCodec = MediaCodec::release,
            releaseSurface = Surface::release,
            quitCallbackThread = HandlerThread::quitSafely,
            onPreparationFailure = codecSessions::invalidateCurrentSession,
        ).prepare { codec, thread ->
            codecSession = codecSessions.beginSession(codec, captureEpoch)
            codec.setCallback(codecCallback(requireNotNull(codecSession)), Handler(thread.looper))
        } ?: return@runCatching null
        EncoderSetup(
            codec = prepared.codec,
            surface = prepared.surface,
            callbackThread = prepared.callbackThread,
            profile = profile,
        )
    }.getOrElse { error ->
        if (error is AsyncCodecPreparationCleanupException) throw error
        null
    }

    private fun codecCallback(
        session: MediaProjectionCodecSessionGuard.Session<MediaCodec>,
    ) = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            codecSessions.handleOutput(
                session,
                codec,
                releaseOutput = { codec.releaseOutputBuffer(index, false) },
                onCurrentReleaseFailure = { error ->
                    Log.e(TAG, "Current video codec output buffer release failed", error)
                    mainHandler.post {
                        codecSessions.handleError(session, codec) {
                            EncodedVideoBus.setCapturing(false)
                            stopSelf()
                        }
                    }
                },
            ) { captureEpoch ->
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val payload = ByteArray(info.size)
                    buffer.get(payload)
                    EncodedVideoBus.emit(
                        EncodedVideoFrame(
                            flags = info.flags,
                            epoch = captureEpoch,
                            presentationTimeUs = info.presentationTimeUs,
                            payload = AvcElementaryStream.toAnnexB(payload),
                        ),
                    )
                }
            }
        }

        override fun onError(codec: MediaCodec, exception: MediaCodec.CodecException) {
            codecSessions.handleError(session, codec) { stopSelf() }
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            codecSessions.handleFormat(session, codec) { captureEpoch ->
                val parameterSets = listOf("csd-0", "csd-1")
                    .mapNotNull { key -> format.byteBufferOrNull(key)?.remainingBytes() }
                    .fold(ByteArray(0)) { accumulated, bytes -> accumulated + AvcElementaryStream.toAnnexB(bytes) }
                if (parameterSets.isNotEmpty()) {
                    EncodedVideoBus.emit(
                        EncodedVideoFrame(
                            flags = MediaCodec.BUFFER_FLAG_CODEC_CONFIG,
                            epoch = captureEpoch,
                            presentationTimeUs = 0,
                            payload = parameterSets,
                        ),
                    )
                }
            }
        }
    }

    private fun stopCapture() {
        projectionSessions.invalidateCurrentSession()
        displayRestarts.invalidateCapture()
        activeCaptureGeneration = null
        cancelPendingDisplayRestart()
        displayListener?.let { listener -> displayManager?.unregisterDisplayListener(listener) }
        displayListener = null
        displayManager = null
        codecSessions.invalidateCurrentSession()
        stopAudioCapture()
        EncodedVideoBus.setCapturing(false)
        GalaxyAccessibilityService.setRemoteKeyboardCaptureActive(false)
        virtualDisplay?.release()
        virtualDisplay = null
        releaseVideoEncoder(invalidateSession = false)
        projection?.stop()
        projection = null
    }

    private fun releaseVideoEncoder(invalidateSession: Boolean = true) {
        EncodedVideoBus.keyFrameRequest = null
        if (invalidateSession) codecSessions.invalidateCurrentSession()
        inputSurface?.release()
        inputSurface = null
        runCatching { encoder?.stop() }
        encoder?.release()
        encoder = null
        codecThread?.quitSafely()
        codecThread = null
    }

    private fun stopAudioCapture() {
        audioRunning = false
        runCatching { audioRecord?.stop() }
        audioThread?.interrupt()
        runCatching { audioThread?.join(1_000) }
        audioThread = null
        audioRecord = null
        EncodedAudioBus.setCapturing(false)
    }

    @Suppress("DEPRECATION")
    private fun Intent.intentExtra(name: String): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            getParcelableExtra(name, Intent::class.java)
        } else {
            getParcelableExtra(name)
        }

    companion object {
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_RESULT_DATA = "result_data"
        private const val NOTIFICATION_ID = 4_702
        private const val MAX_DIMENSION = 1_920
        private const val FALLBACK_MAX_DIMENSION = 1_280
        private const val TAG = "GalaxyBridgeCapture"
        private const val AUDIO_SAMPLE_RATE = 48_000
        private const val AUDIO_CHANNELS = 2
        private const val PCM_BYTES_PER_SAMPLE = 2
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_INPUT_BUFFER_BYTES = 32_768
        private const val AUDIO_CODEC_TIMEOUT_US = 10_000L
        private const val DISPLAY_CHANGE_DEBOUNCE_MILLIS = 150L
    }
}

private data class CaptureProfile(
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrate: Int,
)

private data class EncoderSetup(
    val codec: MediaCodec,
    val surface: Surface,
    val callbackThread: HandlerThread,
    val profile: CaptureProfile,
)

private fun MediaFormat.byteBufferOrNull(key: String): ByteBuffer? =
    if (containsKey(key)) getByteBuffer(key)?.duplicate() else null

private fun ByteBuffer.remainingBytes(): ByteArray = ByteArray(remaining()).also(::get)

internal object AvcElementaryStream {
    fun toAnnexB(payload: ByteArray): ByteArray {
        if (payload.size < 4 || hasStartCode(payload)) return payload
        var offset = 0
        val output = ArrayList<Byte>(payload.size + 16)
        while (offset + 4 <= payload.size) {
            val length = ((payload[offset].toInt() and 0xFF) shl 24) or
                ((payload[offset + 1].toInt() and 0xFF) shl 16) or
                ((payload[offset + 2].toInt() and 0xFF) shl 8) or
                (payload[offset + 3].toInt() and 0xFF)
            offset += 4
            if (length <= 0 || offset + length > payload.size) return payload
            output.add(0)
            output.add(0)
            output.add(0)
            output.add(1)
            repeat(length) { output.add(payload[offset + it]) }
            offset += length
        }
        if (offset != payload.size) return payload
        return output.toByteArray()
    }

    private fun hasStartCode(payload: ByteArray): Boolean =
        payload[0] == 0.toByte() && payload[1] == 0.toByte() &&
            (payload[2] == 1.toByte() || (payload[2] == 0.toByte() && payload[3] == 1.toByte()))
}
