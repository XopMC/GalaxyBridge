package com.xopmc.galaxybridge.service

import android.Manifest
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class EncodedCameraFrame(
    val flags: Int,
    val epoch: Int,
    val presentationTimeUs: Long,
    val payload: ByteArray,
)

object EncodedCameraBus {
    private val frameBuffer = RealtimeCameraFrameBuffer(capacity = 4)
    private val mutableState = MutableStateFlow(false)
    val frames = frameBuffer.frames
    val captureState = mutableState.asStateFlow()

    @Volatile
    var latestConfiguration: EncodedCameraFrame? = null
        private set

    internal fun emit(frame: EncodedCameraFrame): Boolean {
        if (frame.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) latestConfiguration = frame
        return frameBuffer.offer(frame)
    }

    internal fun setCapturing(value: Boolean) {
        mutableState.value = value
        if (!value) latestConfiguration = null
    }
}

class CameraCaptureService : Service(), LifecycleOwner {
    override val lifecycle: Lifecycle get() = lifecycleRegistry
    private val lifecycleRegistry = LifecycleRegistry(this)
    private val cameraExecutor = Executors.newSingleThreadExecutor()
    private val epoch = AtomicInteger(0)
    private val sessions = CameraCaptureSessionGuard()
    private val encoderSessions = CameraEncoderSessionGuard<MediaCodec>()
    private val streamingReadiness = CameraStreamingReadiness()
    private var cameraProvider: ProcessCameraProvider? = null
    private var encoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private var codecThread: HandlerThread? = null
    private var activeRequestId = ""

