package com.camtransfer.viewmodel.gallery

import com.camtransfer.model.CameraFile
import com.camtransfer.model.CameraFileFormatHint
import java.time.LocalDate
import java.time.format.DateTimeFormatter

data class HighDefinitionPreviewItem(
    val previewFile: CameraFile,
    val rawFile: CameraFile?,
)

data class HighDefinitionPreviewSession(
    val activeDate: LocalDate,
    val files: List<CameraFile>,
    val currentIndex: Int = 0,
    val failedHandles: Set<Int> = emptySet(),
    val pausedForTransfer: Boolean = false,
    val activeWindowHandles: List<Int> = emptyList(),
) {
    fun nextFile(
        loadedHandles: Set<Int>,
        loadingHandles: Set<Int>,
    ): CameraFile? {
        val searchFiles = if (activeWindowHandles.isNotEmpty()) {
            val byHandle = files.associateBy { it.info.handle }
            activeWindowHandles.mapNotNull(byHandle::get)
        } else {
            files.drop(currentIndex.coerceAtLeast(0))
        }
        return searchFiles.firstOrNull { file ->
            val handle = file.info.handle
            handle !in loadedHandles &&
                handle !in loadingHandles &&
                handle !in failedHandles
        }
    }

    fun markLoaded(handle: Int): HighDefinitionPreviewSession =
        copy(currentIndex = nextIndexAfter(handle))

    fun markFailed(handle: Int): HighDefinitionPreviewSession =
        copy(
            currentIndex = nextIndexAfter(handle),
            failedHandles = failedHandles + handle,
        )

    fun prioritizeVisibleHandles(
        visibleHandles: List<Int>,
        loadedHandles: Set<Int>,
        loadingHandles: Set<Int>,
    ): HighDefinitionPreviewSession {
        val targetHandle = visibleHandles.firstOrNull { handle ->
            handle !in loadedHandles &&
                handle !in loadingHandles &&
                handle !in failedHandles
        }
        val targetWindow = activeWindowForVisibleHandles(visibleHandles)
        val targetIndex = targetHandle?.let { handle -> files.indexOfFirst { it.info.handle == handle } } ?: currentIndex
        return copy(
            currentIndex = if (targetIndex >= 0) targetIndex else currentIndex,
            activeWindowHandles = targetWindow,
        )
    }

    fun withFiles(nextFiles: List<CameraFile>): HighDefinitionPreviewSession =
        copy(files = nextFiles, currentIndex = 0)

    fun pauseForTransfer(): HighDefinitionPreviewSession =
        copy(pausedForTransfer = true)

    fun resumeAfterTransfer(): HighDefinitionPreviewSession =
        copy(pausedForTransfer = false)

    fun activeWindowHandleSet(): Set<Int> =
        activeWindowHandles.toSet()

    private fun nextIndexAfter(handle: Int): Int {
        val currentHandleIndex = files.indexOfFirst { it.info.handle == handle }
        if (currentHandleIndex < 0) return currentIndex
        if (currentIndex != currentHandleIndex) return currentIndex
        return (currentHandleIndex + 1).coerceAtMost(files.size)
    }

    private fun activeWindowForVisibleHandles(visibleHandles: List<Int>): List<Int> {
        val visibleIndices = visibleHandles.mapNotNull { visibleHandle ->
            files.indexOfFirst { it.info.handle == visibleHandle }.takeIf { it >= 0 }
        }
        if (visibleIndices.isEmpty()) return emptyList()
        val firstVisible = visibleIndices.min()
        val lastVisible = visibleIndices.max()
        val start = (firstVisible - WINDOW_BEFORE_VISIBLE).coerceAtLeast(0)
        val end = (lastVisible + WINDOW_AFTER_VISIBLE).coerceAtMost(files.lastIndex)
        val visibleSet = visibleHandles.toSet()
        val visible = files.slice(firstVisible..lastVisible)
            .filter { it.info.handle in visibleSet }
            .map { it.info.handle }
        val after = if (lastVisible + 1 <= end) {
            files.slice((lastVisible + 1)..end).map { it.info.handle }
        } else {
            emptyList()
        }
        val before = if (start <= firstVisible - 1) {
            files.slice(start until firstVisible).map { it.info.handle }
        } else {
            emptyList()
        }
        return (visible + after + before).distinct()
    }

    private companion object {
        const val WINDOW_BEFORE_VISIBLE = 5
        const val WINDOW_AFTER_VISIBLE = 20
    }
}

internal object HighDefinitionPreviewSessionPolicy {
    private val basicDayFormatter = DateTimeFormatter.BASIC_ISO_DATE

    fun build(
        files: List<CameraFile>,
        activeDate: LocalDate,
    ): HighDefinitionPreviewSession =
        buildFromItems(
            activeDate = activeDate,
            items = previewItemsForDate(files, activeDate),
        )

    fun buildFromItems(
        activeDate: LocalDate,
        items: List<HighDefinitionPreviewItem>,
    ): HighDefinitionPreviewSession =
        HighDefinitionPreviewSession(
            activeDate = activeDate,
            files = items.map { it.previewFile },
        )

    fun previewableFilesForDate(
        files: List<CameraFile>,
        activeDate: LocalDate,
    ): List<CameraFile> =
        previewItemsForDate(files, activeDate).map { it.previewFile }

