package com.camtransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

class PtpBuffer {
    private val chunks = mutableListOf<ByteArray>()
    private var totalLength = 0

    val length: Int get() = totalLength

    fun add(chunk: ByteArray) {
        chunks.add(chunk)
        totalLength += chunk.size
    }

    fun clear() {
        chunks.clear()
        totalLength = 0
    }

    private fun flatten(): ByteArray {
        if (chunks.size == 1) return chunks.first()
        val result = ByteArray(totalLength)
        var offset = 0
        for (chunk in chunks) {
            chunk.copyInto(result, offset)
            offset += chunk.size
        }
        return result
    }

    fun drain(): List<PtpPacket> {
        val packets = mutableListOf<PtpPacket>()
        if (totalLength < 8) return packets

        var bytes = flatten()
        while (bytes.size >= 8) {
            val packetLen = ByteBuffer.wrap(bytes, 0, 4).order(ByteOrder.LITTLE_ENDIAN).getInt()
            if (packetLen < 8 || bytes.size < packetLen) break
            packets.add(PtpPacket.decode(bytes.copyOfRange(0, packetLen)))
            bytes = bytes.copyOfRange(packetLen, bytes.size)
        }

        clear()
        if (bytes.isNotEmpty()) add(bytes)

        return packets
    }
}
