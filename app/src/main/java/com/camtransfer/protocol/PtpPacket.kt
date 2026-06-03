package com.camtransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

data class PtpPacket(val type: Int, val payload: ByteArray) {

    val totalLength: Int get() = 8 + payload.size

    fun encode(): ByteArray {
        val buf = ByteBuffer.allocate(8 + payload.size).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(8 + payload.size)
        buf.putInt(type)
        buf.put(payload)
        return buf.array()
    }

    companion object {
        fun decode(raw: ByteArray): PtpPacket {
            if (raw.size < 8) throw IllegalArgumentException("Packet too short: ${raw.size} bytes")
            val buf = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
            val length = buf.getInt()
            val type = buf.getInt()
            val payload = raw.copyOfRange(8, length)
            return PtpPacket(type, payload)
        }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PtpPacket) return false
        return type == other.type && payload.contentEquals(other.payload)
    }

    override fun hashCode(): Int = 31 * type + payload.contentHashCode()
}

object PtpPacketBuilder {

    fun buildInitCommandRequest(guid: ByteArray, friendlyName: String): ByteArray {
        val nameUtf16 = encodeUtf16LE(friendlyName)
        val payloadSize = 16 + nameUtf16.size + 4
        val payload = ByteBuffer.allocate(payloadSize).order(ByteOrder.LITTLE_ENDIAN)
        payload.put(guid, 0, 16)
        payload.put(nameUtf16)
        payload.putInt(CameraVendorConst.STANDARD_PTP_IP_PROTOCOL_VERSION)
        return PtpPacket(PtpPacketType.INIT_COMMAND_REQUEST, payload.array()).encode()
    }

    fun buildCameraVendorLegacyInitCommandRequest(
        friendlyName: String,
        clientIp: String? = null,
    ): ByteArray {
        val payload = ByteBuffer
            .allocate(4 + 4 + 16 + CameraVendorConst.INIT_DEVICE_NAME_BYTE_COUNT)
            .order(ByteOrder.LITTLE_ENDIAN)
        payload.putInt(PtpPacketType.INIT_COMMAND_REQUEST)
        payload.putInt(CameraVendorConst.CAMERA_VENDOR_LEGACY_PROTOCOL_VERSION.toInt())
        CameraVendorConst.INIT_GUID_BASE_WORDS.forEach { payload.putInt(it.toInt()) }
        payload.putInt(cameraWifiIpWord(clientIp).toInt())
        payload.put(rawUtf16LE(friendlyName, CameraVendorConst.INIT_DEVICE_NAME_BYTE_COUNT))

        return ByteBuffer.allocate(4 + payload.position())
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(4 + payload.position())
            .put(payload.array())
            .array()
    }

