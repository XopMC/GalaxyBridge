package com.xopmc.galaxybridge.service

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.xopmc.galaxybridge.CameraStartConfirmationActivity
import com.xopmc.galaxybridge.R

internal class AndroidCameraStartGateway(private val context: Context) : CameraStartGateway {
    override fun tryStart(request: CameraCaptureRequest): CameraStartAttempt {
        val permissionGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA,
        ) == PackageManager.PERMISSION_GRANTED
        if (!permissionGranted) return CameraStartAttempt.PERMISSION_MISSING

        return try {
            ContextCompat.startForegroundService(context, request.serviceIntent(context))
            CameraStartAttempt.ACCEPTED
        } catch (error: RuntimeException) {
            CameraStartFailureClassifier.classify(
                cameraPermissionGranted = permissionGranted,
                errorClassName = error.javaClass.name,
                securityException = error is SecurityException,
            )
        }
    }

    override fun requestUserConfirmation(request: CameraCaptureRequest): Boolean {
        if (!notificationsAvailable()) return false
        val manager = context.getSystemService(NotificationManager::class.java)
        context.ensureNotificationChannels()
        val confirmationIntent = Intent(context, CameraStartConfirmationActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putCameraCaptureRequest(request)
        val pendingIntent = PendingIntent.getActivity(
            context,
            request.requestId.hashCode(),
            confirmationIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(context, CAMERA_CONFIRMATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle(context.getString(R.string.camera_confirmation_notification_title))
            .setContentText(context.getString(R.string.camera_confirmation_notification_text))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_CALL)
            .addAction(
                Notification.Action.Builder(
                    null,
                    context.getString(R.string.camera_confirmation_action),
                    pendingIntent,
                ).build(),
            )
            .build()
        manager.notify(CAMERA_CONFIRMATION_NOTIFICATION_ID, notification)
        return true
    }

    override fun stop(request: CameraCaptureRequest) {
        context.getSystemService(NotificationManager::class.java)
            .cancel(CAMERA_CONFIRMATION_NOTIFICATION_ID)
        context.stopService(request.serviceIntent(context))
    }

    private fun notificationsAvailable(): Boolean {
        if (!context.getSystemService(NotificationManager::class.java).areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    companion object {
        const val CAMERA_CONFIRMATION_NOTIFICATION_ID = 4_704
    }
}

internal fun CameraCaptureRequest.serviceIntent(context: Context): Intent =
    Intent(context, CameraCaptureService::class.java)
        .putExtra(CameraCaptureService.EXTRA_REQUEST_ID, requestId)
        .putExtra(CameraCaptureService.EXTRA_ENABLED, enabled)
        .putExtra(CameraCaptureService.EXTRA_CAMERA_ID, cameraId)
        .putExtra(CameraCaptureService.EXTRA_WIDTH, width)
        .putExtra(CameraCaptureService.EXTRA_HEIGHT, height)
        .putExtra(CameraCaptureService.EXTRA_FPS, framesPerSecond)

internal fun Intent.putCameraCaptureRequest(request: CameraCaptureRequest): Intent =
    putExtra(CameraCaptureService.EXTRA_REQUEST_ID, request.requestId)
        .putExtra(CameraCaptureService.EXTRA_ENABLED, request.enabled)
        .putExtra(CameraCaptureService.EXTRA_CAMERA_ID, request.cameraId)
        .putExtra(CameraCaptureService.EXTRA_WIDTH, request.width)
        .putExtra(CameraCaptureService.EXTRA_HEIGHT, request.height)
        .putExtra(CameraCaptureService.EXTRA_FPS, request.framesPerSecond)

internal fun Intent.cameraCaptureRequest(): CameraCaptureRequest? {
    val requestId = getStringExtra(CameraCaptureService.EXTRA_REQUEST_ID).orEmpty()
    if (requestId.isBlank() || requestId.length > 128) return null
    return CameraCaptureRequest(
        requestId = requestId,
        enabled = getBooleanExtra(CameraCaptureService.EXTRA_ENABLED, true),
        cameraId = getStringExtra(CameraCaptureService.EXTRA_CAMERA_ID).orEmpty(),
        width = getIntExtra(CameraCaptureService.EXTRA_WIDTH, 0),
        height = getIntExtra(CameraCaptureService.EXTRA_HEIGHT, 0),
        framesPerSecond = getIntExtra(CameraCaptureService.EXTRA_FPS, 0),
    )
}
