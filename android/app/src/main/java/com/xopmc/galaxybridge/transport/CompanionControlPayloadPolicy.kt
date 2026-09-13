package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.BuildConfig
import com.xopmc.galaxybridge.protocol.v1.Envelope
import com.xopmc.galaxybridge.protocol.v1.ErrorEvent
import com.xopmc.galaxybridge.setup.DistributionFeatures

internal enum class CompanionControlPayloadKind {
    OPEN_CHANNEL,
    PING,
    INPUT,
    CLIPBOARD,
    NOTIFICATION_ACTION,
    CAMERA_CONFIGURATION,
    CALL,
    TRANSFER_MANIFEST,
    TRANSFER_CHUNK,
    TRANSFER_CANCEL,
    TRANSFER_ACK,
    UNSUPPORTED,
}

internal object CompanionControlPayloadPolicy {
    fun classify(envelope: Envelope): CompanionControlPayloadKind = when (envelope.payloadCase) {
        Envelope.PayloadCase.OPEN_CHANNEL -> CompanionControlPayloadKind.OPEN_CHANNEL
        Envelope.PayloadCase.PING -> CompanionControlPayloadKind.PING
        Envelope.PayloadCase.INPUT_EVENT -> CompanionControlPayloadKind.INPUT
        Envelope.PayloadCase.CLIPBOARD_UPDATE -> CompanionControlPayloadKind.CLIPBOARD
        Envelope.PayloadCase.NOTIFICATION_ACTION -> CompanionControlPayloadKind.NOTIFICATION_ACTION
        Envelope.PayloadCase.CAMERA_CONFIGURATION -> CompanionControlPayloadKind.CAMERA_CONFIGURATION
        Envelope.PayloadCase.CALL_EVENT -> if (
            DistributionFeatures.telephonyEnabled(BuildConfig.DISTRIBUTION)
        ) {
            CompanionControlPayloadKind.CALL
        } else {
            CompanionControlPayloadKind.UNSUPPORTED
        }
        Envelope.PayloadCase.TRANSFER_MANIFEST -> CompanionControlPayloadKind.TRANSFER_MANIFEST
        Envelope.PayloadCase.TRANSFER_CHUNK -> CompanionControlPayloadKind.TRANSFER_CHUNK
        Envelope.PayloadCase.TRANSFER_CANCEL -> CompanionControlPayloadKind.TRANSFER_CANCEL
        Envelope.PayloadCase.TRANSFER_ACK -> CompanionControlPayloadKind.TRANSFER_ACK
        else -> CompanionControlPayloadKind.UNSUPPORTED
    }

    fun unsupportedResponse(request: Envelope, deviceId: String): Envelope {
        val directSms = request.hasSmsEvent()
        return Envelope.newBuilder()
            .setProtocolMajor(1)
            .setProtocolMinor(0)
            .setDeviceId(deviceId)
            .setSessionId(request.sessionId)
            .setMessageId(request.messageId + 1)
            .setError(
                ErrorEvent.newBuilder()
                    .setCode(if (directSms) "sms_notification_actions_only" else "unsupported_payload")
                    .setSafeMessage(
                        if (directSms) {
                            "Reply through a message notification action."
                        } else {
                            "This request is not supported by Galaxy Bridge on this phone."
                        },
                    )
                    .setRetryable(false),
            )
            .build()
    }
}