    override fun onCreate() {
        super.onCreate()
        lifecycleRegistry.currentState = Lifecycle.State.CREATED
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val request = intent?.cameraCaptureRequest() ?: CameraCaptureRequest(
            requestId = intent?.getStringExtra(EXTRA_REQUEST_ID).orEmpty().ifBlank { "camera-service-$startId" },
            enabled = intent?.getBooleanExtra(EXTRA_ENABLED, true) ?: true,
            cameraId = intent?.getStringExtra(EXTRA_CAMERA_ID).orEmpty(),
            width = intent?.getIntExtra(EXTRA_WIDTH, 0) ?: 0,
            height = intent?.getIntExtra(EXTRA_HEIGHT, 0) ?: 0,
            framesPerSecond = intent?.getIntExtra(EXTRA_FPS, 0) ?: 0,
        )
        activeRequestId = request.requestId
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            publishFailure("camera_permission_required", retryable = false)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            startForeground(NOTIFICATION_ID, cameraNotification())
        } catch (error: RuntimeException) {
            val attempt = CameraStartFailureClassifier.classify(
                cameraPermissionGranted = true,
                errorClassName = error.javaClass.name,
                securityException = error is SecurityException,
            )
            if (attempt == CameraStartAttempt.BACKGROUND_RESTRICTED &&
                AndroidCameraStartGateway(this).requestUserConfirmation(request)
            ) {
                CameraCaptureStatusBus.publish(
                    CameraCaptureStatus(
                        request.requestId,
                        CameraCapturePhase.AWAITING_USER_CONFIRMATION,
                        reasonCode = "camera_confirmation_required",
                        retryable = true,
                    ),
                )
            } else {
                publishFailure(
                    if (attempt == CameraStartAttempt.BACKGROUND_RESTRICTED) {
                        "camera_confirmation_unavailable"
                    } else {
                        "camera_start_failed"
                    },
                    retryable = true,
                )
            }
            stopSelf()
            return START_NOT_STICKY
        }
        if (!request.enabled) {
            stopSelf()
            return START_NOT_STICKY
        }
        val profile = CameraCaptureProfileResolver.resolve(
            requestedWidth = request.width,
            requestedHeight = request.height,
            requestedFps = request.framesPerSecond,
            requestedCameraId = request.cameraId,
        )
        stopCamera()
        startCamera(profile)
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopCamera()
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        cameraExecutor.shutdown()
        super.onDestroy()
    }

    private fun startCamera(profile: CameraCaptureProfile) {
        val session = sessions.beginSession(epoch.incrementAndGet())
        lifecycleRegistry.currentState = Lifecycle.State.STARTED
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener(
            {
                sessions.runIfCurrent(session) {
                    runCatching {
                        val provider = future.get()
                        cameraProvider = provider
                        val resolutionSelector = ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(profile.width, profile.height),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                ),
                            )
                            .build()
                        val preview = Preview.Builder()
                            .setResolutionSelector(resolutionSelector)
                            .setTargetFrameRate(Range(profile.fps, profile.fps))
                            .build()
                        preview.setSurfaceProvider(cameraExecutor) { request ->
                            if (!sessions.isCurrent(session)) {
                                request.willNotProvideSurface()
                                return@setSurfaceProvider
                            }
                            runCatching {
                                val actualProfile = profile.copy(
                                    width = request.resolution.width and -2,
                                    height = request.resolution.height and -2,
                                    bitRate = CameraCaptureProfileResolver.recommendedBitRate(
                                        request.resolution.width,
                                        request.resolution.height,
                                        profile.fps,
                                    ),
                                )
                                val activeEncoder = startEncoder(actualProfile, session)
                                // CameraX completes this callback while unbind/destroy is still
                                // draining. The service-owned worker is intentionally shut down in
                                // onDestroy(), so using it here races the completion dispatch and
                                // produces RejectedExecutionException on every clean camera stop.
                                request.provideSurface(
                                    activeEncoder.surface,
                                    ContextCompat.getMainExecutor(this),
                                ) { result ->
                                    if (result.resultCode != androidx.camera.core.SurfaceRequest.Result.RESULT_SURFACE_USED_SUCCESSFULLY) {
                                        encoderSessions.runIfCurrent(activeEncoder.session, activeEncoder.codec) {
                                            sessions.runIfCurrent(session) { stopSelf() }
                                        }
                                    }
                                }
                            }.onFailure {
                                request.willNotProvideSurface()
                                sessions.runIfCurrent(session) { stopSelf() }
                            }
                        }
                        provider.unbindAll()
                        provider.bindToLifecycle(
                            this,
                            if (profile.frontCamera) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA,
                            preview,
                        )
                    }.onFailure {
                        publishFailure("camera_capture_failed", retryable = true)
                        stopSelf()
                    }
                }
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    private fun startEncoder(
        profile: CameraCaptureProfile,
        session: CameraCaptureSessionGuard.Session,
    ): ActiveCameraEncoder {
        stopEncoder()
        val nextEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            profile.width,
            profile.height,
        ).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, profile.bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, profile.fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
        }
        nextEncoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = nextEncoder.createInputSurface()
        encoder = nextEncoder
        encoderSurface = surface
        val encoderSession = encoderSessions.beginSession(nextEncoder, session.epoch)
        streamingReadiness.begin(encoderSession.epoch)
        val thread = HandlerThread("GalaxyBridgeCameraCodec").also { it.start() }
        codecThread = thread
        nextEncoder.setCallback(codecCallback(encoderSession), Handler(thread.looper))
        nextEncoder.start()
        EncodedCameraBus.setCapturing(true)
        return ActiveCameraEncoder(surface, nextEncoder, encoderSession)
    }

    private fun codecCallback(session: CameraEncoderSessionGuard.Session<MediaCodec>) = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            encoderSessions.handleOutput(
                session,
                codec,
                releaseOutput = { runCatching { codec.releaseOutputBuffer(index, false) } },
            ) { capturedEpoch ->
                codec.getOutputBuffer(index)?.let { buffer ->
                    if (info.size > 0) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val payload = ByteArray(info.size)
                        buffer.get(payload)
                        val frame = EncodedCameraFrame(
                            info.flags,
                            capturedEpoch,
                            info.presentationTimeUs,
                            AvcElementaryStream.toAnnexB(payload),
                        )
                        val offered = EncodedCameraBus.emit(frame)
                        if (offered && streamingReadiness.shouldAnnounce(capturedEpoch, info.flags, info.size)) {
                            CameraCaptureStatusBus.publish(
                                CameraCaptureStatus(activeRequestId, CameraCapturePhase.STREAMING),
                            )
                        }
                    }
                }
            }
        }

        override fun onError(codec: MediaCodec, exception: MediaCodec.CodecException) {
            encoderSessions.runIfCurrent(session, codec) {
                publishFailure("camera_encoder_failed", retryable = true)
                stopSelf()
            }
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            encoderSessions.runIfCurrent(session, codec) {
                val parameterSets = listOf("csd-0", "csd-1")
                    .mapNotNull { key -> format.cameraByteBuffer(key)?.cameraRemainingBytes() }
                    .fold(ByteArray(0)) { accumulated, bytes -> accumulated + AvcElementaryStream.toAnnexB(bytes) }
                if (parameterSets.isNotEmpty()) {
                    EncodedCameraBus.emit(
                        EncodedCameraFrame(MediaCodec.BUFFER_FLAG_CODEC_CONFIG, session.epoch, 0, parameterSets),
                    )
                }
            }
        }
    }

    private fun stopCamera() {
        sessions.invalidateCurrentSession()
        EncodedCameraBus.setCapturing(false)
        cameraProvider?.unbindAll()
        cameraProvider = null
        stopEncoder()
        if (lifecycleRegistry.currentState != Lifecycle.State.DESTROYED) {
            lifecycleRegistry.currentState = Lifecycle.State.CREATED
        }
    }

    private fun stopEncoder() {
        encoderSessions.invalidateCurrentSession()
        streamingReadiness.stop()
        val previousEncoder = encoder
        val previousSurface = encoderSurface
        val previousThread = codecThread
        encoder = null
        encoderSurface = null
        codecThread = null
        runCatching { previousEncoder?.stop() }
        previousEncoder?.release()
        previousSurface?.release()
        previousThread?.quitSafely()
    }

    private fun publishFailure(reasonCode: String, retryable: Boolean) {
        CameraCaptureStatusBus.publish(
            CameraCaptureStatus(
                requestId = activeRequestId,
                phase = CameraCapturePhase.FAILED,
                reasonCode = reasonCode,
                retryable = retryable,
            ),
        )
    }

    companion object {
        const val EXTRA_ENABLED = "enabled"
        const val EXTRA_REQUEST_ID = "request_id"
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_FPS = "fps"
        const val EXTRA_CAMERA_ID = "camera_id"
        private const val NOTIFICATION_ID = 4_703
    }
}

private data class ActiveCameraEncoder(
    val surface: Surface,
    val codec: MediaCodec,
    val session: CameraEncoderSessionGuard.Session<MediaCodec>,
)

private fun MediaFormat.cameraByteBuffer(key: String): ByteBuffer? =
    if (containsKey(key)) getByteBuffer(key)?.duplicate() else null

private fun ByteBuffer.cameraRemainingBytes(): ByteArray = ByteArray(remaining()).also(::get)
