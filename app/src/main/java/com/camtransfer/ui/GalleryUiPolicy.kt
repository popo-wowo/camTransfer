package com.camtransfer.ui

import com.camtransfer.model.CameraFile
import com.camtransfer.model.CameraFileFormatHint
import com.camtransfer.model.TransferState
import com.camtransfer.protocol.PtpObjectFormat
import java.nio.ByteOrder
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

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
    val folders: Set<GalleryFolderFilter> = emptySet(),
)

data class GalleryFolderFilter(
    val storageId: Int,
    val parentObject: Int,
)

data class GalleryFolderCount(
    val folder: GalleryFolderFilter,
    val label: String,
    val count: Int,
)

data class GalleryFilterStats(
    val totalCount: Int,
    val folderCounts: List<GalleryFolderCount>,
    val formatCounts: Map<GalleryFormatFilter, Int>,
)

data class GalleryDaySection(
    val day: LocalDate?,
    val files: List<CameraFile>,
    val hourGroups: List<GalleryHourGroup> = emptyList(),
)

data class GalleryHourGroup(
    val hour: Int,
    val files: List<CameraFile>,
)

object GalleryUiPolicy {
    fun filteredFiles(
        files: List<CameraFile>,
        state: GalleryFilterState,
        today: LocalDate,
    ): List<CameraFile> =
        files.filter { file ->
            matchesDate(file, state.date, today) &&
                matchesFormat(file, state.formats) &&
                matchesFolder(file, state.folders)
        }

    fun captureDate(file: CameraFile): LocalDate? {
        val raw = file.info.captureDate
        if (raw.length < 8) return null
        return runCatching {
            LocalDate.parse(raw.take(8), DateTimeFormatter.BASIC_ISO_DATE)
        }.getOrNull()
    }

    private fun matchesDate(file: CameraFile, date: GalleryDateFilter, today: LocalDate): Boolean {
        val captureDay = captureDate(file) ?: return date == GalleryDateFilter.All
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
            if (file.info.format != PtpObjectFormat.UNDEFINED) {
                matchesResolvedFormat(file, format)
            } else {
                matchesFormatHint(file, format)
            }
        }
    }

    private fun matchesResolvedFormat(file: CameraFile, format: GalleryFormatFilter): Boolean =
        when (format) {
            GalleryFormatFilter.Jpg -> file.info.isJpeg
            GalleryFormatFilter.Heif -> file.info.isHeif
            GalleryFormatFilter.Raw -> file.info.isRaw
            GalleryFormatFilter.Video -> file.info.isVideo
        }

    private fun matchesFormatHint(file: CameraFile, format: GalleryFormatFilter): Boolean =
        when (format) {
            GalleryFormatFilter.Jpg -> CameraFileFormatHint.JPG in file.formatHints
            GalleryFormatFilter.Heif -> CameraFileFormatHint.HEIF in file.formatHints ||
                CameraFileFormatHint.EXTENDED_STILL_CANDIDATE in file.formatHints
            GalleryFormatFilter.Raw -> CameraFileFormatHint.RAW in file.formatHints ||
                CameraFileFormatHint.EXTENDED_STILL_CANDIDATE in file.formatHints
            GalleryFormatFilter.Video -> CameraFileFormatHint.VIDEO in file.formatHints
        }

    fun formatMatches(file: CameraFile, format: GalleryFormatFilter): Boolean =
        if (file.info.format != PtpObjectFormat.UNDEFINED) {
            matchesResolvedFormat(file, format)
        } else {
            matchesFormatHint(file, format)
        }

    private fun matchesFolder(file: CameraFile, folders: Set<GalleryFolderFilter>): Boolean {
        if (folders.isEmpty()) return true
        return folderFilter(file) in folders
    }

    fun folderFilter(file: CameraFile): GalleryFolderFilter =
        GalleryFolderFilter(
            storageId = file.info.storageId,
            parentObject = file.info.parentObject,
        )
}

