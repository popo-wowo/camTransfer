package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorPtpDataParserImageTest {
    @Test
    fun parsesCountPrefixedPtpStringDateCounts() {
        val payload = uint32(2) +
            ptpString("20260620") + uint32(12) +
            ptpString("20260619") + uint32(3)

        val result = CameraVendorPtpDataParser.objectCountsByDate(payload)

        assertEquals(
            listOf(
                CameraVendorObjectCountByDate("20260620", 12),
                CameraVendorObjectCountByDate("20260619", 3),
            ),
            result,
        )
    }

    @Test
    fun parsesCountPrefixedAsciiDateCounts() {
        val payload = uint32(2) +
            "20260620".toByteArray(Charsets.US_ASCII) + uint32(12) +
            "20260619".toByteArray(Charsets.US_ASCII) + uint32(3)

        val result = CameraVendorPtpDataParser.objectCountsByDate(payload)

        assertEquals(
            listOf(
                CameraVendorObjectCountByDate("20260620", 12),
                CameraVendorObjectCountByDate("20260619", 3),
            ),
            result,
        )
    }

    @Test
    fun rejectsImplausibleDateCountPayloads() {
        val payload = uint32(1) + ptpString("not-a-date") + uint32(12)

        assertEquals(emptyList<CameraVendorObjectCountByDate>(), CameraVendorPtpDataParser.objectCountsByDate(payload))
    }

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
        assertEquals(1, info.orientation)
    }

    @Test
    fun mapsCameraVendorRawOrientationMetadataLikeReferenceApp() {
        val expected = mapOf(
            1 to 1,
            2 to 1,
            6 to 2,
            7 to 2,
            3 to 3,
            4 to 3,
            5 to 4,
            8 to 4,
        )

        expected.forEach { (rawOrientation, normalizedOrientation) ->
            val payload = cameraVendorObjectInfoPayload(
                filename = "DSCF3309.HEIC",
                captureDate = "20260328T045849",
                metadata = listOf("Orientation:$rawOrientation"),
            )

            val info = CameraVendorPtpDataParser.cameraVendorObjectInfo(0x10000001, payload)

            assertEquals("raw orientation $rawOrientation", normalizedOrientation, info.orientation)
        }
    }

    @Test
    fun parsesStandardObjectInfoOrientationMetadataAfterCaptureDate() {
        val payload = standardObjectInfoPayload(
            filename = "DSCF3310.JPG",
            captureDate = "20260328T050001",
            metadata = listOf("Orientation:6"),
        )

        val info = CameraVendorPtpDataParser.objectInfo(0x10000002, payload)

        assertEquals("DSCF3310.JPG", info.filename)
        assertEquals("20260328T050001", info.captureDate)
        assertEquals(2, info.orientation)
    }

    @Test
    fun skipsEmptyObjectInfoMetadataFieldsBeforeOrientation() {
        val payload = standardObjectInfoPayload(
            filename = "DSCF3311.JPG",
            captureDate = "20260328T050002",
            metadata = listOf("", "Orientation:8"),
        )

        val info = CameraVendorPtpDataParser.objectInfo(0x10000003, payload)

        assertEquals(4, info.orientation)
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

    private fun uint32(value: Int): ByteArray =
        byteArrayOf(
            (value and 0xFF).toByte(),
            ((value ushr 8) and 0xFF).toByte(),
            ((value ushr 16) and 0xFF).toByte(),
            ((value ushr 24) and 0xFF).toByte(),
        )

    private fun standardObjectInfoPayload(
        filename: String,
        captureDate: String,
        metadata: List<String>,
    ): ByteArray =
        ByteArray(52) + ptpString(filename) + ptpString(captureDate) + metadata.flatMap { ptpString(it).toList() }
            .toByteArray()

    private fun cameraVendorObjectInfoPayload(
        filename: String,
        captureDate: String,
        metadata: List<String>,
    ): ByteArray =
        ByteArray(54) + ptpString(filename) + ptpString(captureDate) + metadata.flatMap { ptpString(it).toList() }
            .toByteArray()
}
