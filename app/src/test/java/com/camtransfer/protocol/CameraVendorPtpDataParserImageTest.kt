package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorPtpDataParserImageTest {
    @Test
    fun parsesCameraVendorObjectInfoOrientationMetadata() {
        val payload = byteArrayOf(
            0x01, 0x00, 0x00, 0x10, 0x12, 0x38, 0x00, 0x00,
            0x07, 0xB1.toByte(), 0x0D, 0x00, 0x01, 0xB9.toByte(), 0x80.toByte(), 0xCB.toByte(),
            0x00, 0x00, 0x80.toByte(), 0x02, 0x00, 0x00, 0xE0.toByte(), 0x01,
            0x00, 0x00, 0x30, 0x1E, 0x00, 0x00, 0x20, 0x14,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ) + ptpString("DSCF3309.HEIC") +
            ptpString("20260328T045849") +
            ptpString("Orientation:2")

        val info = CameraVendorPtpDataParser.cameraVendorObjectInfo(0x10000001, payload)

        assertEquals("DSCF3309.HEIC", info.filename)
        assertEquals("20260328T045849", info.captureDate)
        assertEquals(2, info.orientation)
    }

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

    private fun ptpString(value: String): ByteArray {
        val bytes = ArrayList<Byte>()
        bytes.add((value.length + 1).toByte())
        for (char in value) {
            bytes.add(char.code.toByte())
            bytes.add(0)
        }
        bytes.add(0)
        bytes.add(0)
        return bytes.toByteArray()
    }
}
