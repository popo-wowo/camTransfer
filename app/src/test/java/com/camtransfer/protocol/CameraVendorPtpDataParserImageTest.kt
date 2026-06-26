package com.camtransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
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
    fun parsesCountPrefixedSizedPtpStringDateCountsFromCameraVendorGallery() {
        val firstRecord = ptpString("20260620") + uint32(12)
        val secondRecord = ptpString("20260619") + uint32(3)
        val payload = uint32(2) +
            uint32(firstRecord.size + 4) + firstRecord +
            uint32(secondRecord.size + 4) + secondRecord

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
    fun describesLegacySearchModeSnapshotEntriesForFormatResearch() {
        val payload = uint32(1) +
            uint16(CameraVendorSearchMode.OBJECT_FORMAT_PROPERTY) +
            uint16(CameraVendorSearchMode.DATA_TYPE_UINT16) +
            uint32(CameraVendorSearchMode.FORMAT_RAW)

        val result = CameraVendorPtpDataParser.searchModeSnapshot(payload)

        assertEquals("[0xD604/type=1/value=16/layout=legacy8]", result)
    }

    @Test
    fun describesNativeSearchModeSnapshotEntriesForFormatResearch() {
        val payload = uint32(1) +
            uint16(CameraVendorSearchMode.DATA_TYPE_UINT16) +
            uint16(CameraVendorSearchMode.OBJECT_FORMAT_PROPERTY) +
            uint32(CameraVendorSearchMode.FORMAT_HEIF) +
            ByteArray(10)

        val result = CameraVendorPtpDataParser.searchModeSnapshot(payload)

        assertEquals("[0xD604/type=1/value=2/layout=native18]", result)
    }

    @Test
    fun describesCameraSearchModeSnapshotSizedEntriesFromRealCamera() {
        val payload = hex(
            "050000000900000001d60100000900000002d60100000800000003d600000800000004d600000a00000005d600000000"
        )

        val result = CameraVendorPtpDataParser.searchModeSnapshot(payload)

        assertEquals(
            "[0xD601/type=65535/value=1/layout=sized, " +
                "0xD602/type=65535/value=1/layout=sized, " +
                "0xD603/type=4/value=0/layout=sized, " +
                "0xD604/type=4/value=0/layout=sized, " +
                "0xD605/type=6/value=0/layout=sized]",
            result,
        )
    }

    @Test
    fun buildsOfficialEmptySearchModeAllPayload() {
        val payload = CameraVendorPtpDataParser.emptySearchModeAllPayload()

        assertArrayEquals(uint32(0), payload)
        assertEquals("[]", CameraVendorPtpDataParser.searchModeSnapshot(payload))
    }

    @Test
    fun buildsOfficialObjectFormatSearchModeAllPayload() {
        val payload = CameraVendorPtpDataParser.officialObjectFormatSearchModeAllPayload(
            CameraVendorSearchMode.ALL_FORMATS,
        )

        assertArrayEquals(
            uint32(1) +
                uint32(8) +
                uint16(CameraVendorSearchMode.OBJECT_FORMAT_PROPERTY) +
                uint16(CameraVendorSearchMode.ALL_FORMATS),
            payload,
        )
        assertEquals("[0xD604/type=4/value=31/layout=sized]", CameraVendorPtpDataParser.searchModeSnapshot(payload))
    }

    @Test
    fun replacesCameraSearchModeObjectFormatValueWithoutChangingOtherBytes() {
        val payload = uint32(2) +
            uint32(9) + uint16(0xD601) + uint16(1) +
            uint32(8) + uint16(CameraVendorSearchMode.OBJECT_FORMAT_PROPERTY) + uint16(0)

        val result = CameraVendorPtpDataParser.searchModeWithObjectFormat(
            payload,
            CameraVendorSearchMode.FORMAT_HEIF,
        )

        assertArrayEquals(
            uint32(2) +
                uint32(9) + uint16(0xD601) + uint16(1) +
                uint32(CameraVendorSearchMode.FORMAT_HEIF) +
                uint16(CameraVendorSearchMode.OBJECT_FORMAT_PROPERTY) + uint16(0),
            result,
        )
    }

    @Test
    fun replacesObjectFormatInRealCameraSearchModePayloadFromDiagnostics() {
        val payload = hex(
            "050000000900000001d60100000900000002d60100000800000003d600000800000004d600000a00000005d600000000"
        )

        val result = CameraVendorPtpDataParser.searchModeWithObjectFormat(
            payload,
            CameraVendorSearchMode.FORMAT_RAW,
        )

        assertEquals(
            "[0xD601/type=65535/value=1/layout=sized, " +
                "0xD602/type=65535/value=1/layout=sized, " +
                "0xD603/type=4/value=0/layout=sized, " +
                "0xD604/type=4/value=16/layout=sized, " +
                "0xD605/type=6/value=0/layout=sized]",
            CameraVendorPtpDataParser.searchModeSnapshot(result ?: ByteArray(0)),
        )
        assertEquals(8, result?.let { uint32At(it, 30) })
        assertEquals(CameraVendorSearchMode.FORMAT_RAW, result?.let { uint16At(it, 36) })
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

    private fun uint16(value: Int): ByteArray =
        byteArrayOf(
            (value and 0xFF).toByte(),
            ((value ushr 8) and 0xFF).toByte(),
        )

    private fun uint32At(data: ByteArray, offset: Int): Int =
        (data[offset].toInt() and 0xFF) or
            ((data[offset + 1].toInt() and 0xFF) shl 8) or
            ((data[offset + 2].toInt() and 0xFF) shl 16) or
            ((data[offset + 3].toInt() and 0xFF) shl 24)

    private fun uint16At(data: ByteArray, offset: Int): Int =
        (data[offset].toInt() and 0xFF) or
            ((data[offset + 1].toInt() and 0xFF) shl 8)

    private fun hex(value: String): ByteArray =
        value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

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
