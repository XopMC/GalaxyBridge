package com.xopmc.galaxybridge.transport

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.media.MediaCodec
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Base64
import android.util.Log
import com.google.protobuf.ByteString
import com.xopmc.galaxybridge.core.PairingTranscript
import com.xopmc.galaxybridge.core.CompanionRoutedFallback
import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.core.PairingUriCodec
import com.xopmc.galaxybridge.core.SessionAuthenticationTranscript
import com.xopmc.galaxybridge.security.DeviceIdentityStore
import com.xopmc.galaxybridge.security.DeviceIdStore
import com.xopmc.galaxybridge.protocol.v1.Capability
import com.xopmc.galaxybridge.protocol.v1.AdbBindingResponse
import com.xopmc.galaxybridge.protocol.v1.ChannelKind
import com.xopmc.galaxybridge.protocol.v1.ClipboardKind
import com.xopmc.galaxybridge.protocol.v1.ClipboardUpdate
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.Hello
import com.xopmc.galaxybridge.protocol.v1.InputAction
import com.xopmc.galaxybridge.protocol.v1.PairingResponse
import com.xopmc.galaxybridge.protocol.v1.Pong
import com.xopmc.galaxybridge.protocol.v1.TransportKind
import com.xopmc.galaxybridge.service.AndroidInputCommand
import com.xopmc.galaxybridge.service.CompanionPointerGestureAccumulator
import com.xopmc.galaxybridge.service.ClipboardBridge
import com.xopmc.galaxybridge.service.ClipboardImageCodec
import com.xopmc.galaxybridge.service.ClipboardPayloadPolicy
import com.xopmc.galaxybridge.service.CameraCaptureService
import com.xopmc.galaxybridge.service.AndroidCameraStartGateway
import com.xopmc.galaxybridge.service.CameraCaptureRequest
import com.xopmc.galaxybridge.service.CameraCaptureStatusBus
import com.xopmc.galaxybridge.service.CameraStartCoordinator
import com.xopmc.galaxybridge.service.EncodedCameraBus
import com.xopmc.galaxybridge.service.EncodedAudioBus
import com.xopmc.galaxybridge.service.EncodedVideoBus
import com.xopmc.galaxybridge.service.GalaxyAccessibilityService
import com.xopmc.galaxybridge.service.GalaxyNotificationListenerService
import com.xopmc.galaxybridge.service.NotificationEventBus
import com.xopmc.galaxybridge.service.NotificationEmission
import com.xopmc.galaxybridge.service.NotificationSnapshotBoundary
import com.xopmc.galaxybridge.protocol.v1.NotificationSnapshot
import com.xopmc.galaxybridge.service.CallEventBus
import com.xopmc.galaxybridge.service.TelephonyBridge
import com.xopmc.galaxybridge.setup.DistributionFeatures
import com.xopmc.galaxybridge.storage.EncryptedContentCache
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.BufferedOutputStream
import java.net.Socket
import java.net.BindException
import java.net.SocketTimeoutException
import java.net.URI
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.UUID
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedKeyManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.onSubscription
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import androidx.core.content.FileProvider
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

internal class CompanionAuthenticatedChannelRole {
    var kind: ChannelKind = ChannelKind.CHANNEL_KIND_UNSPECIFIED
        private set
    val ownsControlRetirement: Boolean get() = kind == ChannelKind.CHANNEL_KIND_CONTROL
    fun admit(incoming: Envelope): Boolean {
        val payload = CompanionControlPayloadPolicy.classify(incoming)
        if (payload == CompanionControlPayloadKind.OPEN_CHANNEL) {
            val selected = incoming.openChannel.kind
            if (selected == ChannelKind.CHANNEL_KIND_UNSPECIFIED || selected == ChannelKind.UNRECOGNIZED ||
                (kind != ChannelKind.CHANNEL_KIND_UNSPECIFIED && kind != selected)) return false
            kind = selected
            return true
        }
        // Preserve the protocol's safe unsupported-response path without
        // granting the sender authority over another connection's leases.
        if (payload == CompanionControlPayloadKind.UNSUPPORTED || payload == CompanionControlPayloadKind.TRANSFER_ACK) return true
        // Protocol-v1 control clients do not send OpenChannel. Only a parsed,
        // supported ordinary request may claim their legacy control lifetime.
        // Authentication, Hello/capability replies, PONG and bare EOF never do.
        if (kind == ChannelKind.CHANNEL_KIND_UNSPECIFIED) kind = ChannelKind.CHANNEL_KIND_CONTROL
        if (!ownsControlRetirement) return false
        return true
    }
}

internal class CompanionReceiverStartup<T : Any>(
    factory: () -> T,
) {
    private val receiver = lazy(LazyThreadSafetyMode.SYNCHRONIZED, factory)

    suspend fun initializeOnIo(): T = withContext(Dispatchers.IO) {
        receiver.value
    }
}

class CompanionLanServer(private val context: Context) {
    val listeningPort: Int get() = serverSocket?.localPort?.takeIf { it > 0 } ?: 0
    private val identity = DeviceIdentityStore()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val running = AtomicBoolean(false)
    private var serverSocket: SSLServerSocket? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var acceptJob: Job? = null
    private val activeSessions = CompanionSessionRegistry()
    private val controlWriters = java.util.concurrent.ConcurrentHashMap<DataOutputStream, CompanionControlIntake>()
    private val featurePreferences = com.xopmc.galaxybridge.setup.DeviceFeaturePreferences(context)
    private val featureChannels = java.util.concurrent.ConcurrentHashMap<Socket, Set<String>>()
    private val featureControlSessions = java.util.concurrent.ConcurrentHashMap<String, Pair<String, Socket>>()
    private data class FeatureShellLease(val hostID: String, val sessionID: String, val leaseID: String,
        val bootGeneration: String, val features: Set<String>, val streamIDs: Set<String>) {
        fun confirmsStopped(peer: String, session: String, result: com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult?): Boolean =
            hostID == peer && sessionID == session && result != null && result.available && result.errorCode.isEmpty() &&
                leaseID.isNotEmpty() && bootGeneration.isNotEmpty() && result.leaseId == leaseID &&
                result.bootGeneration == bootGeneration && result.state == "stopped" && result.streamIdsCount == 0
    }
    private val featureShellLeases = java.util.concurrent.ConcurrentHashMap<String, FeatureShellLease>()
    private val transferReceiverStartup = CompanionReceiverStartup {
        SafTransferReceiver(context).also { it.cleanup() }
    }
    private val pointerGestures = CompanionPointerGestureAccumulator()

    fun start() {
        if (!running.compareAndSet(false, true)) return
        acceptJob = scope.launch {
            try {
                val transferReceiver = transferReceiverStartup.initializeOnIo()
                val socket = createServerSocket()
                serverSocket = socket
                advertise(socket.localPort)
                while (isActive && running.get()) {
                    val client = socket.accept() as SSLSocket
                    launch {
                        AcceptedClientLifecycle.run(
                            closeTransport = client::close,
                            reportFailure = { type -> Log.w(TAG, "LAN client closed: $type") },
                        ) {
                            handleClient(client, transferReceiver)
                        }
                    }
                }
            } catch (error: Exception) {
                if (running.get()) Log.e(TAG, "LAN server stopped", error)
            }
        }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        registrationListener?.let {
            runCatching { context.getSystemService(NsdManager::class.java).unregisterService(it) }
        }
        registrationListener = null
        runCatching { serverSocket?.close() }
        activeSessions.closeAll()
        acceptJob?.cancel()
        scope.cancel()
    }

