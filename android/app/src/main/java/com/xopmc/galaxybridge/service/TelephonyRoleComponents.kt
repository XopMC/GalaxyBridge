package com.xopmc.galaxybridge.service

import android.telecom.Call
import android.telecom.InCallService
import android.telecom.VideoProfile
import com.xopmc.galaxybridge.protocol.v1.CallEvent
import com.xopmc.galaxybridge.protocol.v1.CallState
import java.lang.System.currentTimeMillis
import java.util.concurrent.ConcurrentHashMap

class GalaxyInCallService : InCallService() {
    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        activeCalls[id(call)] = call
        call.registerCallback(callback)
        publish(call)
    }

    override fun onCallRemoved(call: Call) {
        publish(call, CallState.CALL_STATE_ENDED)
        call.unregisterCallback(callback)
        activeCalls.remove(id(call))
        super.onCallRemoved(call)
    }

    private val callback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) = publish(call)
        override fun onDetailsChanged(call: Call, details: Call.Details) = publish(call)
    }

    private fun publish(call: Call, forcedState: CallState? = null) {
        val details = call.details
        CallEventBus.emit(
            CallEvent.newBuilder()
                .setCallId(id(call))
                .setAddress(details.handle?.schemeSpecificPart.orEmpty())
                .setDisplayName(details.contactDisplayName.orEmpty())
                .setState(forcedState ?: callState(details.state))
                .setIncoming(details.callDirection == Call.Details.DIRECTION_INCOMING)
                .setTimestampUnixMs(currentTimeMillis())
                .build(),
        )
    }

    companion object {
        private val activeCalls = ConcurrentHashMap<String, Call>()

        fun answer(callId: String?): Boolean {
            val call = callId?.let(activeCalls::get) ?: activeCalls.values.firstOrNull {
                it.details.state == Call.STATE_RINGING
            }
                ?: return false
            call.answer(VideoProfile.STATE_AUDIO_ONLY)
            return true
        }

        fun end(callId: String?): Boolean {
            val call = callId?.let(activeCalls::get) ?: activeCalls.values.firstOrNull() ?: return false
            call.disconnect()
            return true
        }

        private fun id(call: Call): String = System.identityHashCode(call).toString(16)

        private fun callState(state: Int): CallState = when (state) {
            Call.STATE_RINGING -> CallState.CALL_STATE_RINGING
            Call.STATE_DIALING, Call.STATE_CONNECTING, Call.STATE_SELECT_PHONE_ACCOUNT -> CallState.CALL_STATE_DIALING
            Call.STATE_ACTIVE, Call.STATE_HOLDING -> CallState.CALL_STATE_ACTIVE
            Call.STATE_DISCONNECTED, Call.STATE_DISCONNECTING -> CallState.CALL_STATE_ENDED
            else -> CallState.CALL_STATE_IDLE
        }
    }
}
