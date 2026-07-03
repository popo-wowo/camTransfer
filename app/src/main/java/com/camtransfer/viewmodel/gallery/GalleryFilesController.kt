package com.camtransfer.viewmodel.gallery

import com.camtransfer.model.CameraFile
import com.camtransfer.protocol.CameraVendorHiddenObjectProbePolicy
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import java.time.LocalDate
import java.time.format.DateTimeFormatter

class GalleryFilesController(
    private val scope: CoroutineScope,
    private val requestScheduler: GalleryRequestScheduler,
    private val thumbnailCache: () -> Map<Int, ByteArray>,
    private val hasActiveThumbnailWork: () -> Boolean = { false },
) {
    private val _files = MutableStateFlow<List<CameraFile>>(emptyList())
    val files: StateFlow<List<CameraFile>> = _files.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isLoadingHiddenFormats = MutableStateFlow(false)
    val isLoadingHiddenFormats: StateFlow<Boolean> = _isLoadingHiddenFormats.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private var loadJob: Job? = null
    private var fullObjectInfoJob: Job? = null
    private var loadedSource: CameraFileSource? = null
    private var fullObjectInfoPausedForExclusiveOperation = false

    fun loadIfNeeded(cameraSource: CameraFileSource) {
        val sourceChanged = loadedSource != null && loadedSource !== cameraSource
        if (!GalleryFileLoadPolicy.shouldLoad(
                currentSource = cameraSource,
                loadedSource = loadedSource,
                isLoading = _isLoading.value,
                lastLoadFailed = _error.value != null,
            )
        ) {
            return
        }
        if (sourceChanged) reset()
        load(cameraSource)
    }

    fun load(cameraSource: CameraFileSource) {
        if (_isLoading.value) return
        _isLoading.value = true
        _error.value = null

        loadJob = scope.launch(Dispatchers.IO) {
            try {
                DiagnosticLog.append(cameraSource.context, "Gallery", "Loading file list")
                val initialFiles = requestScheduler.run(GalleryRequestPriority.BackgroundMetadata) {
                    cameraSource.fastInitialFiles()
                }
                if (GalleryFastInitialLoadPolicy.shouldPublishInitialFiles(_files.value, initialFiles)) {
                    DiagnosticLog.append(cameraSource.context, "Gallery", "Fast file placeholders loaded total=${initialFiles.size}")
                    _files.value = GalleryFastInitialLoadPolicy.mergeWithCachedThumbnails(
                        files = initialFiles,
                        thumbnailsByHandle = thumbnailCache(),
                    )
                    if (GalleryFastInitialLoadPolicy.shouldDeferFullObjectInfoUntilAfterThumbnails(initialFiles.size)) {
                        DiagnosticLog.append(
                            cameraSource.context,
                            "Gallery",
                            "Deferred full object info for large gallery initialFileCount=${initialFiles.size}",
                        )
                        loadedSource = cameraSource
                        _isLoading.value = false
                        if (GalleryFastInitialLoadPolicy.shouldContinueFullObjectInfoAfterInitialPlaceholders(initialFiles.size)) {
                            scheduleFullObjectInfoLoad(cameraSource)
                        }
                        return@launch
                    }
                }
                val fileList = requestScheduler.run(GalleryRequestPriority.BackgroundMetadata) {
                    cameraSource.listFiles()
                }
                DiagnosticLog.appendFileSummary(cameraSource.context, fileList)
                _files.value = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
                    currentFiles = _files.value,
                    fullFiles = fileList,
                    thumbnailsByHandle = thumbnailCache(),
                )
                loadedSource = cameraSource
                _isLoading.value = false
            } catch (e: Exception) {
                DiagnosticLog.append(cameraSource.context, "Gallery", "File list load failed", e)
                _error.value = e.message ?: "加载文件列表失败"
                loadedSource = null
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun mergeThumbnail(handle: Int, thumbnail: ByteArray, updatedFile: CameraFile?) {
        _files.value = _files.value.map { file ->
            if (file.info.handle == handle) {
                GalleryFastInitialLoadPolicy.mergeThumbnailMetadata(
                    existingFile = file,
                    thumbnailFile = updatedFile,
                ).copy(thumbnail = thumbnail)
            } else {
                file
            }
        }
    }

    fun hasThumbnail(handle: Int): Boolean =
        _files.value.any { it.info.handle == handle && it.thumbnail != null }

    fun reset() {
        loadJob?.cancel()
        fullObjectInfoJob?.cancel()
        loadJob = null
        fullObjectInfoJob = null
        fullObjectInfoPausedForExclusiveOperation = false
        _files.value = emptyList()
        _isLoading.value = false
        _error.value = null
        loadedSource = null
    }

    suspend fun pauseForExclusiveOperation(cameraSource: CameraFileSource, reason: String) {
        if (loadedSource !== cameraSource) return
        val jobToCancel = fullObjectInfoJob
        if (fullObjectInfoJob?.isActive == true) {
            DiagnosticLog.append(cameraSource.context, "Gallery", "Paused full object info for $reason")
        }
        fullObjectInfoPausedForExclusiveOperation = true
        jobToCancel?.cancel()
        fullObjectInfoJob = null
        _isLoadingHiddenFormats.value = false
        jobToCancel?.join()
    }

    fun resumeAfterExclusiveOperation(cameraSource: CameraFileSource, reason: String) {
        if (loadedSource !== cameraSource) return
        if (!fullObjectInfoPausedForExclusiveOperation) return
        fullObjectInfoPausedForExclusiveOperation = false
        if (GalleryFastInitialLoadPolicy.shouldResumeFullObjectInfoAfterExclusiveOperation(_files.value)) {
            DiagnosticLog.append(cameraSource.context, "Gallery", "Resuming full object info after $reason")
            scheduleFullObjectInfoLoad(cameraSource)
        }
    }

    private fun scheduleFullObjectInfoLoad(cameraSource: CameraFileSource) {
        fullObjectInfoJob?.cancel()
        fullObjectInfoJob = scope.launch(Dispatchers.IO) {
            delay(GalleryFastInitialLoadPolicy.FULL_OBJECT_INFO_AFTER_PLACEHOLDERS_DELAY_MS)
            if (loadedSource !== cameraSource) return@launch
            if (fullObjectInfoPausedForExclusiveOperation) return@launch
            _isLoadingHiddenFormats.value = true
            try {
                DiagnosticLog.append(cameraSource.context, "Gallery", "Loading full object info incrementally after initial thumbnails")
                val handles = GalleryFastInitialLoadPolicy.handlesNeedingFullObjectInfo(_files.value)
                val batch = mutableListOf<CameraFile>()
                for (handle in handles) {
                    if (loadedSource !== cameraSource) return@launch
                    if (fullObjectInfoPausedForExclusiveOperation) return@launch
                    waitForThumbnailDrain(cameraSource)
                    if (loadedSource !== cameraSource) return@launch
                    if (fullObjectInfoPausedForExclusiveOperation) return@launch
                    val file = requestScheduler.run(GalleryRequestPriority.BackgroundMetadata) {
                        cameraSource.resolveFile(handle)
                    }
                    if (file != null && GalleryFastInitialLoadPolicy.shouldPublishResolvedMetadata(file)) {
                        batch += file
                    }
                    if (GalleryFastInitialLoadPolicy.shouldPublishIncrementalMetadataBatch(
                            resolvedCount = batch.size,
                            isFinalBatch = false,
                        )
                    ) {
                        publishFullObjectInfoBatch(batch)
                        DiagnosticLog.append(
                            cameraSource.context,
                            "Gallery",
                            "Published incremental object info batch count=${batch.size}",
                        )
                        batch.clear()
                        yield()
                    }
                }
                if (GalleryFastInitialLoadPolicy.shouldPublishIncrementalMetadataBatch(
                        resolvedCount = batch.size,
                        isFinalBatch = true,
                    )
                ) {
                    publishFullObjectInfoBatch(batch)
                    DiagnosticLog.append(
                        cameraSource.context,
                        "Gallery",
                        "Published final object info batch count=${batch.size}",
                    )
                    DiagnosticLog.appendMetadataSnapshot(
                        context = cameraSource.context,
                        label = "full-object-info-final",
                        files = _files.value,
                    )
                    resolveHiddenStillFilesAfterFullMetadata(cameraSource)
                }
            } catch (e: Exception) {
                DiagnosticLog.append(cameraSource.context, "Gallery", "Full object info background load failed", e)
            } finally {
                _isLoadingHiddenFormats.value = false
            }
        }
    }

    private suspend fun waitForThumbnailDrain(cameraSource: CameraFileSource) {
        var loggedWait = false
        while (GalleryFastInitialLoadPolicy.shouldWaitForThumbnailDrainBeforeFullObjectInfo(hasActiveThumbnailWork())) {
            if (loadedSource !== cameraSource) return
            if (fullObjectInfoPausedForExclusiveOperation) return
            if (!loggedWait) {
                DiagnosticLog.append(
                    cameraSource.context,
                    "Gallery",
                    "Deferring full object info while thumbnails are active",
                )
                loggedWait = true
            }
            delay(GalleryFastInitialLoadPolicy.FULL_OBJECT_INFO_WAIT_FOR_THUMBNAILS_DELAY_MS)
        }
    }

    private suspend fun resolveHiddenStillFilesAfterFullMetadata(cameraSource: CameraFileSource) {
        if (loadedSource !== cameraSource) {
            DiagnosticLog.append(cameraSource.context, "Gallery", "Skipped hidden still metadata because source changed")
            return
        }
        val handles = _files.value.map { it.info.handle }
        DiagnosticLog.append(cameraSource.context, "Gallery", "Resolving hidden still metadata knownHandles=${handles.size}")
        val additionalFiles = requestScheduler.run(GalleryRequestPriority.BackgroundMetadata) {
            cameraSource.resolveAdditionalFiles(handles)
        }
        if (additionalFiles.isEmpty()) {
            DiagnosticLog.append(cameraSource.context, "Gallery", "No hidden still metadata resolved")
            return
        }
        publishFullObjectInfoBatch(additionalFiles)
        DiagnosticLog.append(
            cameraSource.context,
            "Gallery",
            "Published hidden still object info count=${additionalFiles.size}",
        )
        DiagnosticLog.appendMetadataSnapshot(
            context = cameraSource.context,
            label = "hidden-still-final",
            files = _files.value,
        )
    }

    private fun publishFullObjectInfoBatch(files: List<CameraFile>) {
        if (files.isEmpty()) return
        val merged = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
            currentFiles = _files.value,
            fullFiles = files,
            thumbnailsByHandle = thumbnailCache(),
        )
        _files.value = merged
    }
}

internal object GalleryFileLoadPolicy {
    fun shouldLoad(
        currentSource: Any,
        loadedSource: Any?,
        isLoading: Boolean,
        lastLoadFailed: Boolean,
    ): Boolean {
        if (isLoading) return false
        if (lastLoadFailed) return true
        return currentSource !== loadedSource
    }
}

internal object GalleryFastInitialLoadPolicy {
    const val MAX_INITIAL_THUMBNAIL_REQUESTS = 8
    const val FULL_OBJECT_INFO_AFTER_PLACEHOLDERS_DELAY_MS = 3_000L
    const val FULL_OBJECT_INFO_WAIT_FOR_THUMBNAILS_DELAY_MS = 50L
    const val INCREMENTAL_METADATA_BATCH_SIZE = 12
    private const val LARGE_GALLERY_PLACEHOLDER_COUNT = 500

    fun shouldPublishInitialFiles(currentFiles: List<CameraFile>, initialFiles: List<CameraFile>): Boolean =
        currentFiles.isEmpty() && initialFiles.isNotEmpty()

    fun shouldDeferFullObjectInfoUntilAfterThumbnails(initialFileCount: Int): Boolean =
        initialFileCount >= LARGE_GALLERY_PLACEHOLDER_COUNT

    fun shouldContinueFullObjectInfoAfterInitialPlaceholders(initialFileCount: Int): Boolean =
        initialFileCount > 0

    fun shouldWaitForThumbnailDrainBeforeFullObjectInfo(hasActiveThumbnailWork: Boolean): Boolean =
        hasActiveThumbnailWork

    fun shouldPublishIncrementalMetadataBatch(
        resolvedCount: Int,
        isFinalBatch: Boolean,
    ): Boolean =
        isFinalBatch || resolvedCount >= INCREMENTAL_METADATA_BATCH_SIZE

    fun shouldResumeFullObjectInfoAfterExclusiveOperation(files: List<CameraFile>): Boolean =
        handlesNeedingFullObjectInfo(files).isNotEmpty()

    fun handlesNeedingFullObjectInfo(files: List<CameraFile>): List<Int> =
        files.filter { file ->
            file.info.format == com.camtransfer.protocol.PtpObjectFormat.UNDEFINED ||
                file.info.compressedSize <= 0 ||
                file.info.filename.startsWith("0x", ignoreCase = true)
        }.map { it.info.handle }

    fun shouldPublishResolvedMetadata(file: CameraFile): Boolean =
        !file.info.isFolder

    fun shouldLoadThumbnail(
        isTransferPreparingOrActive: Boolean = false,
        isLoadingFullObjectInfo: Boolean,
        hasThumbnail: Boolean,
        activeOrPendingThumbnailCount: Int,
        isExplicitVisibleWindow: Boolean = false,
    ): Boolean {
        if (isTransferPreparingOrActive) return false
        if (hasThumbnail) return false
        if (
            isLoadingFullObjectInfo &&
            !isExplicitVisibleWindow &&
            activeOrPendingThumbnailCount >= MAX_INITIAL_THUMBNAIL_REQUESTS
        ) {
            return false
        }
        return true
    }

    fun mergeWithExistingThumbnails(
        currentFiles: List<CameraFile>,
        fullFiles: List<CameraFile>,
        thumbnailsByHandle: Map<Int, ByteArray> = emptyMap(),
    ): List<CameraFile> {
        val mergedThumbnailsByHandle = currentFiles.mapNotNull { file ->
            file.thumbnail?.let { file.info.handle to it }
        }.toMap() + thumbnailsByHandle
        val files = if (currentFiles.isNotEmpty()) {
            mergeFullObjectInfoIntoExisting(
                currentFiles = currentFiles,
                fullFiles = fullFiles,
            )
        } else {
            fullFiles
        }
        return mergeWithCachedThumbnails(files, mergedThumbnailsByHandle)
    }

    fun mergeWithCachedThumbnails(
        files: List<CameraFile>,
        thumbnailsByHandle: Map<Int, ByteArray>,
    ): List<CameraFile> {
        if (thumbnailsByHandle.isEmpty()) return files
        return files.map { file ->
            val thumbnail = thumbnailsByHandle[file.info.handle]
            if (thumbnail == null || file.thumbnail != null) file else file.copy(thumbnail = thumbnail)
        }
    }

    fun mergeThumbnailMetadata(
        existingFile: CameraFile,
        thumbnailFile: CameraFile?,
    ): CameraFile {
        if (thumbnailFile == null) return existingFile
        return thumbnailFile.copy(
            info = thumbnailFile.info.copy(
                captureDate = existingFile.info.captureDate,
            ),
            thumbnail = existingFile.thumbnail,
        )
    }

    private fun mergeFullObjectInfoIntoExisting(
        currentFiles: List<CameraFile>,
        fullFiles: List<CameraFile>,
    ): List<CameraFile> {
        val fullFilesByHandle = fullFiles.associateBy { it.info.handle }
        val currentHandles = currentFiles.map { it.info.handle }.toSet()
        val mergedCurrent = currentFiles.map { file ->
            val fullFile = fullFilesByHandle[file.info.handle] ?: return@map file
            mergeResolvedMetadata(existingFile = file, resolvedFile = fullFile)
        }
        val extraFullFiles = fullFiles.filterNot { it.info.handle in currentHandles }
        return mergedCurrent + extraFullFiles
    }

    private fun mergeResolvedMetadata(
        existingFile: CameraFile,
        resolvedFile: CameraFile,
    ): CameraFile =
        resolvedFile.copy(
            info = resolvedFile.info.copy(
                captureDate = resolvedCaptureDate(
                    existingCaptureDate = existingFile.info.captureDate,
                    resolvedCaptureDate = resolvedFile.info.captureDate,
                ),
            ),
            thumbnail = resolvedFile.thumbnail,
        )

    private fun resolvedCaptureDate(
        existingCaptureDate: String,
        resolvedCaptureDate: String,
    ): String {
        val existingDay = captureDayKey(existingCaptureDate)
        val resolvedDay = captureDayKey(resolvedCaptureDate)
        return when {
            existingDay == null -> resolvedCaptureDate
            resolvedDay == null -> existingCaptureDate
            existingDay == resolvedDay -> resolvedCaptureDate
            else -> existingCaptureDate
        }
    }

    private fun captureDayKey(captureDate: String): String? {
        if (captureDate.length < 8) return null
        val day = captureDate.take(8)
        return runCatching {
            LocalDate.parse(day, DateTimeFormatter.BASIC_ISO_DATE)
            day
        }.getOrNull()
    }
}
