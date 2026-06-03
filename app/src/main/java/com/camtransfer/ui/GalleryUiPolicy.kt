package com.camtransfer.ui

import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferState
import java.nio.ByteOrder
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import kotlin.math.abs
import kotlin.math.hypot

sealed interface GalleryDateFilter {
    data object All : GalleryDateFilter
    data object Today : GalleryDateFilter
    data class SpecificDay(val day: LocalDate) : GalleryDateFilter
    data class Range(val start: LocalDate, val end: LocalDate) : GalleryDateFilter
}

sealed interface GalleryFormatFilter {
    data object Jpg : GalleryFormatFilter
    data object Heif : GalleryFormatFilter
    data object Raw : GalleryFormatFilter
    data object Video : GalleryFormatFilter
}

enum class GallerySortMode {
    NewestFirst,
    OldestFirst,
    NotDownloadedFirst,
}

data class GalleryFilterState(
    val date: GalleryDateFilter = GalleryDateFilter.All,
    val formats: Set<GalleryFormatFilter> = emptySet(),
)

object GalleryUiPolicy {
    fun filteredFiles(
        files: List<CameraFile>,
        state: GalleryFilterState,
        today: LocalDate,
    ): List<CameraFile> =
        files.filter { file ->
            matchesDate(file, state.date, today) && matchesFormat(file, state.formats)
        }

    fun captureDate(file: CameraFile): LocalDate? {
        val raw = file.info.captureDate
        if (raw.length < 8) return null
        return runCatching {
            LocalDate.parse(raw.take(8), DateTimeFormatter.BASIC_ISO_DATE)
        }.getOrNull()
    }

    private fun matchesDate(file: CameraFile, date: GalleryDateFilter, today: LocalDate): Boolean {
        val captureDay = captureDate(file) ?: return true
        return when (date) {
            GalleryDateFilter.All -> true
            GalleryDateFilter.Today -> captureDay == today
            is GalleryDateFilter.SpecificDay -> captureDay == date.day
            is GalleryDateFilter.Range -> {
                val start = minOf(date.start, date.end)
                val end = maxOf(date.start, date.end)
                captureDay in start..end
            }
        }
    }

    private fun matchesFormat(file: CameraFile, formats: Set<GalleryFormatFilter>): Boolean {
        if (formats.isEmpty()) return true
        return formats.any { format ->
            when (format) {
                GalleryFormatFilter.Jpg -> file.info.isJpeg
                GalleryFormatFilter.Heif -> file.info.isHeif
                GalleryFormatFilter.Raw -> file.info.isRaw
                GalleryFormatFilter.Video -> file.info.isVideo
            }
        }
    }
}

object GallerySortPolicy {
    fun sortedFiles(
        files: List<CameraFile>,
        mode: GallerySortMode,
        downloadStates: Map<Int, TransferState?>,
    ): List<CameraFile> =
        when (mode) {
            GallerySortMode.NewestFirst -> files.sortedWith(newestFirstComparator())
            GallerySortMode.OldestFirst -> files.sortedWith(oldestFirstComparator())
            GallerySortMode.NotDownloadedFirst -> files.sortedWith(
                compareBy<CameraFile> { file ->
                    if (GalleryDownloadUiPolicy.canSelect(downloadStates[file.info.handle])) 0 else 1
                }.then(newestFirstComparator())
            )
        }

    private fun newestFirstComparator(): Comparator<CameraFile> =
        compareByDescending<CameraFile> { it.info.captureDate }
            .thenByDescending { it.info.handle }

    private fun oldestFirstComparator(): Comparator<CameraFile> =
        compareBy<CameraFile> { it.info.captureDate }
            .thenBy { it.info.handle }
}

object GalleryScrollResetPolicy {
    fun shouldScrollToTopAfterFilterOrSortChange(): Boolean = true
}

object GalleryFilterPanelPolicy {
    private val shortDateFormatter = DateTimeFormatter.ofPattern("MM-dd")

    fun defaultExpanded(): Boolean = false

    fun summary(state: GalleryFilterState, sortMode: GallerySortMode): String =
        listOf(
            dateLabel(state.date),
            formatLabel(state.formats),
            sortLabel(sortMode),
        ).joinToString(" · ")

    private fun dateLabel(date: GalleryDateFilter): String =
        when (date) {
            GalleryDateFilter.All -> "全部日期"
            GalleryDateFilter.Today -> "今天"
            is GalleryDateFilter.SpecificDay -> date.day.format(shortDateFormatter)
            is GalleryDateFilter.Range -> {
                val start = minOf(date.start, date.end).format(shortDateFormatter)
                val end = maxOf(date.start, date.end).format(shortDateFormatter)
                "$start~$end"
            }
        }

