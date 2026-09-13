package com.xopmc.galaxybridge.qr

import androidx.camera.core.ImageProxy
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.atomic.AtomicBoolean

internal class QrScanGate {
    private val accepted = AtomicBoolean(false)
    private val processing = AtomicBoolean(false)

    fun beginFrame(): Boolean =
        !accepted.get() && processing.compareAndSet(false, true)

    fun completeFrame(accepted: Boolean) {
        if (accepted) this.accepted.set(true)
        processing.set(false)
    }
}

internal data class QrLuminanceFrame(
    val bytes: ByteArray,
    val width: Int,
    val height: Int,
) {
    init {
        require(width > 0 && height > 0)
        require(bytes.size == width * height)
    }

    companion object {
        fun from(image: ImageProxy): QrLuminanceFrame {
            val plane = image.planes.first()
            val buffer = plane.buffer.duplicate()
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            return fromYPlane(
                bytes = bytes,
                width = image.width,
                height = image.height,
                rowStride = plane.rowStride,
                pixelStride = plane.pixelStride,
                clockwiseRotationDegrees = image.imageInfo.rotationDegrees,
            )
        }

        fun fromYPlane(
            bytes: ByteArray,
            width: Int,
            height: Int,
            rowStride: Int,
            pixelStride: Int,
            clockwiseRotationDegrees: Int,
        ): QrLuminanceFrame {
            require(width > 0 && height > 0)
            require(rowStride >= width)
            require(pixelStride > 0)
            val packed = ByteArray(width * height)
            for (y in 0 until height) {
                for (x in 0 until width) {
                    val sourceIndex = y * rowStride + x * pixelStride
                    require(sourceIndex in bytes.indices)
                    packed[y * width + x] = bytes[sourceIndex]
                }
            }
            return rotate(packed, width, height, clockwiseRotationDegrees)
        }

        private fun rotate(
            source: ByteArray,
            width: Int,
            height: Int,
            clockwiseRotationDegrees: Int,
        ): QrLuminanceFrame {
            return when (((clockwiseRotationDegrees % 360) + 360) % 360) {
                0 -> QrLuminanceFrame(source, width, height)
                90 -> {
                    val output = ByteArray(source.size)
                    for (y in 0 until height) {
                        for (x in 0 until width) {
                            val destinationX = height - 1 - y
                            val destinationY = x
                            output[destinationY * height + destinationX] = source[y * width + x]
                        }
                    }
                    QrLuminanceFrame(output, height, width)
                }
                180 -> {
                    val output = ByteArray(source.size)
                    for (index in source.indices) output[source.lastIndex - index] = source[index]
                    QrLuminanceFrame(output, width, height)
                }
                270 -> {
                    val output = ByteArray(source.size)
                    for (y in 0 until height) {
                        for (x in 0 until width) {
                            val destinationX = y
                            val destinationY = width - 1 - x
                            output[destinationY * height + destinationX] = source[y * width + x]
                        }
                    }
                    QrLuminanceFrame(output, height, width)
                }
                else -> throw IllegalArgumentException("Camera rotation must be a multiple of 90 degrees")
            }
        }
    }
}

internal object LocalQrCodeDecoder {
    private val hints = mapOf(
        DecodeHintType.TRY_HARDER to true,
        DecodeHintType.POSSIBLE_FORMATS to listOf(com.google.zxing.BarcodeFormat.QR_CODE),
        DecodeHintType.ALSO_INVERTED to true,
    )

    fun decode(image: ImageProxy): String? = decode(QrLuminanceFrame.from(image))

    fun decode(frame: QrLuminanceFrame): String? {
        val source = PlanarYUVLuminanceSource(
            frame.bytes,
            frame.width,
            frame.height,
            0,
            0,
            frame.width,
            frame.height,
            false,
        )
        val reader = MultiFormatReader().apply { setHints(hints) }
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
        } catch (_: NotFoundException) {
            null
        } finally {
            reader.reset()
        }
    }
}
