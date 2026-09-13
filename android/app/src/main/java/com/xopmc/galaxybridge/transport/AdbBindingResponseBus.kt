package com.xopmc.galaxybridge.transport

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow

data class SignedAdbBindingResponse(
    val adbSerial: String,
    val nonce: ByteArray,
    val identityPublicKey: ByteArray,
    val signature: ByteArray,
)

/** Responses are only consumed by an authenticated Companion TLS events channel. */
object AdbBindingResponseBus {
    private val mutableResponses = MutableSharedFlow<SignedAdbBindingResponse>(
        replay = 1,
        extraBufferCapacity = 4,
    )
    val responses = mutableResponses.asSharedFlow()

    fun publish(response: SignedAdbBindingResponse) {
        mutableResponses.tryEmit(response)
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    fun clear() {
        mutableResponses.resetReplayCache()
    }
}