    fun buildInitEventRequest(connectionNumber: Int): ByteArray {
        val payload = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN)
        payload.putInt(connectionNumber)
        return PtpPacket(PtpPacketType.INIT_EVENT_REQUEST, payload.array()).encode()
    }

    fun buildOperationRequest(opCode: Int, transactionId: Int, params: List<Int> = emptyList()): ByteArray {
        val payloadSize = 4 + 2 + 4 + params.size * 4
        val payload = ByteBuffer.allocate(payloadSize).order(ByteOrder.LITTLE_ENDIAN)
        payload.putInt(1) // dataPhaseInfo: 1 = no data
        payload.putShort(opCode.toShort())
        payload.putInt(transactionId)
        for (p in params) payload.putInt(p)
        return PtpPacket(PtpPacketType.OPERATION_REQUEST, payload.array()).encode()
    }

    fun buildOperationRequest(
        opCode: Int,
        transactionId: Int,
        params: List<Int> = emptyList(),
        dataPhase: Int,
    ): ByteArray {
        val payloadSize = 4 + 2 + 4 + params.size * 4
        val payload = ByteBuffer.allocate(payloadSize).order(ByteOrder.LITTLE_ENDIAN)
        payload.putInt(dataPhase)
        payload.putShort(opCode.toShort())
        payload.putInt(transactionId)
        for (p in params) payload.putInt(p)
        return PtpPacket(PtpPacketType.OPERATION_REQUEST, payload.array()).encode()
    }

    fun buildCameraVendorLegacyOperationRequest(
        opCode: Int,
        transactionId: Int,
        params: List<Int> = emptyList(),
        dataPhase: Int = 1,
    ): ByteArray {
        val length = 4 + 2 + 2 + 4 + params.size * 4
        val data = ByteBuffer.allocate(length).order(ByteOrder.LITTLE_ENDIAN)
        data.putInt(length)
        data.putShort(dataPhase.toShort())
        data.putShort(opCode.toShort())
        data.putInt(transactionId)
        params.forEach { data.putInt(it) }
        return data.array()
    }

    fun buildCameraVendorLegacyDataOutRequest(
        opCode: Int,
        transactionId: Int,
        data: ByteArray,
    ): ByteArray {
        val length = 4 + 2 + 2 + 4 + data.size
        val packet = ByteBuffer.allocate(length).order(ByteOrder.LITTLE_ENDIAN)
        packet.putInt(length)
        packet.putShort(2)
        packet.putShort(opCode.toShort())
        packet.putInt(transactionId)
        packet.put(data)
        return packet.array()
    }

    fun buildEndDataPacket(transactionId: Int, data: ByteArray): ByteArray {
        val payload = ByteBuffer.allocate(4 + data.size).order(ByteOrder.LITTLE_ENDIAN)
        payload.putInt(transactionId)
        payload.put(data)
        return PtpPacket(PtpPacketType.END_DATA_PACKET, payload.array()).encode()
    }

    fun encodeUtf16LE(str: String): ByteArray {
        val chars = str.toCharArray()
        val buf = ByteBuffer.allocate((chars.size + 1) * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (c in chars) buf.putShort(c.code.toShort())
        buf.putShort(0) // null terminator
        return buf.array()
    }

    private fun rawUtf16LE(str: String, paddedTo: Int): ByteArray {
        val raw = str.toByteArray(Charsets.UTF_16LE) + byteArrayOf(0, 0)
        return when {
            raw.size == paddedTo -> raw
            raw.size > paddedTo -> raw.copyOf(paddedTo)
            else -> raw + ByteArray(paddedTo - raw.size)
        }
    }

    private fun cameraWifiIpWord(clientIp: String?): Long {
        val parts = clientIp?.split(".")?.mapNotNull { it.toIntOrNull() } ?: return 0
        if (parts.size != 4 || parts.any { it !in 0..255 }) return 0
        if (parts[0] != 192 || parts[1] != 168 || parts[2] != 0) return 0
        return ((parts[0].toLong() and 0xFF) shl 24) or
            ((parts[1].toLong() and 0xFF) shl 16) or
            ((parts[2].toLong() and 0xFF) shl 8) or
            (parts[3].toLong() and 0xFF)
    }
}

object CameraVendorLegacyPacketDecoder {
    fun decode(raw: ByteArray): PtpPacket {
        require(raw.size >= 6) { "Legacy packet too short: ${raw.size} bytes" }
        val length = ByteBuffer.wrap(raw, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
        require(length >= 6 && raw.size >= length) { "Invalid legacy packet length: $length" }
        val kind = ByteBuffer.wrap(raw, 4, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF
        val body = raw.copyOfRange(6, length)
        return when (kind) {
            2, 21 -> {
                require(body.size >= 6) { "Legacy data packet too short: ${body.size} bytes" }
                PtpPacket(PtpPacketType.DATA_PACKET, body.copyOfRange(6, body.size))
            }
            3 -> PtpPacket(PtpPacketType.OPERATION_RESPONSE, body)
            12 -> PtpPacket(
                PtpPacketType.OPERATION_RESPONSE,
                byteArrayOf(0x01, 0x20) + body.copyOfRange(2, minOf(body.size, 6)),
            )
            else -> PtpPacket(kind, body)
        }
    }
}
