package com.camtransfer.viewmodel.gallery

import com.camtransfer.model.CameraFile
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

class GalleryFilesController(
    private val scope: CoroutineScope,
    private val requestScheduler: GalleryRequestScheduler,
    private val thumbnailCache: () -> Map<Int, ByteArray>,
) {
    private val _files = MutableStateFlow<List<CameraFile>>(emptyList())
    val files: StateFlow<List<CameraFile>> = _files.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private var loadJob: Job? = null
    private var fullObjectInfoJob: Job? = null
    private var loadedSource: CameraFileSource? = null

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
                (updatedFile ?: file).copy(thumbnail = thumbnail)
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
        _files.value = emptyList()
        _isLoading.value = false
        _error.value = null
        loadedSource = null
    }

    private fun scheduleFullObjectInfoLoad(cameraSource: CameraFileSource) {
        fullObjectInfoJob?.cancel()
        fullObjectInfoJob = scope.launch(Dispatchers.IO) {
            delay(GalleryFastInitialLoadPolicy.FULL_OBJECT_INFO_AFTER_PLACEHOLDERS_DELAY_MS)
            if (loadedSource !== cameraSource) return@launch
            try {
                DiagnosticLog.append(cameraSource.context, "Gallery", "Loading full object info after initial thumbnails")
                val fileList = requestScheduler.run(GalleryRequestPriority.BackgroundMetadata) {
                    cameraSource.listFiles()
                }
                DiagnosticLog.appendFileSummary(cameraSource.context, fileList)
                _files.value = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
                    currentFiles = _files.value,
                    fullFiles = fileList,
                    thumbnailsByHandle = thumbnailCache(),
                )
            } catch (e: Exception) {
                DiagnosticLog.append(cameraSource.context, "Gallery", "Full object info background load failed", e)
            }
        }
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
    const val FULL_OBJECT_INFO_AFTER_PLACEHOLDERS_DELAY_MS = 1_000L
    private const val LARGE_GALLERY_PLACEHOLDER_COUNT = 500

    fun shouldPublishInitialFiles(currentFiles: List<CameraFile>, initialFiles: List<CameraFile>): Boolean =
        currentFiles.isEmpty() && initialFiles.isNotEmpty()

    fun shouldDeferFullObjectInfoUntilAfterThumbnails(initialFileCount: Int): Boolean =
        initialFileCount >= LARGE_GALLERY_PLACEHOLDER_COUNT

    fun shouldContinueFullObjectInfoAfterInitialPlaceholders(initialFileCount: Int): Boolean =
        initialFileCount in 1 until LARGE_GALLERY_PLACEHOLDER_COUNT

    fun shouldLoadThumbnail(
        isTransferPreparingOrActive: Boolean = false,
        isLoadingFullObjectInfo: Boolean,
        hasThumbnail: Boolean,
        activeOrPendingThumbnailCount: Int,
    ): Boolean {
        if (isTransferPreparingOrActive) return false
        if (hasThumbnail) return false
        if (isLoadingFullObjectInfo && activeOrPendingThumbnailCount >= MAX_INITIAL_THUMBNAIL_REQUESTS) {
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
        val files = if (currentFiles.size > fullFiles.size) {
            mergePartialFullObjectInfoIntoPlaceholders(
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

    private fun mergePartialFullObjectInfoIntoPlaceholders(
        currentFiles: List<CameraFile>,
        fullFiles: List<CameraFile>,
    ): List<CameraFile> {
        val fullFilesByHandle = fullFiles.associateBy { it.info.handle }
        val currentHandles = currentFiles.map { it.info.handle }.toSet()
        val mergedCurrent = currentFiles.map { file ->
            fullFilesByHandle[file.info.handle] ?: file
        }
        val extraFullFiles = fullFiles.filterNot { it.info.handle in currentHandles }
        return mergedCurrent + extraFullFiles
    }
}