object GalleryFilterStatsPolicy {
    fun stats(files: List<CameraFile>): GalleryFilterStats =
        GalleryFilterStats(
            totalCount = files.size,
            folderCounts = files
                .groupBy(GalleryUiPolicy::folderFilter)
                .map { (folder, folderFiles) ->
                    GalleryFolderCount(
                        folder = folder,
                        label = folderLabel(folder),
                        count = folderFiles.size,
                    )
                }
                .sortedWith(compareByDescending<GalleryFolderCount> { it.count }.thenBy { it.label }),
            formatCounts = localFormatCounts(files),
        )

    fun folderLabel(folder: GalleryFolderFilter): String =
        if (folder.parentObject > 0) {
            "文件夹 ${folder.parentObject}"
        } else {
            "存储卡 ${folder.storageId}"
        }

    private fun localFormatCounts(files: List<CameraFile>): Map<GalleryFormatFilter, Int> =
        mapOf(
            GalleryFormatFilter.Jpg to files.count { GalleryUiPolicy.formatMatches(it, GalleryFormatFilter.Jpg) },
            GalleryFormatFilter.Heif to files.count { GalleryUiPolicy.formatMatches(it, GalleryFormatFilter.Heif) },
            GalleryFormatFilter.Raw to files.count { GalleryUiPolicy.formatMatches(it, GalleryFormatFilter.Raw) },
            GalleryFormatFilter.Video to files.count { GalleryUiPolicy.formatMatches(it, GalleryFormatFilter.Video) },
        )
}

object GalleryTransferModeUiPolicy {
    fun canChangeTransferMode(isTransferring: Boolean): Boolean = !isTransferring
}

object GallerySectionPolicy {
    fun shouldShowDateSections(files: List<CameraFile>): Boolean =
        files.any { GalleryUiPolicy.captureDate(it) != null }

    fun sections(
        files: List<CameraFile>,
        expandedDays: Set<LocalDate>,
    ): List<GalleryDaySection> {
        val filesByDay = files.groupBy { GalleryUiPolicy.captureDate(it) }
        val orderedDays = files
            .mapNotNull { GalleryUiPolicy.captureDate(it) }
            .distinct()
        val unknownFiles = filesByDay[null].orEmpty()
        val sections = orderedDays.mapNotNull { day ->
            filesByDay[day]?.let { dayFiles ->
                GalleryDaySection(
                    day = day,
                    files = dayFiles,
                    hourGroups = if (day in expandedDays) hourGroups(dayFiles) else emptyList(),
                )
            }
        }
        if (unknownFiles.isEmpty()) return sections
        return sections + GalleryDaySection(
            day = null,
            files = unknownFiles,
        )
    }

    private fun hourGroups(files: List<CameraFile>): List<GalleryHourGroup> =
        files.groupBy { captureHour(it) }
            .entries
            .filter { it.key != null }
            .map { (hour, hourFiles) ->
                GalleryHourGroup(
                    hour = hour ?: 0,
                    files = hourFiles,
                )
            }

    private fun captureHour(file: CameraFile): Int? {
        val raw = file.info.captureDate
        if (raw.length < 11) return null
        return raw.substring(9, 11).toIntOrNull()?.takeIf { it in 0..23 }
    }
}

object GalleryStickySectionPolicy {
    fun currentStickyDay(
        sections: List<GalleryDaySection>,
        visibleKeys: List<Any?>,
    ): GalleryDaySection? {
        if (sections.isEmpty() || visibleKeys.isEmpty()) return null
        val sectionByKey = mutableMapOf<Any, GalleryDaySection>()
        sections.forEach { section ->
            sectionByKey[dayKey(section.day)] = section
            section.files.forEach { file ->
                sectionByKey[file.info.handle] = section
            }
            section.hourGroups.forEach { hourGroup ->
                sectionByKey[hourKey(section.day, hourGroup.hour)] = section
                hourGroup.files.forEach { file ->
                    sectionByKey[file.info.handle] = section
                }
            }
        }
        return visibleKeys.firstNotNullOfOrNull { key -> sectionByKey[key] }
    }

    fun dayKey(day: LocalDate?): String = "day-${day ?: "unknown"}"

    fun hourKey(day: LocalDate?, hour: Int): String = "hour-$day-$hour"
}

