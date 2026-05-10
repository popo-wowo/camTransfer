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
        payload.putInt(CameraVendorConst.PROTOCOL_VERSION)
        return PtpPacket(PtpPacketType.INIT_COMMAND_REQUEST, payload.array()).encode()
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

    fun encodeUtf16LE(str: String): ByteArray {
        val chars = str.toCharArray()
        val buf = ByteBuffer.allocate((chars.size + 1) * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (c in chars) buf.putShort(c.code.toShort())
        buf.putShort(0) // null terminator
        return buf.array()
    }
}
