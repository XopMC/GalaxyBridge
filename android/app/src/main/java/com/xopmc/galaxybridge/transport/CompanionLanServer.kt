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

internal class CompanionReceiverStartup<T : Any>(
    factory: () -> T,
) {
    private val receiver = lazy(LazyThreadSafetyMode.SYNCHRONIZED, factory)

    suspend fun initializeOnIo(): T = withContext(Dispatchers.IO) {
        receiver.value
    }
}

class CompanionLanServer(private val context: Context) {
    private val identity = DeviceIdentityStore()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val running = AtomicBoolean(false)
    private var serverSocket: SSLServerSocket? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var acceptJob: Job? = null
    private val activeSessions = CompanionSessionRegistry()
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
        activeSessions.register(envelope.deviceId, envelope.sessionId, socket)
        try {
            socket.soTimeout = 0
            writeEnvelope(output, hello(envelope))
            writeEnvelope(output, capabilities(envelope))
            while (!socket.isClosed) {
                val incoming = runCatching { readEnvelope(input) }.getOrNull() ?: return
                when (CompanionControlPayloadPolicy.classify(incoming)) {
                    CompanionControlPayloadKind.OPEN_CHANNEL -> when (incoming.openChannel.kind) {
                        ChannelKind.CHANNEL_KIND_VIDEO -> return streamVideo(socket, input, output)
                        ChannelKind.CHANNEL_KIND_AUDIO -> return streamAudio(socket, input, output)
                        ChannelKind.CHANNEL_KIND_CAMERA -> return streamCamera(socket, input, output)
                        ChannelKind.CHANNEL_KIND_EVENTS -> return streamEvents(socket, input, output, envelope.sessionId)
                        ChannelKind.CHANNEL_KIND_FILES -> {
                            if (fileOwner == null || fileOwner != transferReceiver.authenticatedOwner(envelope.deviceId)) return
                            return handleFiles(socket, input, output, envelope.sessionId, fileOwner, transferReceiver)
                        }
                        else -> writeEnvelope(
                            output,
                            CompanionControlPayloadPolicy.unsupportedResponse(incoming, deviceId()),
                        )
                    }
                    CompanionControlPayloadKind.PING -> {
                        writeEnvelope(
                            output,
                            Envelope.newBuilder()
                                .setProtocolMajor(1)
                                .setProtocolMinor(0)
                                .setDeviceId(deviceId())
                                .setSessionId(incoming.sessionId)
                                .setMessageId(incoming.messageId + 1)
                                .setPong(Pong.newBuilder().setEchoedMonotonicTimeNs(incoming.ping.monotonicTimeNs))
                                .build(),
                        )
                    }
                    CompanionControlPayloadKind.INPUT -> handleInput(incoming)
                    CompanionControlPayloadKind.CLIPBOARD -> handleClipboard(incoming.clipboardUpdate)
                    CompanionControlPayloadKind.NOTIFICATION_ACTION -> handleNotificationAction(incoming)
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
                }
            }
        } finally {
            activeSessions.unregister(envelope.deviceId, envelope.sessionId, socket)
        }
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
            if (telephonyEnabled) {
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
                NotificationEventBus.events.map { emission ->
                    Envelope.newBuilder()
                        .setProtocolMajor(1)
                        .setProtocolMinor(0)
                        .setDeviceId(deviceId())
                        .setSessionId(sessionId)
                        .setMessageId(nextMessageId.getAndIncrement())
                        .setNotificationEvent(
                            NotificationEventMapper.toProtocol(
                                emission.notification,
                                isInitialSnapshot = emission.isInitialSnapshot,
                            ),
                        )
                        .build()
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
            ).collect { event -> writeEnvelope(output, event) }
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

    private fun handleNotificationAction(envelope: Envelope) {
        val action = envelope.notificationAction
        if (action.dismiss) {
            GalaxyNotificationListenerService.dismissActive(action.notificationId)
        } else {
            GalaxyNotificationListenerService.invokeActive(
                action.notificationId,
                action.actionId,
                action.replyText.takeIf { it.isNotBlank() },
            )
        }
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
        val encoded = envelope.toByteArray()
        synchronized(output) {
            output.writeInt(encoded.size)
            output.write(encoded)
            output.flush()
        }
    }

    private fun deviceId(): String {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        return preferences.getString(DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
            preferences.edit { putString(DEVICE_ID, it) }
        }
    }

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
        const val TAG = "GalaxyBridgeLAN"
        const val SERVICE_TYPE = "_galaxybridge._tcp."
        const val PREFERENCES = "galaxybridge"
        const val PENDING_PAIRING = "pending_pairing"
        const val PAIRED_MAC_KEY = "paired_mac_key"
        const val PAIRED_HOST_ID = "paired_host_id"
        const val PAIRED_AT = "paired_at"
        const val DEVICE_ID = "device_id"
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