    private fun formatLabel(formats: Set<GalleryFormatFilter>): String {
        if (formats.isEmpty()) return "全部格式"
        val ordered = listOf(
            GalleryFormatFilter.Jpg to "JPG",
            GalleryFormatFilter.Heif to "HEIF",
            GalleryFormatFilter.Raw to "RAW",
            GalleryFormatFilter.Video to "视频",
        )
        return ordered.filter { it.first in formats }.joinToString("/") { it.second }
    }

    private fun sortLabel(sortMode: GallerySortMode): String =
        when (sortMode) {
            GallerySortMode.NewestFirst -> "最新优先"
            GallerySortMode.OldestFirst -> "最早优先"
            GallerySortMode.NotDownloadedFirst -> "未下载优先"
        }
}

object GalleryDownloadUiPolicy {
    fun canSelect(state: TransferState?): Boolean =
        when (state) {
            null, TransferState.ERROR -> true
            TransferState.PENDING,
            TransferState.DOWNLOADING,
            TransferState.SAVING,
            TransferState.DONE -> false
        }
}

object GalleryDisconnectPolicy {
    const val confirmTitle = "确认断开相机连接？"
    const val confirmMessage = "当前会保持在照片筛选页面，并且不会断开相机通讯。只有确认断开后，才会返回首页并断开相机连接。"

    fun shouldConfirmBeforeDisconnect(): Boolean = true
}

object GalleryDragSelectionPolicy {
    fun shouldSelectForDrag(startHandleSelected: Boolean): Boolean = !startHandleSelected

    fun shouldStartDragSelection(deltaX: Float, deltaY: Float, touchSlop: Float): Boolean {
        val distance = hypot(deltaX.toDouble(), deltaY.toDouble()).toFloat()
        if (distance < touchSlop) return false
        return abs(deltaX) >= abs(deltaY) * 0.55f
    }

    fun updatedSelection(
        currentSelection: Set<Int>,
        handle: Int,
        downloadState: TransferState?,
        shouldSelect: Boolean,
    ): Set<Int> {
        if (!GalleryDownloadUiPolicy.canSelect(downloadState)) return currentSelection
        return if (shouldSelect) {
            currentSelection + handle
        } else {
            currentSelection - handle
        }
    }
}

object GalleryColumnLayoutPolicy {
    const val MIN_COLUMNS = 2
    const val MAX_COLUMNS = 5
    const val DEFAULT_COLUMNS = 3
    private const val ZOOM_IN_THRESHOLD = 1.45f
    private const val ZOOM_OUT_THRESHOLD = 0.7f

    fun targetColumns(currentColumns: Int, pinchScale: Float): Int {
        val normalized = currentColumns.coerceIn(MIN_COLUMNS, MAX_COLUMNS)
        return when {
            pinchScale > ZOOM_IN_THRESHOLD -> (normalized - 1).coerceAtLeast(MIN_COLUMNS)
            pinchScale < ZOOM_OUT_THRESHOLD -> (normalized + 1).coerceAtMost(MAX_COLUMNS)
            else -> normalized
        }
    }
}

object GalleryPreviewNavigationPolicy {
    fun initialPage(files: List<CameraFile>, selectedHandle: Int): Int {
        val index = files.indexOfFirst { it.info.handle == selectedHandle }
        return index.coerceAtLeast(0)
    }
}

object GalleryPreviewRotationPolicy {
    fun nextManualRotationDegrees(currentDegrees: Int): Int =
        normalizedDegrees(currentDegrees + 90)

    fun autoRotationDegrees(
        file: CameraFile,
        decodedWidth: Int,
        decodedHeight: Int,
        imageData: ByteArray?,
    ): Int {
        exifRotationDegrees(imageData)?.let { return it }
        if (decodedWidth <= 0 || decodedHeight <= 0) return 0
        val expectedWidth = firstPositive(file.info.imagePixWidth, file.info.thumbPixWidth)
        val expectedHeight = firstPositive(file.info.imagePixHeight, file.info.thumbPixHeight)
        if (expectedWidth <= 0 || expectedHeight <= 0) return 0
        val expectedPortrait = expectedHeight > expectedWidth
        val decodedPortrait = decodedHeight > decodedWidth
        return if (expectedPortrait != decodedPortrait) 90 else 0
    }

