package com.camtransfer.protocol

import com.camtransfer.model.ObjectInfo
import java.nio.ByteBuffer
import java.nio.ByteOrder

object CameraVendorPtpDataParser {
    fun emptySearchModeAllPayload(): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(0).array()

    fun officialObjectFormatSearchModeAllPayload(formatMask: Int): ByteArray {
        require(formatMask in 0..0xFFFF) { "Format mask must fit in UInt16: $formatMask" }
        return ByteBuffer.allocate(12)
            .order(ByteOrder.LITTLE_ENDIAN)
            .putInt(1)
            .putInt(8)
            .putShort(CameraVendorSearchMode.OBJECT_FORMAT_PROPERTY.toShort())
            .putShort(formatMask.toShort())
            .array()
    }

    fun searchModeSnapshot(data: ByteArray): String {
        val exact = parseSearchModes(data)
        if (exact.isNotEmpty()) return exact.joinToString(prefix = "[", postfix = "]") {
            "0x%04X/type=%d/value=%d/layout=%s".format(
                it.propertyCode,
                it.dataType,
                it.value.toLong() and 0xFFFFFFFFL,
                it.layout,
            )
        }
        val d604Offsets = mutableListOf<String>()
        for (offset in 0..data.size - 2) {
            if (uint16(data, offset) == CameraVendorSearchMode.OBJECT_FORMAT_PROPERTY) {
                val nearby = data.copyOfRange(offset, (offset + 20).coerceAtMost(data.size)).joinToString("") {
                    "%02x".format(it)
                }
                d604Offsets += "$offset:$nearby"
            }
        }
        return if (d604Offsets.isEmpty()) "[]" else "d604Offsets=${d604Offsets.joinToString("|")}"
    }

    fun searchModeWithObjectFormat(data: ByteArray, formatMask: Int): ByteArray? {
        val entry = parseSearchModes(data)
            .firstOrNull { it.propertyCode == CameraVendorSearchMode.OBJECT_FORMAT_PROPERTY }
            ?: return null
        val copy = data.copyOf()
        writeSearchModeValue(copy, entry.valueOffset, entry.valueByteCount, formatMask)
        return copy
    }

    private fun parseSearchModes(data: ByteArray): List<SearchModeEntry> {
        if (data.size < 4) return emptyList()
        val count = uint32(data, 0)
        if (count !in 0..32) return emptyList()
        return parseSizedSearchModes(data, count).ifEmpty {
            parseSearchModesWithStride(
            data = data,
            count = count,
            stride = 8,
            layout = "valueFirst8",
            dataTypeOffset = 6,
            propertyCodeOffset = 4,
            valueOffset = 0,
            allowZeroDataType = true,
            valueByteCount = 4,
            )
        }.ifEmpty {
            parseSearchModesWithStride(
                data = data,
                count = count,
                stride = 18,
                layout = "native18",
                dataTypeOffset = 0,
                propertyCodeOffset = 2,
                valueOffset = 4,
                allowZeroDataType = false,
                valueByteCount = 4,
            )
        }.ifEmpty {
            parseSearchModesWithStride(
                data = data,
                count = count,
                stride = 18,
                layout = "native18-swapped",
                dataTypeOffset = 2,
                propertyCodeOffset = 0,
                valueOffset = 4,
                allowZeroDataType = false,
                valueByteCount = 4,
            )
        }.ifEmpty {
            parseSearchModesWithStride(
                data = data,
                count = count,
                stride = 8,
                layout = "legacy8",
                dataTypeOffset = 2,
                propertyCodeOffset = 0,
                valueOffset = 4,
                allowZeroDataType = false,
                valueByteCount = 4,
            )
        }.ifEmpty {
            parseSearchModesByPropertyScan(data, count)
        }
    }

    private fun parseSizedSearchModes(data: ByteArray, count: Int): List<SearchModeEntry> {
        if (count == 0) return emptyList()
        val result = mutableListOf<SearchModeEntry>()
        var offset = 4
        repeat(count) {
            if (offset + 6 > data.size) return emptyList()
            val recordLength = uint32(data, offset)
            if (recordLength < 6 || offset + recordLength > data.size) return emptyList()
            val propertyCode = uint16(data, offset + 4)
            if (!isPlausibleSearchModeProperty(propertyCode)) return emptyList()
            val valueOffset = offset + 6
            val valueByteCount = recordLength - 6
            val value = uintSizedOrZero(data, valueOffset, valueByteCount)
            result += SearchModeEntry(
                propertyCode = propertyCode,
                dataType = sizedSearchModeDataType(propertyCode, valueByteCount),
                value = value,
                valueOffset = valueOffset,
                valueByteCount = valueByteCount,
                layout = "sized",
            )
            offset += recordLength
        }
        return result.takeIf { offset == data.size }.orEmpty()
    }

