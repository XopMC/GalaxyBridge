package com.xopmc.galaxybridge.transport

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.xopmc.galaxybridge.core.NearbyConsent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Memory only. UI consent cannot survive connection retirement or Helper leaving the foreground. */
object NearbyConsentBus {
    private val policy = NearbyConsent()
    private val handler = Handler(Looper.getMainLooper())
    private val mutablePrompt = MutableStateFlow<NearbyConsent.Prompt?>(null)
    val prompt = mutablePrompt.asStateFlow()
    @Synchronized fun setVisible(visible: Boolean) { policy.setVisible(visible); publish() }
    @Synchronized fun request(id: String, name: String, comparison: String): NearbyConsent.Decision {
        val result = policy.request(id, name, comparison, SystemClock.elapsedRealtime())
        publish()
        if (result == NearbyConsent.Decision.PENDING && expiryID != id) {
            expiryID = id
            handler.postDelayed({ expire(id) }, 60_000)
        }
        return result
    }
    private var expiryID: String? = null
    @Synchronized private fun expire(id: String) {
        if (expiryID == id) {
            policy.expire(SystemClock.elapsedRealtime()); expiryID = null; publish()
        }
    }
    @Synchronized fun answer(id: String, approve: Boolean) {
        policy.answer(id,approve,SystemClock.elapsedRealtime()); publish()
    }
    @Synchronized fun retire(id: String) {
        policy.retire(id,SystemClock.elapsedRealtime())
        if (expiryID == id) expiryID = null
        publish()
    }
    private fun publish() { mutablePrompt.value = policy.pending }
}