    fun exifRotationDegrees(data: ByteArray?): Int? {
        if (data == null || data.size < 12) return null
        if (data[0].unsigned() != 0xFF || data[1].unsigned() != 0xD8) return null
        var offset = 2
        while (offset + 4 <= data.size) {
            if (data[offset].unsigned() != 0xFF) return null
            val marker = data[offset + 1].unsigned()
            if (marker == 0xDA || marker == 0xD9) return null
            val segmentLength = data.uint16BE(offset + 2)
            if (segmentLength < 2) return null
            val segmentStart = offset + 4
            val segmentEnd = offset + 2 + segmentLength
            if (segmentEnd > data.size) return null
            if (marker == 0xE1 && hasExifHeader(data, segmentStart)) {
                return tiffOrientation(data, segmentStart + EXIF_HEADER.size, segmentEnd)
                    ?.let(::rotationForExifOrientation)
            }
            offset = segmentEnd
        }
        return null
    }

    private fun tiffOrientation(data: ByteArray, tiffStart: Int, end: Int): Int? {
        if (tiffStart + 8 > end) return null
        val byteOrder = when {
            data[tiffStart].toInt().toChar() == 'I' && data[tiffStart + 1].toInt().toChar() == 'I' ->
                ByteOrder.LITTLE_ENDIAN
            data[tiffStart].toInt().toChar() == 'M' && data[tiffStart + 1].toInt().toChar() == 'M' ->
                ByteOrder.BIG_ENDIAN
            else -> return null
        }
        if (data.uint16(tiffStart + 2, byteOrder) != 42) return null
        val ifdOffset = data.uint32(tiffStart + 4, byteOrder)
        val ifdStart = tiffStart + ifdOffset
        if (ifdOffset < 8 || ifdStart + 2 > end) return null
        val entryCount = data.uint16(ifdStart, byteOrder)
        var entryOffset = ifdStart + 2
        repeat(entryCount) {
            if (entryOffset + 12 > end) return null
            val tag = data.uint16(entryOffset, byteOrder)
            val type = data.uint16(entryOffset + 2, byteOrder)
            val count = data.uint32(entryOffset + 4, byteOrder)
            if (tag == ORIENTATION_TAG && type == SHORT_TYPE && count == 1) {
                return data.uint16(entryOffset + 8, byteOrder)
            }
            entryOffset += 12
        }
        return null
    }

    private fun rotationForExifOrientation(orientation: Int): Int? =
        when (orientation) {
            3, 4 -> 180
            5, 6 -> 90
            7, 8 -> 270
            else -> null
        }

    private fun normalizedDegrees(degrees: Int): Int =
        ((degrees % 360) + 360) % 360

    private fun firstPositive(first: Int, second: Int): Int =
        if (first > 0) first else second

    private fun hasExifHeader(data: ByteArray, offset: Int): Boolean {
        if (offset + EXIF_HEADER.size > data.size) return false
        return EXIF_HEADER.indices.all { data[offset + it] == EXIF_HEADER[it] }
    }

    private fun ByteArray.uint16BE(offset: Int): Int =
        (this[offset].unsigned() shl 8) or this[offset + 1].unsigned()

    private fun ByteArray.uint16(offset: Int, byteOrder: ByteOrder): Int =
        if (byteOrder == ByteOrder.LITTLE_ENDIAN) {
            this[offset].unsigned() or (this[offset + 1].unsigned() shl 8)
        } else {
            (this[offset].unsigned() shl 8) or this[offset + 1].unsigned()
        }

    private fun ByteArray.uint32(offset: Int, byteOrder: ByteOrder): Int {
        val value = if (byteOrder == ByteOrder.LITTLE_ENDIAN) {
            this[offset].unsigned() or
                (this[offset + 1].unsigned() shl 8) or
                (this[offset + 2].unsigned() shl 16) or
                (this[offset + 3].unsigned() shl 24)
        } else {
            (this[offset].unsigned() shl 24) or
                (this[offset + 1].unsigned() shl 16) or
                (this[offset + 2].unsigned() shl 8) or
                this[offset + 3].unsigned()
        }
        return value.takeIf { it >= 0 } ?: return Int.MAX_VALUE
    }

    private fun Byte.unsigned(): Int = toInt() and 0xFF

    private val EXIF_HEADER = byteArrayOf(0x45, 0x78, 0x69, 0x66, 0, 0)
    private const val ORIENTATION_TAG = 0x0112
    private const val SHORT_TYPE = 3
}