    private fun parseSearchModesByPropertyScan(data: ByteArray, count: Int): List<SearchModeEntry> {
        if (count == 0) return emptyList()
        val result = mutableListOf<SearchModeEntry>()
        for (propertyOffset in 4..data.size - 4) {
            val propertyCode = uint16(data, propertyOffset)
            if (!isPlausibleSearchModeProperty(propertyCode)) continue
            val valueOffset = propertyOffset - 4
            if (valueOffset < 4) continue
            val dataType = uint16(data, propertyOffset + 2)
            if (!isPlausibleSearchModeDataType(dataType, allowZero = true)) continue
            val value = uint32(data, valueOffset)
            if (!isPlausibleSearchModeValue(value)) continue
            result += SearchModeEntry(
                propertyCode = propertyCode,
                dataType = dataType,
                value = value,
                valueOffset = valueOffset,
                valueByteCount = 4,
                layout = "propertyScan",
            )
        }
        return result.takeIf { it.size == count }.orEmpty()
    }

    private fun parseSearchModesWithStride(
        data: ByteArray,
        count: Int,
        stride: Int,
        layout: String,
        dataTypeOffset: Int,
        propertyCodeOffset: Int,
        valueOffset: Int,
        allowZeroDataType: Boolean,
        valueByteCount: Int,
    ): List<SearchModeEntry> {
        if (count == 0) return emptyList()
        if (data.size < 4 + count * stride) return emptyList()
        val result = mutableListOf<SearchModeEntry>()
        var offset = 4
        repeat(count) {
            val propertyCode = uint16(data, offset + propertyCodeOffset)
            val dataType = uint16(data, offset + dataTypeOffset)
            val value = uint32(data, offset + valueOffset)
            if (
                !isPlausibleSearchModeProperty(propertyCode) ||
                !isPlausibleSearchModeDataType(dataType, allowZeroDataType)
            ) {
                return emptyList()
            }
            result += SearchModeEntry(
                propertyCode = propertyCode,
                dataType = dataType,
                value = value,
                valueOffset = offset + valueOffset,
                valueByteCount = valueByteCount,
                layout = layout,
            )
            offset += stride
        }
        return result
    }

    private fun sizedSearchModeDataType(propertyCode: Int, valueByteCount: Int): Int =
        when {
            propertyCode == 0xD601 || propertyCode == 0xD602 -> 0xFFFF
            valueByteCount == 4 -> 6
            else -> 4
        }

    private fun isPlausibleSearchModeProperty(value: Int): Boolean =
        value in 0xD600..0xD6FF

    private fun isPlausibleSearchModeDataType(value: Int, allowZero: Boolean): Boolean =
        value in 1..4 || (allowZero && value == 0)

    private fun isPlausibleSearchModeValue(value: Int): Boolean =
        value in 0..0xFFFF

    private data class SearchModeEntry(
        val propertyCode: Int,
        val dataType: Int,
        val value: Int,
        val valueOffset: Int,
        val valueByteCount: Int,
        val layout: String,
    )

    fun objectCountsByDate(data: ByteArray): List<CameraVendorObjectCountByDate> {
        if (data.isEmpty()) return emptyList()
        return parseCountPrefixedSizedPtpStringDateCounts(data)
            .ifEmpty { parseCountPrefixedPtpStringDateCounts(data) }
            .ifEmpty { parseCountPrefixedAsciiDateCounts(data) }
    }

    fun uint32Array(data: ByteArray): List<Int> {
        if (data.size < 4) return emptyList()
        val count = uint32(data, 0)
        val result = mutableListOf<Int>()
        for (i in 0 until count) {
            val offset = 4 + i * 4
            if (offset + 4 > data.size) break
            result.add(uint32(data, offset))
        }
        return result
    }

