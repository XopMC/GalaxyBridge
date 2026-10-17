package com.xopmc.galaxybridge.transport

import org.junit.Assert.*
import org.junit.Test

class PairingPromotionGateTest {
    @Test fun onlyExactSynchronousOwnPreferenceCommitIsExemptFromRevocation() {
        val gate=PairingPromotionGate();val key=byteArrayOf(1,2,3)
        var listenerRevocations=0
        fun listener(host:String?,storedKey:ByteArray?) {
            if (!gate.matches(host,storedKey)) listenerRevocations++
        }
        gate.during("host",key) {
            listener("host",key);listener("host",key)
            assertEquals(0,listenerRevocations)
            listener(null,null);assertEquals(1,listenerRevocations)
            listener("host",byteArrayOf(9));assertEquals(2,listenerRevocations)
            val otherThread=Thread { listener("host",key) };otherThread.start();otherThread.join()
            assertEquals(3,listenerRevocations)
        }
        listener("host",key);assertEquals(4,listenerRevocations)
        assertThrows(IllegalStateException::class.java) { gate.during("host",key) { error("disk failed") } }
        assertFalse(gate.matches("host",key))
    }
}
