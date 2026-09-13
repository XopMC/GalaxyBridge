package com.xopmc.galaxybridge.service

import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RealtimeCameraFrameBufferTest {
    @Test
    fun `slow subscriber drops stale backlog and receives newest frames`() = runBlocking {
        val buffer = RealtimeCameraFrameBuffer(capacity = 2)
        val received = CopyOnWriteArrayList<Int>()
        val firstFrameEntered = CompletableDeferred<Unit>()
        val releaseSubscriber = CompletableDeferred<Unit>()

        val collector = launch(start = CoroutineStart.UNDISPATCHED) {
            buffer.frames.collect { frame ->
                received += frame.epoch
                if (frame.epoch == 0) {
                    firstFrameEntered.complete(Unit)
                    releaseSubscriber.await()
                }
                if (frame.epoch == 20) cancel()
            }
        }

        buffer.offer(frame(0))
        firstFrameEntered.await()
        (1..20).forEach { assertTrue(buffer.offer(frame(it))) }
        releaseSubscriber.complete(Unit)
        withTimeout(1_000) { collector.join() }

        assertEquals(listOf(0, 19, 20), received)
    }

    private fun frame(marker: Int) = EncodedCameraFrame(
        flags = 0,
        epoch = marker,
        presentationTimeUs = marker.toLong(),
        payload = byteArrayOf(marker.toByte()),
    )
}
