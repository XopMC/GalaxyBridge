package com.xopmc.galaxybridge

import android.app.NotificationManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.dimensionResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.xopmc.galaxybridge.service.AndroidCameraStartGateway
import com.xopmc.galaxybridge.service.CameraCapturePhase
import com.xopmc.galaxybridge.service.CameraCaptureStatus
import com.xopmc.galaxybridge.service.CameraCaptureStatusBus
import com.xopmc.galaxybridge.service.CameraStartAttempt
import com.xopmc.galaxybridge.service.CameraStartCoordinator
import com.xopmc.galaxybridge.service.cameraCaptureRequest

class CameraStartConfirmationActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val request = intent.cameraCaptureRequest() ?: run {
            finish()
            return
        }
        setContent {
            GalaxyBridgeTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    CameraStartConfirmation(
                        onConfirm = {
                            val status = CameraStartCoordinator(AndroidCameraStartGateway(this)).apply(request)
                            if (status.phase == CameraCapturePhase.STARTING) {
                                cancelConfirmationNotification()
                                finish()
                            }
                        },
                        onCancel = {
                            CameraCaptureStatusBus.publish(
                                CameraCaptureStatus(
                                    requestId = request.requestId,
                                    phase = CameraCapturePhase.FAILED,
                                    reasonCode = "camera_confirmation_cancelled",
                                    retryable = true,
                                ),
                            )
                            cancelConfirmationNotification()
                            finish()
                        },
                    )
                }
            }
        }
    }

    private fun cancelConfirmationNotification() {
        getSystemService(NotificationManager::class.java)
            .cancel(AndroidCameraStartGateway.CAMERA_CONFIRMATION_NOTIFICATION_ID)
    }
}

@Composable
private fun CameraStartConfirmation(onConfirm: () -> Unit, onCancel: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.surfaceContainerLowest)
            .safeDrawingPadding()
            .padding(
                horizontal = dimensionResource(R.dimen.one_ui_content_horizontal),
                vertical = dimensionResource(R.dimen.one_ui_content_top),
            ),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Text(
            text = stringResource(R.string.camera_confirmation_title),
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
        )
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(28.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        ) {
            Column(
                modifier = Modifier.padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                Text(
                    text = stringResource(R.string.camera_confirmation_body),
                    style = MaterialTheme.typography.bodyLarge,
                )
                Button(onClick = onConfirm, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.camera_confirmation_action))
                }
                OutlinedButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.action_cancel))
                }
            }
        }
    }
}