object GalleryDateMetadataPolicy {
    fun shouldLoadMetadataForDateFilter(
        files: List<CameraFile>,
        dateFilter: GalleryDateFilter,
    ): Boolean =
        dateFilter != GalleryDateFilter.All && shouldLoadMetadataForDatePicker(files)

    fun shouldLoadMetadataForDatePicker(files: List<CameraFile>): Boolean =
        files.isNotEmpty() && files.none { GalleryUiPolicy.captureDate(it) != null }
}

object GalleryDateDialogPolicy {
    fun emptyMessage(isLoadingMetadata: Boolean): String =
        if (isLoadingMetadata) {
            "正在读取相机照片日期..."
        } else {
            "相机文件里没有可识别日期"
        }
}

enum class GalleryDateRangeEndpoint {
    Start,
    End,
}

object GalleryDateRangePickerPolicy {
    private val fullDateFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd")

    fun fieldValue(day: LocalDate?): String =
        day?.format(fullDateFormatter) ?: "选择日期"

    fun nextEndpointAfterDate(endpoint: GalleryDateRangeEndpoint): GalleryDateRangeEndpoint =
        when (endpoint) {
            GalleryDateRangeEndpoint.Start -> GalleryDateRangeEndpoint.End
            GalleryDateRangeEndpoint.End -> GalleryDateRangeEndpoint.End
        }

    fun normalizedStart(start: LocalDate?, end: LocalDate?): LocalDate? =
        start?.let { startDay -> end?.let { minOf(startDay, it) } ?: startDay }

    fun normalizedEnd(start: LocalDate?, end: LocalDate?): LocalDate? =
        start?.let { startDay -> end?.let { maxOf(startDay, it) } ?: startDay }
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
                    if (GalleryDownloadUiPolicy.isNeverDownloadedOrRetryable(downloadStates[file.info.handle])) 0 else 1
                }.then(newestFirstComparator())
            )
        }

    private fun newestFirstComparator(): Comparator<CameraFile> =
        compareByDescending<CameraFile> { captureDateSortKey(it) }

    private fun oldestFirstComparator(): Comparator<CameraFile> =
        compareBy<CameraFile> { captureDateSortKey(it) }

    private fun captureDateSortKey(file: CameraFile): String {
        val captureDate = file.info.captureDate
        return if (captureDate.length >= 15) captureDate.take(15) else if (captureDate.length >= 8) {
            captureDate.take(8)
        } else {
            captureDate
        }
    }
}

object GalleryScrollResetPolicy {
    fun shouldScrollToTopAfterFilterOrSortChange(): Boolean = true
}

object GalleryCacheUsageUiPolicy {
    const val INITIAL_SCAN_DELAY_MS = 1_500L

    fun shouldScanCacheUsage(hasFiles: Boolean, isLoading: Boolean): Boolean =
        hasFiles && !isLoading
}

object GalleryThumbnailRequestWindowPolicy {
    const val REQUEST_DEBOUNCE_MS = 80L
    private const val PREFETCH_ROWS_BEFORE = 1
    private const val PREFETCH_ROWS_AFTER = 2

    fun handlesToRequest(
        orderedHandles: List<Int>,
        visibleHandles: List<Int>,
        columnCount: Int,
    ): List<Int> {
        if (orderedHandles.isEmpty()) return emptyList()
        val indexByHandle = orderedHandles.withIndex().associate { it.value to it.index }
        val normalizedColumnCount = columnCount.coerceAtLeast(1)
        val visibleIndexes = visibleHandles.mapNotNull(indexByHandle::get)
        if (visibleIndexes.isEmpty()) {
            val initialWindowSize = normalizedColumnCount * (1 + PREFETCH_ROWS_AFTER)
            return orderedHandles.take(initialWindowSize)
        }

        val start = (visibleIndexes.minOrNull()!! - normalizedColumnCount * PREFETCH_ROWS_BEFORE).coerceAtLeast(0)
        val end = (visibleIndexes.maxOrNull()!! + normalizedColumnCount * PREFETCH_ROWS_AFTER)
            .coerceAtMost(orderedHandles.lastIndex)
        val visibleSet = visibleHandles.toSet()
        val visibleOrdered = visibleHandles.filter { it in indexByHandle }.distinct()
        val nearby = orderedHandles
            .subList(start, end + 1)
            .filterNot { it in visibleSet }
        return visibleOrdered + nearby
    }
}

