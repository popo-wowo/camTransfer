package com.camtransfer.ui

import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferState
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
