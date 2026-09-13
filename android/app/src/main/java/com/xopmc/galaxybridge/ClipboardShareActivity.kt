package com.xopmc.galaxybridge

import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.xopmc.galaxybridge.service.ClipboardBridge
import com.xopmc.galaxybridge.service.ClipboardChangeTracker
import com.xopmc.galaxybridge.service.ClipboardEchoSuppressor
import com.xopmc.galaxybridge.service.ClipboardImageCodec
import com.xopmc.galaxybridge.service.ClipboardOutboundResult
import com.xopmc.galaxybridge.service.ClipboardPayload
import com.xopmc.galaxybridge.service.ClipboardPayloadPolicy
import com.xopmc.galaxybridge.service.ClipboardSharePolicy
import com.xopmc.galaxybridge.service.SharedContentKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ClipboardShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            GalaxyBridgeTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    ClipboardShareScreen(intent = intent, onClose = ::finish)
                }
            }
        }
    }

    private suspend fun loadCandidate(intent: Intent): ShareLoadState = withContext(Dispatchers.IO) {
        val mimeType = intent.type
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
        ClipboardSharePolicy.text(intent.action, mimeType, text)?.let { descriptor ->
            val tracker = ClipboardChangeTracker(ClipboardEchoSuppressor())
            val payload = ClipboardPayloadPolicy.text(text ?: return@withContext ShareLoadState.Invalid, false, tracker)
                ?: return@withContext ShareLoadState.Invalid
            val preview = text.toString().take(PREVIEW_TEXT_CHARACTERS)
            return@withContext ShareLoadState.Ready(payload, descriptor.kind, preview, null)
        }

        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        val descriptor = ClipboardSharePolicy.image(intent.action, mimeType, uri?.scheme)
            ?: return@withContext ShareLoadState.Invalid
        val png = uri?.let { ClipboardImageCodec.readAsBoundedPng(contentResolver, it, mimeType) }
            ?: return@withContext ShareLoadState.Invalid
        val payload = ClipboardPayloadPolicy.png(
            png,
            sensitive = false,
            tracker = ClipboardChangeTracker(ClipboardEchoSuppressor()),
        ) ?: return@withContext ShareLoadState.Invalid
        ShareLoadState.Ready(payload, descriptor.kind, null, ClipboardImageCodec.decodePreview(png))
    }

    @Composable
    private fun ClipboardShareScreen(intent: Intent, onClose: () -> Unit) {
        var loadState by remember(intent) { mutableStateOf<ShareLoadState>(ShareLoadState.Loading) }
        var deliveryResult by remember { mutableStateOf<ClipboardOutboundResult?>(null) }
        LaunchedEffect(intent) { loadState = loadCandidate(intent) }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colorScheme.surfaceContainerLowest)
                .padding(horizontal = 24.dp, vertical = 28.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Text(
                text = stringResource(R.string.clipboard_share_title),
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold,
            )
            when (val current = loadState) {
                ShareLoadState.Loading -> Text(stringResource(R.string.clipboard_share_loading))
                ShareLoadState.Invalid -> {
                    Text(stringResource(R.string.clipboard_share_invalid))
                    TextButton(onClick = onClose) { Text(stringResource(R.string.action_close)) }
                }
                is ShareLoadState.Ready -> {
                    SharePreview(current)
                    deliveryResult?.let { result ->
                        Text(
                            text = stringResource(
                                when (result) {
                                    ClipboardOutboundResult.SENT -> R.string.clipboard_share_sent
                                    ClipboardOutboundResult.NO_CONNECTED_MAC -> R.string.clipboard_share_no_mac
                                    ClipboardOutboundResult.QUEUE_FULL -> R.string.clipboard_share_busy
                                },
                            ),
                            color = if (result == ClipboardOutboundResult.SENT) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.error
                            },
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(onClick = { deliveryResult = ClipboardBridge.outboundHub.publish(current.payload) }) {
                            Text(
                                stringResource(
                                    if (deliveryResult == null || deliveryResult == ClipboardOutboundResult.SENT) {
                                        R.string.clipboard_share_send
                                    } else {
                                        R.string.clipboard_share_retry
                                    },
                                ),
                            )
                        }
                        TextButton(onClick = onClose) { Text(stringResource(R.string.action_cancel)) }
                    }
                }
            }
        }
    }

    @Composable
    private fun SharePreview(candidate: ShareLoadState.Ready) {
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(28.dp),
            color = MaterialTheme.colorScheme.surfaceContainerHigh,
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    text = stringResource(
                        when (candidate.kind) {
                            SharedContentKind.TEXT -> R.string.clipboard_share_text_preview
                            SharedContentKind.URL -> R.string.clipboard_share_url_preview
                            SharedContentKind.IMAGE -> R.string.clipboard_share_image_preview
                        },
                    ),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                candidate.previewText?.let { Text(it, style = MaterialTheme.typography.bodyLarge) }
                candidate.previewBitmap?.let { bitmap ->
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = stringResource(R.string.clipboard_share_image_preview),
                        modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp),
                        contentScale = ContentScale.Fit,
                    )
                }
            }
        }
    }

    private sealed interface ShareLoadState {
        data object Loading : ShareLoadState
        data object Invalid : ShareLoadState
        data class Ready(
            val payload: ClipboardPayload,
            val kind: SharedContentKind,
            val previewText: String?,
            val previewBitmap: Bitmap?,
        ) : ShareLoadState
    }

    private companion object {
        const val PREVIEW_TEXT_CHARACTERS = 800
    }
}
