package com.camtransfer.protocol

import com.camtransfer.model.ObjectInfo
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PtpCommands(private val connection: PtpConnection) {

    suspend fun getStorageIDs(): List<Int> {
        val data = connection.sendCommandGetData(PtpOpCode.GET_STORAGE_IDS)
        return parseUint32Array(data)
    }

    suspend fun getObjectHandles(
        storageId: Int,
        formatCode: Int = 0,
        parentHandle: Int = CameraVendorConst.ALL_HANDLES
    ): List<Int> {
        val data = connection.sendCommandGetData(
            PtpOpCode.GET_OBJECT_HANDLES, listOf(storageId, formatCode, parentHandle)
        )
        return parseUint32Array(data)
    }

    suspend fun getObjectInfo(handle: Int): ObjectInfo {
        val data = connection.sendCommandGetData(PtpOpCode.GET_OBJECT_INFO, listOf(handle))
        return parseObjectInfo(handle, data)
    }

    suspend fun getThumb(handle: Int): ByteArray {
        return connection.sendCommandGetData(PtpOpCode.GET_THUMB, listOf(handle))
    }

    suspend fun getObject(handle: Int): ByteArray {
        return connection.sendCommandGetData(PtpOpCode.GET_OBJECT, listOf(handle))
    }

    fun getObjectStream(handle: Int) =
        connection.sendCommandStreamData(PtpOpCode.GET_OBJECT, listOf(handle))

    suspend fun getPartialObject(handle: Int, offset: Int, maxBytes: Int): ByteArray {
        return connection.sendCommandGetData(
            PtpOpCode.GET_PARTIAL_OBJECT, listOf(handle, offset, maxBytes)
        )
    }

    private fun parseUint32Array(data: ByteArray): List<Int> {
        if (data.size < 4) return emptyList()
        val buf = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val count = buf.getInt()
        val result = mutableListOf<Int>()
        for (i in 0 until count) {
            if (4 + i * 4 + 4 > data.size) break
            result.add(ByteBuffer.wrap(data, 4 + i * 4, 4).order(ByteOrder.LITTLE_ENDIAN).getInt())
        }
        return result
    }

    private fun parseObjectInfo(handle: Int, data: ByteArray): ObjectInfo {
        val buf = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        var offset = 0

        val storageId = buf.getInt(offset); offset += 4
        val format = buf.getShort(offset).toInt() and 0xFFFF; offset += 2
        offset += 2 // protectionStatus
        val compressedSize = buf.getInt(offset); offset += 4
        val thumbFormat = buf.getShort(offset).toInt() and 0xFFFF; offset += 2
        val thumbCompressedSize = buf.getInt(offset); offset += 4
        val thumbPixWidth = buf.getInt(offset); offset += 4
        val thumbPixHeight = buf.getInt(offset); offset += 4
        val imagePixWidth = buf.getInt(offset); offset += 4
        val imagePixHeight = buf.getInt(offset); offset += 4
        offset += 4 // imageBitDepth
        val parentObject = buf.getInt(offset); offset += 4
        offset += 2 // associationType
        offset += 4 // associationDesc
        offset += 4 // sequenceNumber

        val filename = readPtpString(data, offset)
        offset += ptpStringByteLength(data, offset)
        val captureDate = readPtpString(data, offset)

        return ObjectInfo(
            handle = handle,
            storageId = storageId,
            format = format,
            compressedSize = compressedSize,
            thumbFormat = thumbFormat,
            thumbCompressedSize = thumbCompressedSize,
            thumbPixWidth = thumbPixWidth,
            thumbPixHeight = thumbPixHeight,
            imagePixWidth = imagePixWidth,
            imagePixHeight = imagePixHeight,
            parentObject = parentObject,
            filename = filename,
            captureDate = captureDate,
        )
    }

    private fun readPtpString(data: ByteArray, offset: Int): String {
        if (offset >= data.size) return ""
        val numChars = data[offset].toInt() and 0xFF
        if (numChars == 0) return ""
        var pos = offset + 1
        val buf = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        val chars = StringBuilder()
        for (i in 0 until numChars) {
            if (pos + 1 >= data.size) break
            val c = buf.getShort(pos).toInt() and 0xFFFF
            if (c == 0) break
            chars.append(c.toChar())
            pos += 2
        }
        return chars.toString()
    }

    private fun ptpStringByteLength(data: ByteArray, offset: Int): Int {
        if (offset >= data.size) return 1
        val numChars = data[offset].toInt() and 0xFF
        return 1 + numChars * 2
    }
}