    fun objectInfo(handle: Int, data: ByteArray): ObjectInfo {
        val storageId = uint32OrZero(data, 0)
        val format = uint16OrZero(data, 4)
        val compressedSize = uint32OrZero(data, 8)
        val thumbFormat = uint16OrZero(data, 12)
        val thumbCompressedSize = uint32OrZero(data, 14)
        val thumbPixWidth = uint32OrZero(data, 18)
        val thumbPixHeight = uint32OrZero(data, 22)
        val imagePixWidth = uint32OrZero(data, 26)
        val imagePixHeight = uint32OrZero(data, 30)
        val parentObject = uint32OrZero(data, 38)
        val filenameOffset = 52
        val filename = ptpString(data, filenameOffset)
        val captureDateOffset = filenameOffset + ptpStringByteLength(data, filenameOffset)
        val captureDate = ptpString(data, captureDateOffset)
        val metadataOffset = captureDateOffset + ptpStringByteLength(data, captureDateOffset)
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
            filename = filename.ifBlank { "0x%08X.JPG".format(handle) },
            captureDate = captureDate,
            orientation = cameraVendorOrientation(data, metadataOffset),
        )
    }

    fun cameraVendorObjectInfo(handle: Int, data: ByteArray): ObjectInfo {
        val info = objectInfo(handle, data)
        val filenameOffset = 54
        val filename = ptpString(data, filenameOffset)
        val captureDateOffset = filenameOffset + ptpStringByteLength(data, filenameOffset)
        val captureDate = ptpString(data, captureDateOffset)
        val orientationOffset = captureDateOffset + ptpStringByteLength(data, captureDateOffset)
        return info.copy(
            filename = filename.ifBlank { info.filename },
            captureDate = captureDate.ifBlank { info.captureDate },
            orientation = cameraVendorOrientation(data, orientationOffset) ?: info.orientation,
        )
    }

    fun imageData(data: ByteArray): ByteArray {
        val jpeg = jpegData(data)
        if (jpeg.size != data.size || (jpeg.size >= 2 && jpeg[0] == 0xFF.toByte() && jpeg[1] == 0xD8.toByte())) {
            return jpeg
        }
        return heifData(data)
    }

    fun isLikelyImageData(data: ByteArray): Boolean {
        if (data.size >= 2 && data[0] == 0xFF.toByte() && data[1] == 0xD8.toByte()) return true
        if (data.size < 12) return false
        val brands = setOf("heic", "heix", "hevc", "hevx", "heis", "hevm", "heif", "mif1", "msf1")
        for (i in 4..data.size - 8) {
            if (data[i] == 'f'.code.toByte() &&
                data[i + 1] == 't'.code.toByte() &&
                data[i + 2] == 'y'.code.toByte() &&
                data[i + 3] == 'p'.code.toByte()
            ) {
                val brand = data.copyOfRange(i + 4, i + 8).toString(Charsets.US_ASCII)
                if (brand in brands) return true
            }
        }
        return false
    }

    private fun jpegData(data: ByteArray): ByteArray {
        if (data.size < 2) return data
        if (data[0] == 0xFF.toByte() && data[1] == 0xD8.toByte()) return data
        for (i in 0 until data.size - 1) {
            if (data[i] == 0xFF.toByte() && data[i + 1] == 0xD8.toByte()) {
                return data.copyOfRange(i, data.size)
            }
        }
        return data
    }

    private fun heifData(data: ByteArray): ByteArray {
        if (data.size < 12) return data
        val brands = setOf("heic", "heix", "hevc", "hevx", "heis", "hevm", "heif", "mif1", "msf1")
        for (i in 4..data.size - 8) {
            if (data[i] == 'f'.code.toByte() &&
                data[i + 1] == 't'.code.toByte() &&
                data[i + 2] == 'y'.code.toByte() &&
                data[i + 3] == 'p'.code.toByte()
            ) {
                val brand = data.copyOfRange(i + 4, i + 8).toString(Charsets.US_ASCII)
                if (brand in brands) {
                    return data.copyOfRange(i - 4, data.size)
                }
            }
        }
        return data
    }

    private fun ptpString(data: ByteArray, offset: Int): String {
        if (offset >= data.size) return ""
        val numChars = data[offset].toInt() and 0xFF
        if (numChars == 0) return ""
        val chars = StringBuilder()
        var pos = offset + 1
        for (i in 0 until numChars) {
            if (pos + 1 >= data.size) break
            val c = uint16(data, pos)
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

    private fun cameraVendorOrientation(data: ByteArray, offset: Int): Int? {
        var currentOffset = offset
        repeat(12) {
            if (currentOffset >= data.size) return null
            val value = ptpString(data, currentOffset)
            orientationFromMetadataString(value)?.let { return it }
            val length = ptpStringByteLength(data, currentOffset)
            currentOffset += length.coerceAtLeast(1)
        }
        return null
    }

    private fun orientationFromMetadataString(value: String): Int? {
        val match = Regex("""(?i)\borientation\s*:\s*([1-8])\b""").find(value) ?: return null
        return when (match.groupValues[1].toIntOrNull()) {
            1, 2 -> 1
            6, 7 -> 2
            3, 4 -> 3
            5, 8 -> 4
            else -> null
        }
    }

    private fun uint16OrZero(data: ByteArray, offset: Int): Int =
        if (offset + 2 <= data.size) uint16(data, offset) else 0

    private fun uint32OrZero(data: ByteArray, offset: Int): Int =
        if (offset + 4 <= data.size) uint32(data, offset) else 0

    private fun uint16(data: ByteArray, offset: Int): Int =
        ByteBuffer.wrap(data, offset, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF

    private fun uint32(data: ByteArray, offset: Int): Int =
        ByteBuffer.wrap(data, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int

    private fun uintSizedOrZero(data: ByteArray, offset: Int, byteCount: Int): Int {
        if (byteCount <= 0 || offset >= data.size) return 0
        var value = 0
        val count = byteCount.coerceAtMost(4).coerceAtMost(data.size - offset)
        for (index in 0 until count) {
            value = value or ((data[offset + index].toInt() and 0xFF) shl (index * 8))
        }
        return value
    }

    private fun writeSearchModeValue(data: ByteArray, offset: Int, byteCount: Int, value: Int) {
        require(byteCount in 1..4) { "Unsupported search mode value width: $byteCount" }
        require(offset + byteCount <= data.size) { "Search mode value offset out of bounds" }
        for (index in 0 until byteCount) {
            data[offset + index] = ((value ushr (index * 8)) and 0xFF).toByte()
        }
    }

    private fun writeUInt32(data: ByteArray, offset: Int, value: Int) {
        ByteBuffer.wrap(data, offset, 4).order(ByteOrder.LITTLE_ENDIAN).putInt(value)
    }

    private fun parseCountPrefixedPtpStringDateCounts(data: ByteArray): List<CameraVendorObjectCountByDate> {
        if (data.size < 4) return emptyList()
        val count = uint32(data, 0)
        if (!isPlausibleDateGroupCount(count)) return emptyList()
        val result = mutableListOf<CameraVendorObjectCountByDate>()
        var offset = 4
        repeat(count) {
            val rawDate = ptpString(data, offset)
            val normalizedDate = normalizedDateValue(rawDate) ?: return emptyList()
            offset += ptpStringByteLength(data, offset)
            if (offset + 4 > data.size) return emptyList()
            val numberOfImages = uint32(data, offset)
            if (!isPlausibleImageCount(numberOfImages)) return emptyList()
            offset += 4
            result += CameraVendorObjectCountByDate(normalizedDate, numberOfImages)
        }
        return result
    }

    private fun parseCountPrefixedSizedPtpStringDateCounts(data: ByteArray): List<CameraVendorObjectCountByDate> {
        if (data.size < 8) return emptyList()
        val count = uint32(data, 0)
        if (!isPlausibleDateGroupCount(count)) return emptyList()
        val result = mutableListOf<CameraVendorObjectCountByDate>()
        var offset = 4
        repeat(count) {
            if (offset + 4 > data.size) return emptyList()
            val recordLength = uint32(data, offset)
            if (recordLength < 9 || offset + recordLength > data.size) return emptyList()
            val recordEnd = offset + recordLength
            val dateOffset = offset + 4
            val rawDate = ptpString(data, dateOffset)
            val normalizedDate = normalizedDateValue(rawDate) ?: return emptyList()
            val countOffset = dateOffset + ptpStringByteLength(data, dateOffset)
            if (countOffset + 4 > recordEnd) return emptyList()
            val numberOfImages = uint32(data, countOffset)
            if (!isPlausibleImageCount(numberOfImages)) return emptyList()
            result += CameraVendorObjectCountByDate(normalizedDate, numberOfImages)
            offset = recordEnd
        }
        return result
    }

    private fun parseCountPrefixedAsciiDateCounts(data: ByteArray): List<CameraVendorObjectCountByDate> {
        if (data.size < 4) return emptyList()
        val count = uint32(data, 0)
        if (!isPlausibleDateGroupCount(count)) return emptyList()
        val expectedSize = 4 + count * 12
        if (data.size < expectedSize) return emptyList()
        val result = mutableListOf<CameraVendorObjectCountByDate>()
        var offset = 4
        repeat(count) {
            val rawDate = data.copyOfRange(offset, offset + 8).toString(Charsets.US_ASCII)
            val normalizedDate = normalizedDateValue(rawDate) ?: return emptyList()
            offset += 8
            val numberOfImages = uint32(data, offset)
            if (!isPlausibleImageCount(numberOfImages)) return emptyList()
            offset += 4
            result += CameraVendorObjectCountByDate(normalizedDate, numberOfImages)
        }
        return result
    }

    private fun normalizedDateValue(value: String): String? {
        val digits = value.filter(Char::isDigit)
        if (digits.length < 8) return null
        val date = digits.take(8)
        val month = date.substring(4, 6).toIntOrNull() ?: return null
        val day = date.substring(6, 8).toIntOrNull() ?: return null
        if (month !in 1..12 || day !in 1..31) return null
        return date
    }

    private fun isPlausibleDateGroupCount(count: Int): Boolean =
        count in 1..10_000

    private fun isPlausibleImageCount(count: Int): Boolean =
        count in 1..100_000
}

data class CameraVendorObjectCountByDate(
    val dateValue: String,
    val numberOfImages: Int,
)
