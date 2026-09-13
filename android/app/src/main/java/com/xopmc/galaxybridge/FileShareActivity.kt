package com.xopmc.galaxybridge

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.xopmc.galaxybridge.service.GalaxyBridgeForegroundService
import com.xopmc.galaxybridge.transport.AndroidOutgoingFiles
import com.xopmc.galaxybridge.transport.FileSendPreview
import com.xopmc.galaxybridge.transport.FileSendPolicy
import com.xopmc.galaxybridge.transport.OutgoingFilePhase
import com.xopmc.galaxybridge.transport.terminal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** Only Direct/Internal manifests expose this single-file target. URI grants never leave the app. */
class FileShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!AndroidOutgoingFiles.enabled) { finish(); return }
        @Suppress("DEPRECATION")
        val uri = runCatching {
            if (intent.action == Intent.ACTION_SEND) intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri else null
        }.getOrNull()
        val invalid = intent.action == Intent.ACTION_SEND && !runCatching {
            FileSendPolicy.acceptsShare(intent.action, uri?.scheme, intent.clipData?.itemCount ?: 1,
                intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        }.getOrDefault(false)
        setContent {
            GalaxyBridgeTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    FileSendScreen(if (invalid) null else uri, invalid, ::finish)
                }
            }
        }
    }
}

@Composable private fun FileSendScreen(initialURI: Uri?, invalidShare: Boolean, close: () -> Unit) {
    val context = LocalContext.current
    val manager = remember { AndroidOutgoingFiles.get(context) }
    val scope = rememberCoroutineScope()
    var uri by remember { mutableStateOf(initialURI) }
    var preview by remember { mutableStateOf<FileSendPreview?>(null) }
    var error by remember { mutableStateOf(invalidShare) }
    var loading by remember { mutableStateOf(false) }
    var preparing by remember { mutableStateOf(false) }
    var preparation by remember { mutableStateOf<Job?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { selected ->
        if (selected != null) uri = selected
    }
    LaunchedEffect(uri) {
        preview = null
        val selected = uri ?: return@LaunchedEffect
        loading = true
        try { preview = manager.preview(selected); error = false }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { error = true }
        finally { loading = false }
    }
    BackHandler(preparing) { preparation?.cancel() }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.file_send_title), style = MaterialTheme.typography.headlineMedium)
        Text(stringResource(R.string.file_send_hint))
        if (manager.currentOwner() == null) Text(stringResource(R.string.file_send_pair_required))
        if (loading || preparing) Text(stringResource(R.string.file_send_preparing))
        preview?.let { selected ->
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(selected.name, style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.file_send_destination))
                    Button(enabled = !preparing && manager.currentOwner() == selected.owner, onClick = {
                        preparing = true
                        error = false
                        preparation = scope.launch {
                            var preparedID: String? = null
                            try {
                                // User-visible activity start; no background activity/permission launch.
                                ContextCompat.startForegroundService(context, Intent(context, GalaxyBridgeForegroundService::class.java))
                                val id = manager.prepare(selected)
                                preparedID = id
                                manager.enqueuePrepared(id, selected.owner)
                                preview = null
                                uri = null
                            } catch (cancelled: CancellationException) {
                                preparedID?.let { manager.cancel(it, selected.owner) }
                                throw cancelled
                            } catch (_: Exception) {
                                preparedID?.let { manager.cancel(it, selected.owner) }
                                error = true
                            }
                            finally { preparing = false; preparation = null }
                        }
                    }) { Text(stringResource(R.string.clipboard_share_send)) }
                }
            }
        }
        if (error) Text(stringResource(R.string.file_send_unavailable), color = MaterialTheme.colorScheme.error)
        if (preparing) TextButton(onClick = { preparation?.cancel() }) { Text(stringResource(R.string.action_cancel)) }
        Button(enabled = !preparing && !loading && manager.currentOwner() != null,
            onClick = { picker.launch(arrayOf("*/*")) }) { Text(stringResource(R.string.file_send_pick)) }
        OutgoingFilesList(manager)
        TextButton(onClick = { preparation?.cancel(); close() }) { Text(stringResource(R.string.action_close)) }
    }
}

@Composable internal fun OutgoingFilesPanel() {
    if (!AndroidOutgoingFiles.enabled) return
    val context = LocalContext.current
    val manager = remember { AndroidOutgoingFiles.get(context) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.file_send_title), style = MaterialTheme.typography.titleLarge)
        Button(onClick = { context.startActivity(Intent(context, FileShareActivity::class.java)) }) {
            Text(stringResource(R.string.file_send_pick))
        }
        OutgoingFilesList(manager)
    }
}

@Composable private fun OutgoingFilesList(manager: AndroidOutgoingFiles) {
    val state by manager.state.collectAsState()
    LaunchedEffect(manager) { manager.refresh() }
    if (state.storageError) Text(stringResource(R.string.file_send_unavailable), color = MaterialTheme.colorScheme.error)
    for (progress in state.transfers) {
        val record = progress.record
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(record.name, style = MaterialTheme.typography.titleSmall)
                Text(when (record.phase) {
                    OutgoingFilePhase.PREPARED -> stringResource(R.string.file_send_preparing)
                    OutgoingFilePhase.COMPLETED -> stringResource(R.string.file_send_completed, record.publishedName)
                    OutgoingFilePhase.CANCELLED -> stringResource(R.string.file_send_cancelled)
                    OutgoingFilePhase.CANCEL_REQUESTED -> stringResource(R.string.file_send_cancel_pending)
                    OutgoingFilePhase.PAUSED -> stringResource(R.string.file_send_failed)
                    OutgoingFilePhase.QUEUED -> if (progress.waiting)
                        stringResource(R.string.file_send_progress, progress.confirmedOffset, record.size)
                        else stringResource(R.string.file_send_waiting)
                })
                if (!record.terminal) Row {
                    if (record.phase != OutgoingFilePhase.PREPARED) TextButton(onClick = { manager.retry(record.id, record.owner) }) { Text(stringResource(R.string.clipboard_share_retry)) }
                    TextButton(onClick = { manager.cancel(record.id, record.owner) }) { Text(stringResource(R.string.action_cancel)) }
                }
            }
        }
    }
}
