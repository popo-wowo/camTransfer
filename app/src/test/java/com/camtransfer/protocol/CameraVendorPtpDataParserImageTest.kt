package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorPtpDataParserImageTest {
    @Test
    fun detectsJpegAfterCameraWrapperIsNormalized() {
        val raw = byteArrayOf(0x00, 0x01, 0x02, 0x03, 0xFF.toByte(), 0xD8.toByte(), 0x11, 0x22)

        val image = CameraVendorPtpDataParser.imageData(raw)

        assertEquals(0xFF.toByte(), image[0])
        assertEquals(0xD8.toByte(), image[1])
        assertTrue(CameraVendorPtpDataParser.isLikelyImageData(image))
    }

    @Test
    fun rejectsNonImageThumbnailPayloadsSoPreviewFallbackCanRun() {
        val raw = ByteArray(128) { it.toByte() }

        assertFalse(CameraVendorPtpDataParser.isLikelyImageData(CameraVendorPtpDataParser.imageData(raw)))
    }
}