    private fun createServerSocket(): SSLServerSocket {
        val entry = identity.privateKeyEntry()
        val context = SSLContext.getInstance("TLSv1.3")
        context.init(arrayOf<KeyManager>(IdentityKeyManager(entry.privateKey, entry.certificateChain.map { it as X509Certificate }.toTypedArray())), null, SecureRandom())
        val socket = try {
            context.serverSocketFactory.createServerSocket(CompanionRoutedFallback.PORT)
        } catch (_: BindException) {
            // Bonjour still advertises the actual ephemeral port when another
            // local service owns the stable routed-subnet fallback port.
            context.serverSocketFactory.createServerSocket(0)
        }
        return (socket as SSLServerSocket).apply {
            enabledProtocols = arrayOf("TLSv1.3")
            needClientAuth = false
            reuseAddress = true
        }
    }

    private fun advertise(port: Int) {
        val manager = context.getSystemService(NsdManager::class.java)
        val attributes = BonjourAdvertisement.attributes(
            deviceId = deviceId(),
            publicKeyFingerprint = identity.fingerprint(),
            displayName = Build.MODEL,
            protocolMajor = 1,
        )
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "Bonjour registration failed: $errorCode")
            }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Bonjour unregistration failed: $errorCode")
            }
        }
        registrationListener = listener
        manager.registerService(
            NsdServiceInfo().apply {
                serviceName = BonjourAdvertisement.serviceName(Build.MODEL)
                serviceType = SERVICE_TYPE
                setPort(port)
                attributes.forEach(::setAttribute)
            },
            NsdManager.PROTOCOL_DNS_SD,
            listener,
        )
    }

    private suspend fun handleClient(socket: SSLSocket, transferReceiver: SafTransferReceiver) {
        socket.enabledProtocols = arrayOf("TLSv1.3")
        socket.tcpNoDelay = true
        socket.keepAlive = true
        socket.soTimeout = SOCKET_TIMEOUT_MS
        socket.startHandshake()
        val input = DataInputStream(socket.inputStream)
        // Coalesce each framed message before TLS; never emit its 17-byte
        // media header as several tiny records subject to delayed ACKs.
        val output = DataOutputStream(BufferedOutputStream(socket.outputStream, 64 * 1024))
        val envelope = readEnvelope(input)
        if (envelope.hasPairingRequest()) {
            handlePairing(socket, input, output, envelope)
            return
        }
        val fileOwner = transferReceiver.authenticatedOwner(envelope.deviceId)
        val authenticatedKey = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(PAIRED_MAC_KEY, null)
        val authenticationFailure = authenticationFailure(envelope)
        if (authenticationFailure != null) {
            Log.w(TAG, "LAN authentication rejected: ${authenticationFailure.name.lowercase()}")
            writeEnvelope(
                output,
                SessionAuthenticationRejectionResponse.make(
                    request = envelope,
                    deviceId = deviceId(),
                    failure = authenticationFailure,
                ),
            )
            return
        }
        if (context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(PAIRED_MAC_KEY, null) != authenticatedKey) return
        activeSessions.register(envelope.deviceId, envelope.sessionId, socket)
        val channelRole = CompanionAuthenticatedChannelRole()
        var controlIntake: CompanionControlIntake? = null
        var controlPermit: CompanionControlAdmission.Permit? = null
        try {
            // Healthy control peers heartbeat every two seconds. A lost control path
            // cannot leave its internet lease alive behind an indefinitely blocked read.
            socket.soTimeout = SOCKET_TIMEOUT_MS
            writeEnvelope(output, hello(envelope))
            writeEnvelope(output, capabilities(envelope))
            val notificationActionLedger = NotificationActionLedger()
            fun handleControlRequest(incoming: Envelope) {
                val payloadKind = CompanionControlPayloadPolicy.classify(incoming)
                when (payloadKind) {
                    CompanionControlPayloadKind.FEATURE_CONFIGURATION -> {
                        check(featureControlSessions[envelope.deviceId] == (envelope.sessionId to socket)) { "control_session_replaced" }
                        val request = incoming.featureConfigurationRequest
                        val enabled = request.enabledFeatureIdsList.toSet()
                        val requestPolicy = com.xopmc.galaxybridge.setup.DeviceFeatureRequest(envelope.deviceId, envelope.sessionId,
                            request.targetDeviceId, request.requestId, request.revision, enabled)
                        val previous = featurePreferences.enabledIDs()
                        val error = if (request.enabledFeatureIdsCount != enabled.size || request.enabledFeatureIdsCount > 10)
                            "invalid_feature_request" else featurePreferences.applyAuthenticated(requestPolicy, envelope.deviceId, envelope.sessionId, deviceId())
                        if (error == null) {
                            val disabled = previous - enabled
                            featureChannels.entries.filter { (_, required) -> required.any { it in disabled } }
                                .forEach { (channel, _) -> runCatching { channel.close() } }
                            if ("camera" in disabled) context.stopService(Intent(context, CameraCaptureService::class.java))
                            if ("screen" in disabled) context.stopService(Intent(context, com.xopmc.galaxybridge.service.MediaProjectionCaptureService::class.java))
                            val shell = com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current?.shell
                            featureShellLeases.values.filter { it.hostID == envelope.deviceId && it.sessionID == envelope.sessionId && it.features.any { feature -> feature in disabled } }
                                .forEach { lease ->
                                    val stopped = shell?.executeAuthenticated(lease.hostID, lease.sessionID, com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.newBuilder()
                                        .setRequestId(UUID.randomUUID().toString()).setLeaseId(lease.leaseID).setBootGeneration(lease.bootGeneration)
                                        .setOperation(com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.STOP).build())
                                    if (lease.confirmsStopped(lease.hostID, lease.sessionID, stopped)) {
                                        featureShellLeases.remove(lease.leaseID, lease)
                                    }
                                }
                            if ("internet" in disabled) com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current?.internet?.revokeAuthenticated(envelope.deviceId, envelope.sessionId)
                            if ("notifications" in disabled) NotificationEventBus.discardAll()
                            GalaxyNotificationListenerService.refreshFeaturePolicy()
                        }
                        val result = com.xopmc.galaxybridge.protocol.v1.FeatureConfigurationResult.newBuilder()
                            .setRequestId(request.requestId.take(36)).setTargetDeviceId(deviceId()).setRevision(request.revision)
                            .setAccepted(error == null).addAllEnabledFeatureIds(featurePreferences.enabledIDs().sorted()).setErrorCode(error.orEmpty())
                        writeEnvelope(output, eventEnvelope(envelope.sessionId, incoming.messageId + 1).setFeatureConfigurationResult(result).build())
                        writeEnvelope(output, capabilities(incoming))
                    }
                    CompanionControlPayloadKind.SHELL_BRIDGE -> {
                        val bridge = com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current?.shell
                        val shellRequest = if (!featurePreferences.isEnabled("audio") && incoming.shellBridgeRequest.hasOptions())
                            incoming.shellBridgeRequest.toBuilder().setOptions(incoming.shellBridgeRequest.options.toBuilder().setAudio(false)).build()
                            else incoming.shellBridgeRequest
                        val result = if (incoming.shellBridgeRequest.operation == com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.LIST_APPLICATIONS && BuildConfig.DISTRIBUTION != "play") {
                            runCatching {
                                require(com.xopmc.galaxybridge.transport.shell.ShellBridgePolicy.uuid(incoming.shellBridgeRequest.requestId))
                                com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult.newBuilder()
                                    .setRequestId(incoming.shellBridgeRequest.requestId).setBootGeneration(bridge?.status()?.bootGeneration.orEmpty())
                                    .setAvailable(true).setState("catalog")
                                    .setApplicationCatalogJson(ByteString.copyFrom(com.xopmc.galaxybridge.catalog.ApplicationCatalogExporter.inlineJSON(context))).build()
                            }.getOrElse {
                                com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult.newBuilder().setRequestId(incoming.shellBridgeRequest.requestId)
                                    .setAvailable(false).setState("failed").setErrorCode("application_catalog_unavailable").build()
                            }
                        } else if (bridge == null || BuildConfig.DISTRIBUTION == "play") {
                            com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult.newBuilder()
                                .setRequestId(incoming.shellBridgeRequest.requestId).setAvailable(false).setState("failed")
                                .setErrorCode("shell_bridge_not_activated").build()
                        } else bridge.executeAuthenticated(envelope.deviceId, envelope.sessionId, shellRequest)
                        if (shellRequest.operation == com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.STOP) {
                            featureShellLeases[shellRequest.leaseId]?.let { lease ->
                                if (lease.confirmsStopped(envelope.deviceId, envelope.sessionId, result)) {
                                    featureShellLeases.remove(shellRequest.leaseId, lease)
                                }
                            }
                        }
                        else if (result.available && result.errorCode.isEmpty() && result.streamIdsCount > 0) {
                            val required = when (shellRequest.operation) {
                                com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.START_CLIPBOARD -> setOf("clipboard")
                                com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.START_PANEL -> emptySet()
                                else -> setOf(if (shellRequest.options.packageName.isBlank()) "screen" else "applications") +
                                    (if (shellRequest.options.audio) setOf("audio") else emptySet())
                            }
                            val lease = FeatureShellLease(envelope.deviceId, envelope.sessionId, result.leaseId, result.bootGeneration, required, result.streamIdsList.toSet())
                            featureShellLeases[result.leaseId] = lease
                            // A different CONTROL operation may have disabled this feature while the shell was starting.
                            if (required.any { !featurePreferences.isEnabled(it) }) {
                                val stopped = bridge?.executeAuthenticated(envelope.deviceId, envelope.sessionId, com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.newBuilder()
                                    .setRequestId(UUID.randomUUID().toString()).setLeaseId(result.leaseId).setBootGeneration(result.bootGeneration)
                                    .setOperation(com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.STOP).build())
                                if (lease.confirmsStopped(envelope.deviceId, envelope.sessionId, stopped)) {
                                    featureShellLeases.remove(result.leaseId, lease)
                                }
                                writeEnvelope(output, featureDisabled(incoming)); return
                            }
                        }
                        writeEnvelope(output, Envelope.newBuilder().setProtocolMajor(1).setDeviceId(deviceId())
                            .setSessionId(envelope.sessionId).setMessageId(incoming.messageId + 1).setShellBridgeResult(result).build())
                    }
                    CompanionControlPayloadKind.DIRECT_LINK -> {
                        val response = runCatching {
                            requireNotNull(com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current)
                                .coordinator.handleAuthenticated(envelope.deviceId, incoming.directLinkRequest)
                        }.getOrElse {
                            Envelope.newBuilder().setProtocolMajor(1).setDeviceId(deviceId()).setDirectLinkStatus(
                                com.xopmc.galaxybridge.protocol.v1.DirectLinkStatus.newBuilder()
                                    .setRequestId(incoming.directLinkRequest.requestId).setState("failed")
                                    .setErrorCode("direct_link_unavailable")).build()
                        }
                        writeEnvelope(output, response.toBuilder().setSessionId(envelope.sessionId).setMessageId(incoming.messageId + 1).build())
                    }
                    CompanionControlPayloadKind.INTERNET_SHARING -> {
                        writeEnvelope(output, internetSharing(incoming, envelope.deviceId, envelope.sessionId))
                    }
                    CompanionControlPayloadKind.INPUT -> handleInput(incoming)
                    CompanionControlPayloadKind.CLIPBOARD -> handleClipboard(incoming.clipboardUpdate)
                    CompanionControlPayloadKind.NOTIFICATION_ACTION -> handleNotificationAction(incoming, output, notificationActionLedger)
                    CompanionControlPayloadKind.CAMERA_CONFIGURATION -> handleCameraConfiguration(incoming)
                    CompanionControlPayloadKind.CALL -> TelephonyBridge.handleCall(context, incoming.callEvent)
                    CompanionControlPayloadKind.TRANSFER_MANIFEST -> writeTransferAck(
                        output,
                        incoming,
                        transferReceiver.accept(fileOwner, incoming.transferManifest),
                    )
                    CompanionControlPayloadKind.TRANSFER_CHUNK -> writeTransferAck(
                        output,
                        incoming,
                        transferReceiver.append(fileOwner, incoming.transferChunk),
                    )
                    CompanionControlPayloadKind.TRANSFER_CANCEL -> writeTransferAck(
                        output, incoming, transferReceiver.cancel(fileOwner, incoming.transferCancel.transferId),
                    )
                    CompanionControlPayloadKind.TRANSFER_ACK, CompanionControlPayloadKind.UNSUPPORTED -> writeEnvelope(
                        output,
                        CompanionControlPayloadPolicy.unsupportedResponse(incoming, deviceId()),
                    )
                    CompanionControlPayloadKind.OPEN_CHANNEL, CompanionControlPayloadKind.PING ->
                        error("invalid_control_dispatch")
                }
            }
            fun installControlIntake(): Boolean {
                if (controlIntake != null) return true
                controlPermit = controlAdmission.acquire(envelope.deviceId) ?: return false
                val intake = CompanionControlIntake(deviceId(), authorized = {
                    val current = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                    !socket.isClosed && current.getString(PAIRED_HOST_ID, null) == envelope.deviceId &&
                        current.getString(PAIRED_MAC_KEY, null) == authenticatedKey &&
                        activeSessions.contains(envelope.deviceId, envelope.sessionId, socket) &&
                        featureControlSessions[envelope.deviceId] == (envelope.sessionId to socket)
                }, featureAllowed = { featurePayloadAllowed(it, CompanionControlPayloadPolicy.classify(it)) },
                featureRejected = { writeEnvelope(output, featureDisabled(it)) }, dispatch = ::handleControlRequest, renew = {
                    com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current?.internet
                        ?.renewAuthenticated(envelope.deviceId, envelope.sessionId)
                }, writeFrame = { encoded -> writeEncodedEnvelope(output, encoded) }, failed = { error ->
                    Log.w(TAG, "Control worker closed: ${error.javaClass.simpleName}")
                    runCatching { socket.close() }
                })
                controlIntake = intake
                controlWriters[output] = intake
                return true
            }
            while (!socket.isClosed) {
                val incoming = runCatching { readEnvelope(input) }.getOrNull() ?: return
                val currentTrust = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                if (currentTrust.getString(PAIRED_HOST_ID, null) != envelope.deviceId ||
                    currentTrust.getString(PAIRED_MAC_KEY, null) != authenticatedKey ||
                    incoming.deviceId != envelope.deviceId || incoming.sessionId != envelope.sessionId) return
                val previousChannelKind = channelRole.kind
                if (!channelRole.admit(incoming)) return
                if (previousChannelKind == ChannelKind.CHANNEL_KIND_UNSPECIFIED && channelRole.ownsControlRetirement) {
                    if (!installControlIntake()) return
                    featureControlSessions[envelope.deviceId] = envelope.sessionId to socket
                }
                val payloadKind = CompanionControlPayloadPolicy.classify(incoming)
                when (payloadKind) {
                    CompanionControlPayloadKind.OPEN_CHANNEL -> {
                      socket.soTimeout = if (channelRole.ownsControlRetirement) SOCKET_TIMEOUT_MS else 0
                      val required = when (channelRole.kind) {
                          ChannelKind.CHANNEL_KIND_VIDEO -> setOf("screen")
                          ChannelKind.CHANNEL_KIND_AUDIO -> setOf("audio")
                          ChannelKind.CHANNEL_KIND_CAMERA -> setOf("camera")
                          ChannelKind.CHANNEL_KIND_FILES -> setOf("files")
                          ChannelKind.CHANNEL_KIND_INTERNET_PROXY -> setOf("internet")
                          ChannelKind.CHANNEL_KIND_ENHANCED_STREAM -> featureShellLeases.values.firstOrNull {
                              it.hostID == envelope.deviceId && it.sessionID == envelope.sessionId && incoming.openChannel.streamId in it.streamIDs
                          }?.features ?: emptySet()
                          else -> emptySet()
                      }
                      if (required.any { !featurePreferences.isEnabled(it) }) { writeEnvelope(output, featureDisabled(incoming)); return }
                      featureChannels[socket] = required
                      when (channelRole.kind) {
                        ChannelKind.CHANNEL_KIND_CONTROL -> Unit
                        ChannelKind.CHANNEL_KIND_VIDEO -> return streamVideo(socket, input, output)
                        ChannelKind.CHANNEL_KIND_AUDIO -> return streamAudio(socket, input, output)
                        ChannelKind.CHANNEL_KIND_CAMERA -> return streamCamera(socket, input, output)
                        ChannelKind.CHANNEL_KIND_EVENTS -> return streamEvents(socket, input, output, envelope.sessionId)
                        ChannelKind.CHANNEL_KIND_ENHANCED_STREAM -> {
                            val shell = com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current?.shell
                            if (shell == null || BuildConfig.DISTRIBUTION == "play") {
                                writeEnvelope(output, Envelope.newBuilder().setProtocolMajor(1).setDeviceId(deviceId()).setSessionId(envelope.sessionId)
                                    .setShellBridgeResult(com.xopmc.galaxybridge.protocol.v1.ShellBridgeResult.newBuilder()
                                        .setAvailable(false).setState("failed").setErrorCode("shell_bridge_not_activated")).build())
                                return
                            }
                            shell.bridgeAuthenticated(input, output, envelope.deviceId, envelope.sessionId, incoming.openChannel.streamId, socket::close)
                            return
                        }
                        ChannelKind.CHANNEL_KIND_INTERNET_PROXY -> {
                            val runtime = com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current
                            val leaseID = incoming.openChannel.streamId
                            val codec = incoming.openChannel.codec
                            val supportedCodec = codec in setOf("", "socks5", "dns-wire-v1")
                            val admitted = supportedCodec && runtime?.internet?.admits(envelope.deviceId, envelope.sessionId, leaseID) == true
                            val ready = com.xopmc.galaxybridge.protocol.v1.InternetSharingStatus.newBuilder()
                                .setRequestId(leaseID).setLeaseId(leaseID).setEnabled(admitted)
                                .setInternetValidated(false).setUpstream(runtime?.internet?.status()?.upstream ?: "unavailable")
                                .setErrorCode(if (admitted) "" else "gateway_lease_or_upstream_unavailable")
                            writeEnvelope(output, Envelope.newBuilder().setProtocolMajor(1).setDeviceId(deviceId())
                                .setSessionId(envelope.sessionId).setInternetSharingStatus(ready).build())
                            if (!admitted) return
                            if (codec == "dns-wire-v1") runtime!!.internet.handleDnsAuthenticated(input, output, envelope.deviceId, envelope.sessionId, leaseID, socket::close)
                            else runtime!!.internet.bridgeAuthenticated(input, output, envelope.deviceId, envelope.sessionId, leaseID, socket::close)
                            return
                        }
                        ChannelKind.CHANNEL_KIND_FILES -> {
                            if (fileOwner == null || fileOwner != transferReceiver.authenticatedOwner(envelope.deviceId)) return
                            return handleFiles(socket, input, output, envelope.sessionId, fileOwner, transferReceiver)
                        }
                        else -> writeEnvelope(
                            output,
                            CompanionControlPayloadPolicy.unsupportedResponse(incoming, deviceId()),
                        )
                    }
                    }
                    else -> {
                        if (channelRole.ownsControlRetirement) {
                            if (!requireNotNull(controlIntake).admit(incoming)) return
                        } else writeEnvelope(output, CompanionControlPayloadPolicy.unsupportedResponse(incoming, deviceId()))
                    }
                }
            }
        } finally {
            var cleanupInterrupted = Thread.interrupted()
            try {
                controlIntake?.let { intake ->
                    intake.closeAdmission()
                    // Unblock a stalled TLS writer, then settle a possible late START.
                    // Cancellation/EOF is not proof that a mutation never happened.
                    runCatching { socket.close() }
                    intake.awaitSettled()
                    cleanupInterrupted = Thread.interrupted() || cleanupInterrupted
                }
                if (controlPermit != null) {
                    com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current?.internet
                        ?.revokeAuthenticated(envelope.deviceId, envelope.sessionId)
                    com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current?.shell
                        ?.retireAuthenticated(envelope.deviceId, envelope.sessionId)
                }
                if (controlPermit != null) featureShellLeases.entries.removeIf { it.value.hostID == envelope.deviceId && it.value.sessionID == envelope.sessionId }
            } finally {
                controlWriters.remove(output)
                featureControlSessions.remove(envelope.deviceId, envelope.sessionId to socket)
                featureChannels.remove(socket)
                activeSessions.unregister(envelope.deviceId, envelope.sessionId, socket)
                controlPermit?.close()
                if (cleanupInterrupted) Thread.currentThread().interrupt()
            }
        }
    }

    private fun featurePayloadAllowed(envelope: Envelope, kind: CompanionControlPayloadKind): Boolean {
        val feature = when (kind) {
            CompanionControlPayloadKind.CLIPBOARD -> "clipboard"
            CompanionControlPayloadKind.CALL -> "calls"
            CompanionControlPayloadKind.NOTIFICATION_ACTION -> "notifications"
            CompanionControlPayloadKind.INPUT -> if (!featurePreferences.isEnabled("screen") && !featurePreferences.isEnabled("applications")) "screen" else null
            CompanionControlPayloadKind.CAMERA_CONFIGURATION -> if (envelope.cameraConfiguration.enabled) "camera" else null
            CompanionControlPayloadKind.INTERNET_SHARING -> if (envelope.internetSharingRequest.enabled) "internet" else null
            CompanionControlPayloadKind.TRANSFER_MANIFEST, CompanionControlPayloadKind.TRANSFER_CHUNK -> "files"
            CompanionControlPayloadKind.SHELL_BRIDGE -> when (envelope.shellBridgeRequest.operation) {
                com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.START_CLIPBOARD -> "clipboard"
                com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.START_PANEL ->
                    if (com.xopmc.galaxybridge.setup.DeviceFeaturePolicy.canUsePanel(featurePreferences.enabledIDs())) null else "screen"
                com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.LIST_APPLICATIONS -> "applications"
                com.xopmc.galaxybridge.protocol.v1.ShellBridgeRequest.Operation.START_SCRCPY ->
                    if (envelope.shellBridgeRequest.options.packageName.isNotBlank()) "applications" else "screen"
                else -> null
            }
            else -> null
        }
        return feature == null || featurePreferences.isEnabled(feature)
    }

    private fun featureDisabled(request: Envelope): Envelope = eventEnvelope(request.sessionId, request.messageId + 1)
        .setError(com.xopmc.galaxybridge.protocol.v1.ErrorEvent.newBuilder().setCode("feature_disabled")
            .setSafeMessage("This feature is turned off for this phone.").setRetryable(false)).build()

    private fun internetSharing(request: Envelope, peerID: String, sessionID: String): Envelope {
        val sharing = request.internetSharingRequest
        val phoneAllowed = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getBoolean("internet_sharing_allowed", false)
        val runtime = com.xopmc.galaxybridge.nearby.ForegroundConnectivityRuntime.current
        var leaseID = sharing.leaseId
        val error = runCatching {
            val gateway = requireNotNull(runtime).internet
            if (sharing.enabled) {
                check(phoneAllowed)
                // A repeated enabled request with the same lease is status+renew, including
                // temporary validation loss. It must not rotate credentials or close flows.
                leaseID = gateway.enableAuthenticated(peerID, sessionID, leaseID.takeIf { it.isNotEmpty() }).id
            } else gateway.revokeAuthenticated(peerID, sessionID)
        }.exceptionOrNull()
        val state = runtime?.internet?.status()
        return Envelope.newBuilder().setProtocolMajor(1).setDeviceId(deviceId()).setSessionId(sessionID)
            .setMessageId(request.messageId + 1).setInternetSharingStatus(
                com.xopmc.galaxybridge.protocol.v1.InternetSharingStatus.newBuilder().setRequestId(sharing.requestId)
                    .setLeaseId(leaseID).setEnabled(error == null && sharing.enabled)
                    .setUpstream(state?.upstream ?: "unavailable").setInternetValidated(false)
                    .setErrorCode(InternetSharingRequestPolicy.errorCode(
                        sharing.enabled, phoneAllowed, error != null, state?.errorCode.orEmpty()))
                    .setBytesSent(state?.bytesSent ?: 0).setBytesReceived(state?.bytesReceived ?: 0)).build()
    }

    private fun authenticationFailure(envelope: Envelope): SessionAuthenticationFailure? {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val storedKey = preferences.getString(PAIRED_MAC_KEY, null)?.let {
            runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull()
        }
        return SessionAuthenticationValidator.failure(
            envelope = envelope,
            pairedHostId = preferences.getString(PAIRED_HOST_ID, null),
            storedPublicKey = storedKey,
            nowUnixSeconds = System.currentTimeMillis() / 1_000,
        )
    }

    private fun hello(request: Envelope): Envelope = Envelope.newBuilder()
        .setProtocolMajor(1)
        .setProtocolMinor(0)
        .setDeviceId(deviceId())
        .setSessionId(request.sessionId)
        .setMessageId(request.messageId + 1)
        .setHello(
            Hello.newBuilder()
                .setDisplayName("${Build.MANUFACTURER} ${Build.MODEL}")
                .setPublicKeyFingerprint(ByteString.copyFrom(identity.fingerprint()))
                .addTransports(TransportKind.TRANSPORT_KIND_COMPANION_LAN),
        )
        .build()

    private fun capabilities(request: Envelope): Envelope = Envelope.newBuilder()
        .setProtocolMajor(1)
        .setProtocolMinor(0)
        .setDeviceId(deviceId())
        .setSessionId(request.sessionId)
        .setMessageId(request.messageId + 2)
        .setCapabilityUpdate(CompanionCapabilityResolver.resolve(context))
        .build()

    private suspend fun streamVideo(
        socket: SSLSocket,
        input: DataInputStream,
        output: DataOutputStream,
    ) {
        // Bound bytes already committed to TCP as well as the four-frame
        // producer queue; megabytes here can hide seconds of stale video.
        socket.sendBufferSize = 64 * 1024
        val configurationGate = MediaStreamConfigurationGate<com.xopmc.galaxybridge.service.EncodedVideoFrame>(
            epoch = { it.epoch },
            isConfiguration = { it.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 },
            isKeyFrame = { it.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0 },
            sequence = { it.sequence },
            requestKeyFrame = EncodedVideoBus::requestKeyFrame,
        )
        fun write(frame: com.xopmc.galaxybridge.service.EncodedVideoFrame) {
            if (!featurePreferences.isEnabled("screen")) return
            val flags = (if (frame.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) MEDIA_FLAG_CONFIGURATION else 0) or
                (if (frame.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) MEDIA_FLAG_KEY_FRAME else 0)
            synchronized(output) {
                output.writeByte(flags)
                output.writeInt(frame.epoch)
                output.writeLong(frame.presentationTimeUs)
                output.writeInt(frame.payload.size)
                output.write(frame.payload)
                output.flush()
            }
        }
        OutboundChannelLifecycle.run(input, socket::close) {
            EncodedVideoBus.frames.onSubscription {
                val snapshot = EncodedVideoBus.bootstrapFrames()
                snapshot.forEach { frame ->
                    configurationGate.framesToWrite(frame, snapshot.firstOrNull()).forEach(::write)
                }
                EncodedVideoBus.requestKeyFrame()
            }.collect { frame ->
                configurationGate.framesToWrite(frame, EncodedVideoBus.latestConfiguration).forEach(::write)
            }
        }
    }

    private suspend fun streamAudio(
        socket: SSLSocket,
        input: DataInputStream,
        output: DataOutputStream,
    ) {
        val configurationGate = MediaStreamConfigurationGate<com.xopmc.galaxybridge.service.EncodedAudioFrame>(
            epoch = { it.epoch },
            isConfiguration = { it.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0 },
        )
        fun write(frame: com.xopmc.galaxybridge.service.EncodedAudioFrame) {
            if (!featurePreferences.isEnabled("audio")) return
            val flags = if (frame.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) MEDIA_FLAG_CONFIGURATION else 0
            synchronized(output) {
                output.writeByte(flags)
                output.writeInt(frame.epoch)
                output.writeLong(frame.presentationTimeUs)
                output.writeInt(frame.payload.size)
                output.write(frame.payload)
                output.flush()
            }
        }
        OutboundChannelLifecycle.run(input, socket::close) {
            EncodedAudioBus.latestConfiguration?.let { configuration ->
                configurationGate.framesToWrite(configuration, configuration).forEach(::write)
            }
            EncodedAudioBus.frames.collect { frame ->
                configurationGate.framesToWrite(frame, EncodedAudioBus.latestConfiguration).forEach(::write)
            }
        }
    }

    private suspend fun streamCamera(
        socket: SSLSocket,
        input: DataInputStream,
        output: DataOutputStream,
    ) {
        val configurationGate = CameraStreamConfigurationGate()
        fun write(frame: com.xopmc.galaxybridge.service.EncodedCameraFrame) {
            if (!featurePreferences.isEnabled("camera")) return
            val flags = (if (frame.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) MEDIA_FLAG_CONFIGURATION else 0) or
                (if (frame.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) MEDIA_FLAG_KEY_FRAME else 0)
            synchronized(output) {
                output.writeByte(flags)
                output.writeInt(frame.epoch)
                output.writeLong(frame.presentationTimeUs)
                output.writeInt(frame.payload.size)
                output.write(frame.payload)
                output.flush()
            }
        }
        OutboundChannelLifecycle.run(input, socket::close) {
            EncodedCameraBus.latestConfiguration?.let { configuration ->
                configurationGate.framesToWrite(configuration, configuration).forEach(::write)
            }
            EncodedCameraBus.frames.collect { frame ->
                configurationGate.framesToWrite(frame, EncodedCameraBus.latestConfiguration).forEach(::write)
            }
        }
    }

    private suspend fun streamEvents(
        socket: SSLSocket,
        input: DataInputStream,
        output: DataOutputStream,
        sessionId: String,
    ) {
        val nextMessageId = AtomicLong(100)
        ClipboardBridge.outboundHub.subscribe().use { clipboardSubscription ->
            OutboundChannelLifecycle.run(input, socket::close) {
            val telephonyEnabled = DistributionFeatures.telephonyEnabled(BuildConfig.DISTRIBUTION)
            if (telephonyEnabled && featurePreferences.isEnabled("calls")) {
                TelephonyBridge.recentCalls(context).forEach { call ->
                    writeEnvelope(
                        output,
                        eventEnvelope(sessionId, nextMessageId.getAndIncrement()).setCallEvent(call).build(),
                    )
                }
            }
            val callEvents = if (telephonyEnabled) {
                CallEventBus.events.map { call ->
                    eventEnvelope(sessionId, nextMessageId.getAndIncrement()).setCallEvent(call).build()
                }
            } else {
                emptyFlow()
            }
            merge(
                NotificationEventBus.deliveries(onOverflow = { runCatching { socket.close() } }).map { delivery ->
                    val envelope = eventEnvelope(sessionId, nextMessageId.getAndIncrement())
                    when (delivery) {
                        is NotificationEmission -> envelope.setNotificationEvent(
                            NotificationEventMapper.toProtocol(
                                delivery.notification,
                                isInitialSnapshot = delivery.isInitialSnapshot,
                            ),
                        )
                        is NotificationSnapshotBoundary -> envelope.setNotificationSnapshot(
                            NotificationSnapshot.newBuilder().setComplete(delivery.complete),
                        )
                    }
                    envelope.build()
                },
                clipboardSubscription.events.map { clipboard ->
                    Envelope.newBuilder()
                        .setProtocolMajor(1)
                        .setProtocolMinor(0)
                        .setDeviceId(deviceId())
                        .setSessionId(sessionId)
                        .setMessageId(nextMessageId.getAndIncrement())
                        .setClipboardUpdate(
                            ClipboardUpdate.newBuilder()
                                .setChangeId(clipboard.changeId)
                                .setKind(clipboard.kind)
                                .setContent(ByteString.copyFrom(clipboard.content))
                                .setSensitive(false),
                        )
                        .build()
                },
                callEvents,
                flow {
                    var previous = CompanionCapabilityResolver.resolve(context)
                    emit(
                        eventEnvelope(sessionId, nextMessageId.getAndIncrement())
                            .setCapabilityUpdate(previous)
                            .build(),
                    )
                    while (true) {
                        delay(2_000)
                        val current = CompanionCapabilityResolver.resolve(context)
                        if (current != previous) {
                            previous = current
                            emit(
                                eventEnvelope(sessionId, nextMessageId.getAndIncrement())
                                    .setCapabilityUpdate(current)
                                    .build(),
                            )
                        }
                    }
                },
                AdbBindingResponseBus.responses.map { response ->
                    eventEnvelope(sessionId, nextMessageId.getAndIncrement())
                        .setAdbBindingResponse(
                            AdbBindingResponse.newBuilder()
                                .setAdbSerial(response.adbSerial)
                                .setNonce(ByteString.copyFrom(response.nonce))
                                .setIdentityPublicKey(ByteString.copyFrom(response.identityPublicKey))
                                .setSignature(ByteString.copyFrom(response.signature)),
                        )
                        .build()
                },
                CameraCaptureStatusBus.statuses.map { status ->
                    eventEnvelope(sessionId, nextMessageId.getAndIncrement())
                        .setCameraStatus(CameraStatusMapper.toProtocol(status))
                        .build()
                },
            ).collect { event ->
                val feature = when {
                    event.hasNotificationEvent() || event.hasNotificationSnapshot() -> "notifications"
                    event.hasClipboardUpdate() -> "clipboard"
                    event.hasCallEvent() -> "calls"
                    else -> null
                }
                if (feature == null) writeEnvelope(output, event)
                else featurePreferences.withEnabled(feature) { writeEnvelope(output, event) }
            }
            }
        }
    }

    private fun eventEnvelope(sessionId: String, messageId: Long): Envelope.Builder =
        Envelope.newBuilder()
            .setProtocolMajor(1)
            .setProtocolMinor(0)
            .setDeviceId(deviceId())
            .setSessionId(sessionId)
            .setMessageId(messageId)

    private fun handleFiles(
        socket: SSLSocket,
        input: DataInputStream,
        output: DataOutputStream,
        sessionId: String,
        fileOwner: String,
        transferReceiver: SafTransferReceiver,
    ) {
        val outgoing = if (AndroidOutgoingFiles.enabled) AndroidOutgoingFiles.get(context).attach(
            fileOwner, sessionId, deviceId(), { writeEnvelope(output, it) }, socket::close,
        ) else null
        try {
        while (true) {
            val incoming = runCatching { readEnvelope(input) }.getOrNull() ?: return
            if (incoming.sessionId != sessionId || incoming.deviceId != context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(PAIRED_HOST_ID, null)) return
            if (!featurePreferences.isEnabled("files")) return
            when (CompanionControlPayloadPolicy.classify(incoming)) {
                CompanionControlPayloadKind.TRANSFER_ACK -> outgoing?.acknowledge(incoming.transferAck)
                CompanionControlPayloadKind.TRANSFER_MANIFEST -> writeTransferAck(
                    output,
                    incoming,
                    transferReceiver.accept(fileOwner, incoming.transferManifest),
                )
                CompanionControlPayloadKind.TRANSFER_CHUNK -> writeTransferAck(
                    output,
                    incoming,
                    transferReceiver.append(fileOwner, incoming.transferChunk),
                )
                CompanionControlPayloadKind.TRANSFER_CANCEL -> writeTransferAck(
                    output, incoming, transferReceiver.cancel(fileOwner, incoming.transferCancel.transferId),
                )
                CompanionControlPayloadKind.PING -> writeEnvelope(
                    output,
                    Envelope.newBuilder()
                        .setProtocolMajor(1)
                        .setProtocolMinor(0)
                        .setDeviceId(deviceId())
                        .setSessionId(sessionId)
                        .setMessageId(incoming.messageId + 1)
                        .setPong(Pong.newBuilder().setEchoedMonotonicTimeNs(incoming.ping.monotonicTimeNs))
                        .build(),
                )
                else -> writeEnvelope(
                    output,
                    CompanionControlPayloadPolicy.unsupportedResponse(incoming, deviceId()),
                )
            }
        }
        } finally { outgoing?.detach() }
    }

    private fun handleInput(envelope: Envelope) {
        val input = envelope.inputEvent
        val epoch = EncodedVideoBus.latestConfiguration?.epoch ?: 0
        if (input.displayEpoch != 0 && epoch != 0 && input.displayEpoch != epoch) return
        val point = input.normalizedX.toDouble() to input.normalizedY.toDouble()
        when (input.action) {
            InputAction.INPUT_ACTION_DOWN -> pointerGestures.down(input.pointerId, point.first, point.second)
            InputAction.INPUT_ACTION_MOVE -> pointerGestures.move(input.pointerId, point.first, point.second)
            InputAction.INPUT_ACTION_UP -> GalaxyAccessibilityService.submit(
                pointerGestures.up(input.pointerId, point.first, point.second, input.displayEpoch),
            )
            InputAction.INPUT_ACTION_CANCEL -> pointerGestures.cancel(input.pointerId)
            InputAction.INPUT_ACTION_SCROLL -> GalaxyAccessibilityService.submit(
                AndroidInputCommand.Scroll(
                    point.first,
                    point.second,
                    input.scrollX.toDouble(),
                    input.scrollY.toDouble(),
                    input.displayEpoch,
                ),
            )
            InputAction.INPUT_ACTION_TEXT -> GalaxyAccessibilityService.submit(
                AndroidInputCommand.Text(input.text.take(MAX_TEXT_LENGTH), input.displayEpoch),
            )
            InputAction.INPUT_ACTION_KEY -> GalaxyAccessibilityService.submit(
                AndroidInputCommand.Key(input.androidKeycode, input.modifiers, input.displayEpoch),
            )
            else -> Unit
        }
    }

    private fun handleClipboard(update: ClipboardUpdate) {
        if (update.sensitive || update.content.size() > MAX_CLIPBOARD_BYTES) return
        val content = update.content.toByteArray()
        val clip = when (update.kind) {
            ClipboardKind.CLIPBOARD_KIND_TEXT -> {
                if (content.size > ClipboardPayloadPolicy.MAX_TEXT_BYTES) return
                ClipData.newPlainText("GalaxyBridge", decodeUtf8(content) ?: return)
            }
            ClipboardKind.CLIPBOARD_KIND_URL -> {
                if (content.size > ClipboardPayloadPolicy.MAX_TEXT_BYTES) return
                val text = decodeUtf8(content) ?: return
                val uri = runCatching { URI(text.trim()) }.getOrNull() ?: return
                if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.rawAuthority.isNullOrBlank()) return
                ClipData.newPlainText("URL", text)
            }
            ClipboardKind.CLIPBOARD_KIND_PNG -> imageClip(content) ?: return
            else -> return
        }
        ClipboardBridge.echoSuppressor.markInbound(update.kind, content)
        if (update.changeId.isNotEmpty() && update.changeId.toByteArray(Charsets.UTF_8).size <= 256) {
            val normalizedKind = if (update.kind == ClipboardKind.CLIPBOARD_KIND_PNG) update.kind
                else ClipboardKind.CLIPBOARD_KIND_TEXT
            clip.description.extras = android.os.PersistableBundle().apply {
                putString("com.xopmc.galaxybridge.clipboard.origin", update.changeId)
                putString("com.xopmc.galaxybridge.clipboard.origin_digest",
                    com.xopmc.galaxybridge.service.ClipboardFingerprint.digest(normalizedKind, content))
            }
        }
        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
        val id = update.changeId.ifBlank { UUID.randomUUID().toString() }
        runCatching {
            EncryptedContentCache(context).use { cache ->
                cache.put(deviceId(), EncryptedContentCache.NAMESPACE_CLIPBOARD, id, content)
            }
        }
    }

    private fun imageClip(content: ByteArray): ClipData? = runCatching {
        require(ClipboardImageCodec.isSafePng(content))
        val directory = File(context.cacheDir, "clipboard").apply { mkdirs() }
        val file = File(directory, "galaxybridge-${UUID.randomUUID()}.png")
        file.outputStream().use { it.write(content) }
        directory.listFiles()?.filter { candidate ->
            candidate != file && System.currentTimeMillis() - candidate.lastModified() > CLIPBOARD_IMAGE_TTL_MS
        }?.forEach(File::delete)
        val uri: Uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file,
        )
        ClipData.newUri(context.contentResolver, "GalaxyBridge image", uri)
    }.getOrNull()

    private fun decodeUtf8(content: ByteArray): String? = runCatching {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(content))
            .toString()
    }.getOrNull()?.takeIf { it.isNotEmpty() }

    private fun handleNotificationAction(envelope: Envelope, output: DataOutputStream, ledger: NotificationActionLedger) {
        val action = envelope.notificationAction
        fun execute() = GalaxyNotificationListenerService.performActiveResult(
            action.notificationId, action.actionId, action.replyText.takeIf { it.isNotEmpty() }, action.dismiss,
        )
        // Legacy callers receive no unsolicited result frame.
        if (action.requestId.isEmpty()) { execute(); return }
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(action.toByteArray())
            .joinToString("") { "%02x".format(it) }
        val result = ledger.execute(action.requestId, fingerprint, ::execute)
        // Retain the recent outcome BEFORE the socket write. Clients must not retry an unknown result.
        writeEnvelope(output, Envelope.newBuilder().setProtocolMajor(1).setProtocolMinor(0)
            .setDeviceId(deviceId()).setSessionId(envelope.sessionId).setMessageId(envelope.messageId + 1)
            .setNotificationActionResult(com.xopmc.galaxybridge.protocol.v1.NotificationActionResult.newBuilder()
                .setRequestId(action.requestId).setNotificationId(action.notificationId).setActionId(action.actionId)
                .setAccepted(result.accepted).setErrorCode(result.errorCode)).build())
    }

    private fun handleCameraConfiguration(envelope: Envelope) {
        val configuration = envelope.cameraConfiguration
        CameraStartCoordinator(AndroidCameraStartGateway(context)).apply(
            CameraCaptureRequest(
                requestId = configuration.requestId.ifBlank { UUID.randomUUID().toString() },
                enabled = configuration.enabled,
                cameraId = configuration.cameraId,
                width = configuration.width,
                height = configuration.height,
                framesPerSecond = configuration.framesPerSecond,
            ),
        )
    }

    private fun writeTransferAck(
        output: DataOutputStream,
        request: Envelope,
        ack: com.xopmc.galaxybridge.protocol.v1.TransferAck,
    ) {
        writeEnvelope(
            output,
            Envelope.newBuilder()
                .setProtocolMajor(1)
                .setProtocolMinor(0)
                .setDeviceId(deviceId())
                .setSessionId(request.sessionId)
                .setMessageId(request.messageId + 1)
                .setTransferAck(ack)
                .build(),
        )
    }

    private fun readEnvelope(input: DataInputStream): Envelope {
        val length = input.readInt()
        require(length in 1..MAX_CONTROL_FRAME) { "invalid control frame length" }
        val bytes = ByteArray(length)
        input.readFully(bytes)
        return Envelope.parseFrom(bytes)
    }

    private fun writeEnvelope(output: DataOutputStream, envelope: Envelope) {
        controlWriters[output]?.let { it.reply(envelope); return }
        writeEncodedEnvelope(output, envelope.toByteArray())
    }

    private fun writeEncodedEnvelope(output: DataOutputStream, encoded: ByteArray) {
        synchronized(output) {
            output.writeInt(encoded.size)
            output.write(encoded)
            output.flush()
        }
    }

    private fun deviceId(): String = DeviceIdStore.getOrCreate(context)

    private fun handlePairing(
        socket: SSLSocket,
        input: DataInputStream,
        output: DataOutputStream,
        request: Envelope,
    ) {
        val prepared = preparePairing(request)
        if (prepared == null) {
            writeEnvelope(output, rejected(request))
            return
        }
        socket.soTimeout = PAIRING_RETRY_INTERVAL_MS
        writeEnvelope(output, prepared.response)
        var acknowledgedAt = 0L
        while (System.currentTimeMillis() < prepared.candidate.expiresAtMillis) {
            val incoming = try {
                readEnvelope(input)
            } catch (_: SocketTimeoutException) {
                if (prepared.processor.isCommitted &&
                    System.currentTimeMillis() - acknowledgedAt >= ACK_RETRY_WINDOW_MS
                ) return
                writeEnvelope(output, prepared.response)
                continue
            }
            if (incoming.sessionId != prepared.candidate.sessionId) continue
            if (incoming.hasPairingRequest()) {
                writeEnvelope(output, prepared.response)
                continue
            }
            if (!incoming.hasPairingCommit()) continue
            val wasCommitted = prepared.processor.isCommitted
            val accepted = prepared.processor.accept(
                incoming.pairingCommit,
                promote = {
                    context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
                        .remove(PENDING_PAIRING)
                        .putString(
                            PAIRED_MAC_KEY,
                            Base64.encodeToString(prepared.candidate.macPublicKey, Base64.NO_WRAP),
                        )
                        .putString(PAIRED_HOST_ID, prepared.candidate.hostId)
                        .putLong(PAIRED_AT, System.currentTimeMillis())
                        .commit()
                },
                signAcknowledgement = identity::signNonce,
            ) ?: continue
            writeEnvelope(
                output,
                Envelope.newBuilder()
                    .setProtocolMajor(1)
                    .setProtocolMinor(0)
                    .setDeviceId(prepared.candidate.deviceId)
                    .setSessionId(prepared.candidate.sessionId)
                    .setMessageId(incoming.messageId + 1)
                    .setPairingCommitAck(accepted.acknowledgement)
                    .build(),
            )
            if (!wasCommitted) {
                acknowledgedAt = System.currentTimeMillis()
                PairingStateBus.publishSuccess()
            }
        }
    }

    private fun preparePairing(envelope: Envelope): PreparedPairing? {
        val request = envelope.pairingRequest
        val uri = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .getString(PENDING_PAIRING, null)
            ?: return null
        val qr = runCatching { PairingUriCodec.decode(uri, System.currentTimeMillis() / 1_000) }
            .getOrElse { return null }
        val macKey = request.identityPublicKey.toByteArray()
        val clientNonce = request.clientNonce.toByteArray()
        val token = request.oneTimeToken.toByteArray()
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(macKey)
        val requestTranscript = PairingTranscript.makeRequest(
            token,
            clientNonce,
            macKey,
            request.displayName.toByteArray(Charsets.UTF_8),
        )
        val valid = envelope.deviceId == qr.hostId.toString() &&
            envelope.sessionId.isNotBlank() && envelope.sessionId.length <= 128 &&
            macKey.size == 65 &&
            clientNonce.size == 32 &&
            MessageDigest.isEqual(token, qr.token) &&
            MessageDigest.isEqual(fingerprint, qr.publicKeyFingerprint) &&
            PairingTranscript.verify(request.transcriptSignature.toByteArray(), requestTranscript, macKey)
        if (!valid) return null

        val localDeviceId = deviceId()
        val serverNonce = ByteArray(32).also(SecureRandom()::nextBytes)
        val androidKey = identity.publicKeyX963()
        val transcript = PairingTranscript.make(token, clientNonce, serverNonce, macKey, androidKey)
        val response = PairingResponse.newBuilder()
            .setAccepted(true)
            .setIdentityPublicKey(ByteString.copyFrom(androidKey))
            .setServerNonce(ByteString.copyFrom(serverNonce))
            .setTranscriptSignature(ByteString.copyFrom(identity.signNonce(transcript)))
            .setTlsCertificateSha256(ByteString.copyFrom(identity.certificateSha256()))
            .setDisplayName("${Build.MANUFACTURER} ${Build.MODEL}")
            .setDeviceId(localDeviceId)
            .build()
        val candidate = PairingCommitCandidate(
            token = token,
            clientNonce = clientNonce,
            serverNonce = serverNonce,
            macPublicKey = macKey,
            androidPublicKey = androidKey,
            hostId = qr.hostId.toString(),
            deviceId = localDeviceId,
            sessionId = envelope.sessionId,
            expiresAtMillis = qr.expiresAtEpochSeconds * 1_000,
        )
        return PreparedPairing(
            response = responseEnvelope(envelope, response),
            candidate = candidate,
            processor = PairingCommitProcessor(candidate),
        )
    }

    private data class PreparedPairing(
        val response: Envelope,
        val candidate: PairingCommitCandidate,
        val processor: PairingCommitProcessor,
    )

    private fun rejected(envelope: Envelope): Envelope = responseEnvelope(
        envelope,
        PairingResponse.newBuilder().setAccepted(false).setRejectionReason("pairing_denied").build(),
    )

    private fun responseEnvelope(request: Envelope, response: PairingResponse): Envelope =
        Envelope.newBuilder()
            .setProtocolMajor(1)
            .setProtocolMinor(0)
            .setDeviceId(deviceId())
            .setSessionId(request.sessionId)
            .setMessageId(request.messageId + 1)
            .setPairingResponse(response)
            .build()

    private class IdentityKeyManager(
        private val privateKey: PrivateKey,
        private val chain: Array<X509Certificate>,
    ) : X509ExtendedKeyManager() {
        override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = ALIAS
        override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?) = ALIAS
        override fun getCertificateChain(alias: String?) = if (alias == ALIAS) chain else null
        override fun getPrivateKey(alias: String?) = if (alias == ALIAS) privateKey else null
        override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(ALIAS)
        override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = null
        override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = null
        override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = null
    }

    private companion object {
        // Shared across server restarts so a stuck old catalogue operation
        // cannot evade the bound by reconnecting or restarting the listener.
        val controlAdmission = CompanionControlAdmission()
        const val TAG = "GalaxyBridgeLAN"
        const val SERVICE_TYPE = "_galaxybridge._tcp."
        const val PREFERENCES = "galaxybridge"
        const val PENDING_PAIRING = "pending_pairing"
        const val PAIRED_MAC_KEY = "paired_mac_key"
        const val PAIRED_HOST_ID = "paired_host_id"
        const val PAIRED_AT = "paired_at"
        const val ALIAS = "galaxybridge"
        const val MAX_CONTROL_FRAME = 8 * 1024 * 1024
        const val SOCKET_TIMEOUT_MS = 15_000
        const val PAIRING_RETRY_INTERVAL_MS = 1_000
        const val ACK_RETRY_WINDOW_MS = 3_000L
        const val MEDIA_FLAG_CONFIGURATION = 1
        const val MEDIA_FLAG_KEY_FRAME = 2
        const val MAX_TEXT_LENGTH = 4_096
        const val MAX_CLIPBOARD_BYTES = ClipboardPayloadPolicy.MAX_IMAGE_BYTES
        const val CLIPBOARD_IMAGE_TTL_MS = 24 * 60 * 60 * 1_000L
    }
}