object GalleryFilterPanelPolicy {
    private val shortDateFormatter = DateTimeFormatter.ofPattern("MM-dd")

    fun defaultExpanded(): Boolean = false

    fun summary(state: GalleryFilterState, sortMode: GallerySortMode): String =
        buildList {
            add(dateLabel(state.date))
            folderSummaryLabel(state.folders)?.let(::add)
            add(formatLabel(state.formats))
            add(sortLabel(sortMode))
        }.joinToString(" · ")

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

    private fun folderSummaryLabel(folders: Set<GalleryFolderFilter>): String? =
        when (folders.size) {
            0 -> null
            1 -> GalleryFilterStatsPolicy.folderLabel(folders.single())
            else -> "${folders.size} 个文件夹"
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
            null,
            TransferState.ERROR,
            TransferState.DONE -> true
            TransferState.PENDING,
            TransferState.DOWNLOADING,
            TransferState.SAVING -> false
        }

    fun hasStarted(state: TransferState?): Boolean =
        when (state) {
            TransferState.PENDING,
            TransferState.DOWNLOADING,
            TransferState.SAVING,
            TransferState.DONE -> true
            null,
            TransferState.ERROR -> false
        }

    fun isQueuedOrActive(state: TransferState?): Boolean =
        when (state) {
            TransferState.PENDING,
            TransferState.DOWNLOADING,
            TransferState.SAVING -> true
            TransferState.DONE,
            TransferState.ERROR,
            null -> false
        }

    fun isNeverDownloadedOrRetryable(state: TransferState?): Boolean =
        when (state) {
            null,
            TransferState.ERROR -> true
            TransferState.PENDING,
            TransferState.DOWNLOADING,
            TransferState.SAVING,
            TransferState.DONE -> false
        }

    fun canDownloadFromHighDefinitionPreview(
        hasPreviewImage: Boolean,
        state: TransferState?,
    ): Boolean =
        hasPreviewImage && when (state) {
            null,
            TransferState.ERROR,
            TransferState.PENDING,
            TransferState.DONE -> true
            TransferState.DOWNLOADING,
            TransferState.SAVING -> false
        }
}

enum class GalleryTileDownloadBadge {
    PendingText,
    Progress,
    DownloadedIcon,
    ErrorText,
}

object GalleryTileBadgePolicy {
    fun formatLabel(file: CameraFile): String? =
        file.info.formatLabel.takeIf { file.info.format != PtpObjectFormat.UNDEFINED }

    fun downloadBadge(state: TransferState?): GalleryTileDownloadBadge? =
        when (state) {
            TransferState.PENDING -> GalleryTileDownloadBadge.PendingText
            TransferState.DOWNLOADING,
            TransferState.SAVING -> GalleryTileDownloadBadge.Progress
            TransferState.DONE -> GalleryTileDownloadBadge.DownloadedIcon
            TransferState.ERROR -> GalleryTileDownloadBadge.ErrorText
            null -> null
        }
}

object GalleryHeaderActionPolicy {
    const val shouldShowClearDownloadRecords = false
}

object DownloadCenterActionPolicy {
    const val clearDownloadRecordsLabel = "清理记录"
    const val pauseDownloadsLabel = "暂停下载"

    fun canReturnToGallery(activeCount: Int): Boolean =
        true

    fun canPauseDownloads(activeCount: Int): Boolean =
        activeCount > 0

    fun canClearRecords(totalCount: Int, activeCount: Int): Boolean =
        totalCount > 0 && activeCount == 0
}

object GalleryDisconnectPolicy {
    const val confirmTitle = "确认断开相机连接？"
    const val confirmMessage = "继续停留会保持相机连接；确认离开相册后，将返回首页并断开相机连接。"

    fun shouldConfirmBeforeDisconnect(): Boolean = true
}