    fun previewItemsForDate(
        files: List<CameraFile>,
        activeDate: LocalDate,
    ): List<HighDefinitionPreviewItem> {
        val sameDateFiles = files.filter { file ->
            !file.info.isFolder && captureDate(file) == activeDate
        }
        val ambiguousItems = ambiguousHeifRawItems(sameDateFiles)
        val ambiguousHandles = ambiguousItems.flatMap { item ->
            listOfNotNull(item.previewFile.info.handle, item.rawFile?.info?.handle)
        }.toSet()
        val rawFiles = sameDateFiles
            .filterNot { it.info.handle in ambiguousHandles }
            .filter(::isRawSidecar)
        val resolvedItems = sameDateFiles
            .filterNot { it.info.handle in ambiguousHandles }
            .filter(::isDisplayPreviewFile)
            .map { previewFile ->
                HighDefinitionPreviewItem(
                    previewFile = previewFile,
                    rawFile = bestRawSidecarFor(previewFile, rawFiles),
                )
            }
        return (ambiguousItems + resolvedItems)
            .distinctBy { it.previewFile.info.handle }
    }

    fun availableDates(files: List<CameraFile>): List<LocalDate> =
        files.asSequence()
            .filter { file ->
                !file.info.isFolder &&
                    isDateSelectablePlaceholder(file)
            }
            .mapNotNull(::captureDate)
            .distinct()
            .sortedDescending()
            .toList()

    fun preferredActiveDate(
        files: List<CameraFile>,
        currentDate: LocalDate,
    ): LocalDate =
        if (previewableFilesForDate(files, currentDate).isNotEmpty()) {
            currentDate
        } else {
            availableDates(files).firstOrNull() ?: currentDate
        }

    private fun captureDate(file: CameraFile): LocalDate? {
        val raw = file.info.captureDate
        if (raw.length < 8) return null
        return runCatching {
            LocalDate.parse(raw.take(8), basicDayFormatter)
        }.getOrNull()
    }

    private fun isDisplayPreviewFile(file: CameraFile): Boolean =
        file.info.isJpeg ||
            file.info.isHeif ||
            CameraFileFormatHint.JPG in file.formatHints ||
            CameraFileFormatHint.HEIF in file.formatHints ||
            CameraFileFormatHint.EXTENDED_STILL_CANDIDATE in file.formatHints

    private fun ambiguousHeifRawItems(files: List<CameraFile>): List<HighDefinitionPreviewItem> {
        val ambiguous = files
            .filter(::isAmbiguousHeifRawPlaceholder)
            .sortedByDescending { it.info.handle }
        if (ambiguous.isEmpty()) return emptyList()
        val byHandle = ambiguous.associateBy { it.info.handle }
        val used = mutableSetOf<Int>()
        val items = mutableListOf<HighDefinitionPreviewItem>()
        for (file in ambiguous) {
            val handle = file.info.handle
            if (handle in used) continue
            val rawFile = byHandle[handle - 1]?.takeIf { (handle - it.info.handle) <= RAW_SIDECAR_HANDLE_DISTANCE }
            if (rawFile != null) {
                used += handle
                used += rawFile.info.handle
                items += HighDefinitionPreviewItem(
                    previewFile = file.asAmbiguousPreviewCandidate(),
                    rawFile = rawFile.asAmbiguousRawCandidate(),
                )
            } else {
                used += handle
                items += HighDefinitionPreviewItem(previewFile = file.asAmbiguousPreviewCandidate(), rawFile = null)
            }
        }
        return items
    }

    private fun CameraFile.asAmbiguousPreviewCandidate(): CameraFile =
        copy(formatHints = setOf(CameraFileFormatHint.HEIF))

    private fun CameraFile.asAmbiguousRawCandidate(): CameraFile =
        copy(formatHints = setOf(CameraFileFormatHint.RAW))

    private fun isAmbiguousHeifRawPlaceholder(file: CameraFile): Boolean =
            !file.info.isJpeg &&
            !file.info.isHeif &&
            !file.info.isRaw &&
            CameraFileFormatHint.EXTENDED_STILL_CANDIDATE in file.formatHints

    private fun isRawSidecar(file: CameraFile): Boolean =
        file.info.isRaw ||
            (
                (
                    CameraFileFormatHint.RAW in file.formatHints ||
                        CameraFileFormatHint.EXTENDED_STILL_CANDIDATE in file.formatHints
                    ) &&
                    CameraFileFormatHint.JPG !in file.formatHints &&
                    CameraFileFormatHint.HEIF !in file.formatHints
                )

    private fun isDateSelectablePlaceholder(file: CameraFile): Boolean =
        !file.info.isVideo &&
            CameraFileFormatHint.VIDEO !in file.formatHints

    private fun bestRawSidecarFor(
        previewFile: CameraFile,
        rawFiles: List<CameraFile>,
    ): CameraFile? {
        val previewStem = filenameStem(previewFile)
        val sameStem = if (previewStem != null) {
            rawFiles.firstOrNull { filenameStem(it) == previewStem }
        } else {
            null
        }
        return sameStem ?: rawFiles
            .filter { captureDate(it) == captureDate(previewFile) }
            .minByOrNull { kotlin.math.abs(it.info.handle - previewFile.info.handle) }
            ?.takeIf { kotlin.math.abs(it.info.handle - previewFile.info.handle) <= RAW_SIDECAR_HANDLE_DISTANCE }
    }

    private fun filenameStem(file: CameraFile): String? {
        val filename = file.info.filename
        if (!filename.contains('.')) return null
        return filename.substringBeforeLast('.').takeIf { it.isNotBlank() }
    }

    private const val RAW_SIDECAR_HANDLE_DISTANCE = 3
}
