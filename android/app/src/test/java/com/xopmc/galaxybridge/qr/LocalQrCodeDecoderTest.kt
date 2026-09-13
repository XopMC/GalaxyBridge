package com.xopmc.galaxybridge.qr

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LocalQrCodeDecoderTest {
    @Test
    fun decodesGalaxyBridgeQrEntirelyOnDevice() {
        val payload = "galaxybridge://pair?v=1&token=local-only"
        val matrix = QRCodeWriter().encode(payload, BarcodeFormat.QR_CODE, 256, 256)
        val luminance = ByteArray(matrix.width * matrix.height) { index ->
            val x = index % matrix.width
            val y = index / matrix.width
            if (matrix[x, y]) 0 else 0xFF.toByte()
        }

        assertEquals(
            payload,
            LocalQrCodeDecoder.decode(
                QrLuminanceFrame(luminance, matrix.width, matrix.height),
            ),
        )
    }

    @Test
    fun decodesInvertedGalaxyBridgeQrUsedOnDarkSurfaces() {
        val payload = "galaxybridge://pair?v=1&token=local-only"
        val matrix = QRCodeWriter().encode(payload, BarcodeFormat.QR_CODE, 256, 256)
        val invertedLuminance = ByteArray(matrix.width * matrix.height) { index ->
            val x = index % matrix.width
            val y = index / matrix.width
            if (matrix[x, y]) 0xFF.toByte() else 0
        }

        assertEquals(
            payload,
            LocalQrCodeDecoder.decode(
                QrLuminanceFrame(invertedLuminance, matrix.width, matrix.height),
            ),
        )
    }

    @Test
    fun rotatesStridedCameraLuminanceWithoutReadingChroma() {
        val source = byteArrayOf(
            1, 99, 2, 99, 3, 99, 88, 88,
            4, 99, 5, 99, 6, 99, 88, 88,
        )

        val rotated = QrLuminanceFrame.fromYPlane(
            bytes = source,
            width = 3,
            height = 2,
            rowStride = 8,
            pixelStride = 2,
            clockwiseRotationDegrees = 90,
        )

        assertEquals(2, rotated.width)
        assertEquals(3, rotated.height)
        assertEquals(listOf<Byte>(4, 1, 5, 2, 6, 3), rotated.bytes.toList())
    }

    @Test
    fun rejectsNonQrPixels() {
        assertNull(LocalQrCodeDecoder.decode(QrLuminanceFrame(ByteArray(64), 8, 8)))
    }

    @Test
    fun rejectedCandidateDoesNotDisableFollowingFrames() {
        val gate = QrScanGate()

        assertEquals(true, gate.beginFrame())
        gate.completeFrame(accepted = false)
        assertEquals(true, gate.beginFrame())
        gate.completeFrame(accepted = true)
        assertEquals(false, gate.beginFrame())
    }
}