object GalleryDragSelectionPolicy {
    private const val HORIZONTAL_INTENT_RATIO = 1.25f
    private const val MIN_HORIZONTAL_SLOP_MULTIPLIER = 1.15f

    fun shouldSelectForDrag(startHandleSelected: Boolean): Boolean = !startHandleSelected

    fun shouldStartDragSelection(
        deltaX: Float,
        deltaY: Float,
        touchSlop: Float,
        selectionActive: Boolean = false,
    ): Boolean {
        val distance = hypot(deltaX.toDouble(), deltaY.toDouble()).toFloat()
        if (distance < touchSlop) return false
        val horizontal = abs(deltaX)
        val vertical = abs(deltaY)
        val minHorizontal = touchSlop * MIN_HORIZONTAL_SLOP_MULTIPLIER
        return horizontal >= minHorizontal && horizontal >= vertical * HORIZONTAL_INTENT_RATIO
    }

    fun shouldCommitDragSelection(
        startHandle: Int,
        endHandle: Int?,
        endDownloadState: TransferState?,
    ): Boolean =
        endHandle != null &&
            endHandle != startHandle &&
            GalleryDownloadUiPolicy.canSelect(endDownloadState)

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

    fun updatedRangeSelection(
        currentSelection: Set<Int>,
        orderedHandles: List<Int>,
        startHandle: Int,
        endHandle: Int,
        downloadStates: Map<Int, TransferState?>,
        shouldSelect: Boolean,
    ): Set<Int> {
        val startIndex = orderedHandles.indexOf(startHandle)
        val endIndex = orderedHandles.indexOf(endHandle)
        if (startIndex < 0 || endIndex < 0) return currentSelection
        val range = if (startIndex <= endIndex) {
            startIndex..endIndex
        } else {
            endIndex..startIndex
        }
        val selectableHandles = range
            .map { orderedHandles[it] }
            .filter { handle -> GalleryDownloadUiPolicy.canSelect(downloadStates[handle]) }
            .toSet()
        return if (shouldSelect) {
            currentSelection + selectableHandles
        } else {
            currentSelection - selectableHandles
        }
    }

    fun autoScrollDelta(
        pointerY: Float,
        viewportStart: Float,
        viewportEnd: Float,
        edgeSize: Float,
        maxDelta: Float,
    ): Float {
        if (edgeSize <= 0f || maxDelta <= 0f || viewportEnd <= viewportStart) return 0f
        return when {
            pointerY < viewportStart + edgeSize -> {
                val intensity = ((viewportStart + edgeSize - pointerY) / edgeSize).coerceIn(0f, 1f)
                -maxDelta * intensity
            }
            pointerY > viewportEnd - edgeSize -> {
                val intensity = ((pointerY - (viewportEnd - edgeSize)) / edgeSize).coerceIn(0f, 1f)
                maxDelta * intensity
            }
            else -> 0f
        }
    }
}

object GalleryColumnLayoutPolicy {
    const val MIN_COLUMNS = 2
    const val MAX_COLUMNS = 6
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

object GalleryGridSpacingPolicy {
    const val HORIZONTAL_DP = 2
    const val VERTICAL_DP = 2
}

object GalleryPreviewNavigationPolicy {
    fun initialPage(files: List<CameraFile>, selectedHandle: Int): Int {
        val index = files.indexOfFirst { it.info.handle == selectedHandle }
        return index.coerceAtLeast(0)
    }
}

object GalleryPreviewThumbnailPolicy {
    private const val NEIGHBOR_RADIUS = 1

    fun handlesToRequest(
        files: List<CameraFile>,
        currentPage: Int,
        radius: Int = NEIGHBOR_RADIUS,
    ): List<Int> {
        if (currentPage !in files.indices) return emptyList()
        val safeRadius = radius.coerceAtLeast(0)
        val start = (currentPage - safeRadius).coerceAtLeast(0)
        val end = (currentPage + safeRadius).coerceAtMost(files.lastIndex)
        return (start..end).map { index -> files[index].info.handle }
    }
}

object GalleryPreviewRotationPolicy {
    fun previousManualRotationDegrees(currentDegrees: Int): Int =
        normalizedDegrees(currentDegrees - 90)

