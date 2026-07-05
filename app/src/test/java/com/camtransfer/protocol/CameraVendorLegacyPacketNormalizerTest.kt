package com.camtransfer.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorLegacyPacketNormalizerTest {
    @Test
    fun stripsDuplicatedCountFromFirst9053PacketAfterExclusiveLengthDecode() {
        val payload = (
            "13000000" +
                "13000000" +
                "1b0000000932003000320036003000360032003100000007000000" +
                "1b0000000932003000320036003000360032003000000013000000" +
                "1b0000000932003000320036003000360031003900000068000000"
            ).hexToBytes()

        val normalized = CameraVendorLegacyPacketNormalizer.normalizeDataPayload(
            opCode = PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE,
            packetIndex = 0,
            payload = payload,
        )

        assertEquals(19, uint32(normalized, 0))
        assertEquals(27, uint32(normalized, 4))
        assertArrayEquals(payload.copyOfRange(4, payload.size), normalized)
        val groups = CameraVendorPtpDataParser.objectCountsByDate(normalized)
        assertEquals(listOf("20260621" to 7, "20260620" to 19, "20260619" to 104), groups.map { it.dateValue to it.numberOfImages })
    }

    @Test
    fun stripsNestedEnvelopeFromPreviouslyObservedFirst9053PacketShape() {
        val payload = (
            "13000000" +
                "11020000" +
                "0200" +
                "5390" +
                "11000000" +
                "13000000" +
                "1b0000000932003000320036003000360032003100000007000000" +
                "1b0000000932003000320036003000360032003000000013000000" +
                "1b0000000932003000320036003000360031003900000068000000"
            ).hexToBytes()

        val normalized = CameraVendorLegacyPacketNormalizer.normalizeDataPayload(
            opCode = PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE,
            packetIndex = 0,
            payload = payload,
        )

        assertArrayEquals(payload.copyOfRange(16, payload.size), normalized)
    }

    @Test
    fun reportsAdditionalTailBytesForPreviouslyObservedFirst9053PacketShape() {
        val payload = java.nio.ByteBuffer.allocate(20)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .putInt(1)
            .putInt(32)
            .putShort(2)
            .putShort(PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE.toShort())
            .putInt(17)
            .putInt(1)
            .array()

        val additionalTailBytes = CameraVendorLegacyPacketNormalizer.additionalTailBytesForDataPayload(
            opCode = PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE,
            packetIndex = 0,
            payload = payload,
        )

        assertEquals(16, additionalTailBytes)
    }

    @Test
    fun decodesNestedLegacyPacketFromCurrent9053RuntimeShape() {
        val nestedPayload = (
            "01000000" +
                "1b0000000932003000320036003000360032003100000007000000"
            ).hexToBytes()
        val nestedRaw = java.nio.ByteBuffer.allocate(12 + nestedPayload.size)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .putInt(12 + nestedPayload.size)
            .putShort(2)
            .putShort(PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE.toShort())
            .putInt(17)
            .put(nestedPayload)
            .array()
        val runtimePayload = java.nio.ByteBuffer.allocate(4 + nestedRaw.size)
            .order(java.nio.ByteOrder.LITTLE_ENDIAN)
            .putInt(1)
            .put(nestedRaw)
            .array()

        val normalized = CameraVendorLegacyPacketNormalizer.normalizeDataPayload(
            opCode = PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE,
            packetIndex = 0,
            payload = runtimePayload,
        )

        assertArrayEquals(nestedPayload, normalized)
    }

    @Test
    fun leavesOtherPacketsUntouched() {
        val payload = byteArrayOf(1, 2, 3, 4, 5, 6)

        val normalized = CameraVendorLegacyPacketNormalizer.normalizeDataPayload(
            opCode = PtpOpCode.CAMERA_VENDOR_GET_SEARCH_MODE_DESC_ALL,
            packetIndex = 0,
            payload = payload,
        )

        assertArrayEquals(payload, normalized)
    }

    private fun String.hexToBytes(): ByteArray =
        chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private fun uint32(data: ByteArray, offset: Int): Int =
        java.nio.ByteBuffer.wrap(data, offset, 4).order(java.nio.ByteOrder.LITTLE_ENDIAN).int
}
