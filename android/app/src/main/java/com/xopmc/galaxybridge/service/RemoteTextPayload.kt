package com.xopmc.galaxybridge.service

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Base64

internal object RemoteTextPayload {
    private const val MAX_CODE_POINTS = 4_096
    private const val MAX_UTF8_BYTES = 32 * 1_024

    fun encode(text: String): String = Base64.getEncoder()
        .encodeToString(text.toByteArray(StandardCharsets.UTF_8))

    fun decode(encoded: String): String? {
        val bytes = runCatching { Base64.getDecoder().decode(encoded) }.getOrNull()
            ?: return null
        if (bytes.isEmpty() || bytes.size > MAX_UTF8_BYTES) return null
        val text = runCatching {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        }.getOrNull() ?: return null
        if (text.codePointCount(0, text.length) > MAX_CODE_POINTS) return null
        return text
    }
}