    fun nextManualRotationDegrees(currentDegrees: Int): Int =
        normalizedDegrees(currentDegrees + 90)

    fun autoRotationDegrees(
        file: CameraFile,
        decodedWidth: Int,
        decodedHeight: Int,
        imageData: ByteArray?,
    ): Int {
        exifRotationDegrees(imageData)?.let { exifDegrees ->
            if (exifRotationAlreadyApplied(exifDegrees, decodedWidth, decodedHeight)) return 0
            return exifDegrees
        }
        cameraVendorOrientationRotationDegrees(file.info.orientation)?.let { metadataDegrees ->
            if (exifRotationAlreadyApplied(metadataDegrees, decodedWidth, decodedHeight)) return 0
            return metadataDegrees
        }
        if (decodedWidth <= 0 || decodedHeight <= 0) return 0
        val expectedWidth = firstPositive(file.info.imagePixWidth, file.info.thumbPixWidth)
        val expectedHeight = firstPositive(file.info.imagePixHeight, file.info.thumbPixHeight)
        if (expectedWidth <= 0 || expectedHeight <= 0) return 0
        val expectedPortrait = expectedHeight > expectedWidth
        val decodedPortrait = decodedHeight > decodedWidth
        return if (expectedPortrait != decodedPortrait) 90 else 0
    }

