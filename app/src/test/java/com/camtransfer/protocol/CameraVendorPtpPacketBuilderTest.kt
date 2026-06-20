package com.camtransfer.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorPtpPacketBuilderTest {

    @Test
    fun cameraVendorLegacyInitUsesKnownWorkingWireFormat() {
        val packet = PtpPacketBuilder.buildCameraVendorLegacyInitCommandRequest(
            friendlyName = "CamTransfer",
        )

        assertEquals(82, packet.size)
        assertArrayEquals(
            byteArrayOf(
                0x52, 0x00, 0x00, 0x00,
                0x01, 0x00, 0x00, 0x00,
                0xF2.toByte(), 0xE4.toByte(), 0x53, 0x8F.toByte(),
                0xAD.toByte(), 0xA5.toByte(), 0x48, 0x5D,
                0x87.toByte(), 0xB2.toByte(), 0x7F, 0x0B,
                0xD3.toByte(), 0xD5.toByte(), 0xDE.toByte(), 0xD0.toByte(),
                0x00, 0x00, 0x00, 0x00,
            ),
            packet.copyOfRange(0, 28),
        )
        assertArrayEquals(
            "CamTransfer".toByteArray(Charsets.UTF_16LE) + byteArrayOf(0x00, 0x00),
            packet.copyOfRange(28, 52),
        )
        assertEquals(true, packet.copyOfRange(52, packet.size).all { it == 0.toByte() })
    }

    @Test
    fun cameraVendorLegacyOperationOmitsStandardPtpIpTypeHeader() {
        val packet = PtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
            opCode = PtpOpCode.OPEN_SESSION,
            transactionId = 1,
            params = listOf(1),
        )

        assertArrayEquals(
            byteArrayOf(
                0x10, 0x00, 0x00, 0x00,
                0x01, 0x00,
                0x02, 0x10,
                0x01, 0x00, 0x00, 0x00,
                0x01, 0x00, 0x00, 0x00,
            ),
            packet,
        )
    }

    @Test
    fun cameraVendorLegacyDataOutUsesKindTwoAndPayload() {
        val packet = PtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
            opCode = PtpOpCode.SET_DEVICE_PROP_VALUE,
            transactionId = 7,
            data = byteArrayOf(0x05, 0x00, 0x00, 0x00),
        )

        assertArrayEquals(
            byteArrayOf(
                0x10, 0x00, 0x00, 0x00,
                0x02, 0x00,
                0x16, 0x10,
                0x07, 0x00, 0x00, 0x00,
                0x05, 0x00, 0x00, 0x00,
            ),
            packet,
        )
    }

    @Test
    fun cameraVendorLegacyDecoderMapsDataAndTerminalResponseKinds() {
        val dataPacket = CameraVendorLegacyPacketDecoder.decode(
            byteArrayOf(
                0x10, 0x00, 0x00, 0x00,
                0x02, 0x00,
                0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte(), 0xEE.toByte(), 0xFF.toByte(),
                0x11, 0x22, 0x33, 0x44,
            )
        )
        assertEquals(PtpPacketType.DATA_PACKET, dataPacket.type)
        assertArrayEquals(byteArrayOf(0x11, 0x22, 0x33, 0x44), dataPacket.payload)

        val terminalResponse = CameraVendorLegacyPacketDecoder.decode(
            byteArrayOf(
                0x0C, 0x00, 0x00, 0x00,
                0x0C, 0x00,
                0x34, 0x12,
                0x09, 0x00, 0x00, 0x00,
            )
        )
        assertEquals(PtpPacketType.OPERATION_RESPONSE, terminalResponse.type)
        assertArrayEquals(
            byteArrayOf(0x01, 0x20, 0x09, 0x00, 0x00, 0x00),
            terminalResponse.payload,
        )
    }
}