    private fun exifRotationAlreadyApplied(
        exifDegrees: Int,
        decodedWidth: Int,
        decodedHeight: Int,
    ): Boolean {
        if (decodedWidth <= 0 || decodedHeight <= 0) return false
        return (exifDegrees == 90 || exifDegrees == 270) && decodedHeight > decodedWidth
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

    fun cameraVendorOrientationRotationDegrees(orientation: Int?): Int? =
        when (orientation) {
            2 -> 90
            3 -> 180
            4 -> 270
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

object GalleryThumbnailDisplayPolicy {
    fun thumbnailFor(file: CameraFile, thumbnailsByHandle: Map<Int, ByteArray>): ByteArray? =
        thumbnailsByHandle[file.info.handle] ?: file.thumbnail

    fun thumbnailFor(file: CameraFile, cachedThumbnail: ByteArray?): ByteArray? =
        cachedThumbnail ?: file.thumbnail

    fun rotationDegrees(
        file: CameraFile,
        decodedWidth: Int,
        decodedHeight: Int,
        thumbnail: ByteArray,
    ): Int =
        GalleryPreviewRotationPolicy.autoRotationDegrees(
            file = file,
            decodedWidth = decodedWidth,
            decodedHeight = decodedHeight,
            imageData = thumbnail,
        )
}

object GalleryThumbnailDiagnosticPolicy {
    fun summary(
        handle: Int,
        file: CameraFile?,
        thumbnail: ByteArray,
        decodedWidth: Int,
        decodedHeight: Int,
    ): String {
        val thumbExifRotation = GalleryPreviewRotationPolicy.exifRotationDegrees(thumbnail)
        val autoRotation = if (file != null) {
            GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = file,
                decodedWidth = decodedWidth,
                decodedHeight = decodedHeight,
                imageData = thumbnail,
            )
        } else {
            null
        }
        val info = file?.info
        return "Thumbnail loaded handle=$handle bytes=${thumbnail.size} head=${thumbnail.headHex()} " +
            "thumbExifRotation=${thumbExifRotation?.toString() ?: "none"} " +
            "decoded=${dimensionLabel(decodedWidth, decodedHeight)} " +
            "object=${dimensionLabel(info?.imagePixWidth, info?.imagePixHeight)} " +
            "thumbInfo=${dimensionLabel(info?.thumbPixWidth, info?.thumbPixHeight)} " +
            "objectOrientation=${info?.orientation?.toString() ?: "unknown"} " +
            "autoRotation=${autoRotation?.toString() ?: "unknown"}"
    }

    private fun dimensionLabel(width: Int?, height: Int?): String =
        if (width != null && height != null && width > 0 && height > 0) "${width}x$height" else "unknown"

    private fun ByteArray.headHex(byteCount: Int = 16): String =
        take(byteCount).joinToString("") { "%02x".format(it) }
}

internal object GalleryThumbnailDecodePolicy {
    const val GRID_MAX_DECODED_SIDE = 512
    const val PREVIEW_MAX_DECODED_SIDE = 1024

    fun sampleSize(
        width: Int,
        height: Int,
        maxDecodedSide: Int = PREVIEW_MAX_DECODED_SIDE,
    ): Int {
        val maxSide = max(width, height)
        if (maxSide <= maxDecodedSide || width <= 0 || height <= 0 || maxDecodedSide <= 0) return 1
        var sampleSize = 1
        while (maxSide / sampleSize > maxDecodedSide) {
            sampleSize *= 2
        }
        return sampleSize
    }
}

internal object GalleryPreviewImagePolicy {
    const val FULL_IMAGE_MAX_DECODED_SIDE = 3072

    fun displayBytes(previewImage: ByteArray?, thumbnail: ByteArray?): ByteArray? =
        previewImage ?: thumbnail
}

internal object GalleryPreviewActionBarPolicy {
    fun downloadLabel(state: TransferState?): String =
        when (state) {
            TransferState.PENDING -> "排队"
            TransferState.DOWNLOADING -> "下载中"
            TransferState.SAVING -> "保存中"
            TransferState.DONE -> "已保存"
            TransferState.ERROR -> "重试"
            null -> "下载"
        }

    fun downloadModeLabel(preferCompressedDownloads: Boolean): String =
        if (preferCompressedDownloads) "压缩" else "原图"

    fun canRequestHighDefinitionPreview(file: CameraFile): Boolean =
        file.info.isJpeg || file.info.isHeif

    fun highDefinitionPreviewLabel(hasPreview: Boolean, isLoading: Boolean): String =
        when {
            isLoading -> "加载中"
            hasPreview -> "已加载"
            else -> "高清预览"
        }
}

data class GalleryPreviewFileInfoRow(
    val label: String,
    val value: String,
)

internal object GalleryPreviewFileInfoPolicy {
    private val inputFormatter = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss")
    private val outputFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")

    fun rows(file: CameraFile): List<GalleryPreviewFileInfoRow> {
        val info = file.info
        return buildList {
            add(GalleryPreviewFileInfoRow("文件", info.filename))
            add(GalleryPreviewFileInfoRow("格式", info.formatLabel))
            dimensionLabel(info.imagePixWidth, info.imagePixHeight)?.let {
                add(GalleryPreviewFileInfoRow("尺寸", it))
            }
            dimensionLabel(info.thumbPixWidth, info.thumbPixHeight)?.let {
                add(GalleryPreviewFileInfoRow("缩略图", it))
            }
            formatBytes(info.compressedSize)?.let {
                add(GalleryPreviewFileInfoRow("大小", it))
            }
            captureDateLabel(info.captureDate)?.let {
                add(GalleryPreviewFileInfoRow("拍摄时间", it))
            }
            add(GalleryPreviewFileInfoRow("Handle", info.handle.toString()))
            add(GalleryPreviewFileInfoRow("存储", "0x%08X".format(info.storageId)))
            if (info.parentObject > 0) {
                add(GalleryPreviewFileInfoRow("文件夹", info.parentObject.toString()))
            }
            info.orientation?.let {
                add(GalleryPreviewFileInfoRow("方向", it.toString()))
            }
        }
    }

    private fun dimensionLabel(width: Int, height: Int): String? =
        if (width > 0 && height > 0) "$width x $height" else null

    private fun captureDateLabel(value: String): String? {
        if (value.length < 15) return null
        return runCatching {
            LocalDateTime.parse(value.take(15), inputFormatter).format(outputFormatter)
        }.getOrNull()
    }

    private fun formatBytes(bytes: Int): String? {
        if (bytes <= 0) return null
        val kib = 1024.0
        val mib = kib * 1024.0
        return when {
            bytes < 1024 -> "$bytes B"
            bytes < 1024 * 1024 -> "${(bytes / kib).toInt()} KB"
            else -> "%.1f MB".format(bytes / mib).replace(".0 MB", " MB")
        }
    }
}
