package com.camtransfer.viewmodel

import android.graphics.BitmapFactory
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.DiagnosticLog
import com.camtransfer.ui.GalleryThumbnailDiagnosticPolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

class BrowseViewModel : ViewModel() {

    private val _files = MutableStateFlow<List<CameraFile>>(emptyList())
    val files: StateFlow<List<CameraFile>> = _files.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _selectedHandles = MutableStateFlow<Set<Int>>(emptySet())
    val selectedHandles: StateFlow<Set<Int>> = _selectedHandles.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val thumbnailQueue = ThumbnailLoadQueue()
    private val thumbnailWorkers = mutableSetOf<Job>()
    private val thumbnailCache = mutableMapOf<Int, ByteArray>()
    private var loadJob: Job? = null
    private var fullObjectInfoJob: Job? = null
    private var loadedSource: CameraFileSource? = null
    @Volatile
    private var thumbnailLoadingPaused = false

    fun loadFilesIfNeeded(cameraSource: CameraFileSource) {
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
        loadFiles(cameraSource)
    }

    fun loadFiles(cameraSource: CameraFileSource) {
        if (_isLoading.value) return
        _isLoading.value = true
        _error.value = null

        loadJob = viewModelScope.launch(Dispatchers.IO) {
            try {
                DiagnosticLog.append(cameraSource.context, "Gallery", "Loading file list")
                val initialFiles = cameraSource.fastInitialFiles()
                if (GalleryFastInitialLoadPolicy.shouldPublishInitialFiles(_files.value, initialFiles)) {
                    DiagnosticLog.append(cameraSource.context, "Gallery", "Fast file placeholders loaded total=${initialFiles.size}")
                    _files.value = GalleryFastInitialLoadPolicy.mergeWithCachedThumbnails(
                        files = initialFiles,
                        thumbnailsByHandle = thumbnailCache,
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
                val fileList = cameraSource.listFiles()
                DiagnosticLog.appendFileSummary(cameraSource.context, fileList)
                _files.value = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
                    currentFiles = _files.value,
                    fullFiles = fileList,
                    thumbnailsByHandle = thumbnailCache,
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

    private fun scheduleFullObjectInfoLoad(cameraSource: CameraFileSource) {
        fullObjectInfoJob?.cancel()
        fullObjectInfoJob = viewModelScope.launch(Dispatchers.IO) {
            delay(GalleryFastInitialLoadPolicy.FULL_OBJECT_INFO_AFTER_PLACEHOLDERS_DELAY_MS)
            if (loadedSource !== cameraSource) return@launch
            try {
                DiagnosticLog.append(cameraSource.context, "Gallery", "Loading full object info after initial thumbnails")
                val fileList = cameraSource.listFiles()
                DiagnosticLog.appendFileSummary(cameraSource.context, fileList)
                _files.value = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
                    currentFiles = _files.value,
                    fullFiles = fileList,
                    thumbnailsByHandle = thumbnailCache,
                )
            } catch (e: Exception) {
                DiagnosticLog.append(cameraSource.context, "Gallery", "Full object info background load failed", e)
            }
        }
    }

    fun loadThumbnail(cameraSource: CameraFileSource, handle: Int) {
        if (!GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isTransferPreparingOrActive = thumbnailLoadingPaused,
                isLoadingFullObjectInfo = _isLoading.value,
                hasThumbnail = _files.value.any { it.info.handle == handle && it.thumbnail != null },
                activeOrPendingThumbnailCount = activeOrPendingThumbnailCount(),
            )
        ) {
            return
        }
        if (_files.value.any { it.info.handle == handle && it.thumbnail != null }) return
        if (!thumbnailQueue.offer(handle)) return
        startThumbnailWorkers(cameraSource)
    }

    fun loadVisibleThumbnails(cameraSource: CameraFileSource, handles: List<Int>) {
        if (thumbnailLoadingPaused) return
        if (handles.isEmpty()) return
        val visibleHandles = handles.toSet()
        thumbnailQueue.retain(visibleHandles)
        handles.forEach { handle -> loadThumbnail(cameraSource, handle) }
    }

    fun loadPreviewThumbnails(cameraSource: CameraFileSource, handles: List<Int>) {
        if (thumbnailLoadingPaused) return
        if (handles.isEmpty()) return
        handles.forEach { handle -> loadPreviewThumbnail(cameraSource, handle) }
        thumbnailQueue.protect(handles.toSet())
        startThumbnailWorkers(cameraSource)
    }

    private fun loadPreviewThumbnail(cameraSource: CameraFileSource, handle: Int) {
        if (!GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isTransferPreparingOrActive = thumbnailLoadingPaused,
                isLoadingFullObjectInfo = _isLoading.value,
                hasThumbnail = _files.value.any { it.info.handle == handle && it.thumbnail != null },
                activeOrPendingThumbnailCount = activeOrPendingThumbnailCount(),
            )
        ) {
            return
        }
        if (_files.value.any { it.info.handle == handle && it.thumbnail != null }) return
        if (!thumbnailQueue.offerProtected(handle)) {
            thumbnailQueue.protect(setOf(handle))
        }
    }

    private fun startThumbnailWorkers(cameraSource: CameraFileSource) {
        thumbnailWorkers.removeAll { !it.isActive }
        while (ThumbnailLoadPolicy.shouldStartWorker(
                activeWorkers = thumbnailWorkers.count { it.isActive },
                pendingHandles = thumbnailQueue.pendingCount,
            )
        ) {
            val worker = viewModelScope.launch(Dispatchers.IO) {
                drainThumbnailQueue(cameraSource)
            }
            thumbnailWorkers.add(worker)
        }
    }

    private suspend fun drainThumbnailQueue(cameraSource: CameraFileSource) {
        while (true) {
            val handle = thumbnailQueue.poll() ?: return
            try {
                if (thumbnailLoadingPaused) return
                loadThumbnailNow(cameraSource, handle)
            } finally {
                thumbnailQueue.finish(handle)
            }
            yield()
        }
    }

    private suspend fun loadThumbnailNow(cameraSource: CameraFileSource, handle: Int) {
        if (_files.value.any { it.info.handle == handle && it.thumbnail != null }) return
        Log.d(TAG, "Thumbnail request handle=$handle")
        DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail request handle=$handle")
        try {
            val thumbnail = cameraSource.getThumbnailWithInfo(handle)
            val thumb = thumbnail.data
            val file = thumbnail.file ?: _files.value.firstOrNull { it.info.handle == handle }
            val decodedSize = thumb.decodedBounds()
            val thumbnailSummary = GalleryThumbnailDiagnosticPolicy.summary(
                handle = handle,
                file = file,
                thumbnail = thumb,
                decodedWidth = decodedSize.width,
                decodedHeight = decodedSize.height,
            )
            Log.d(TAG, thumbnailSummary)
            DiagnosticLog.append(cameraSource.context, TAG, thumbnailSummary)
            thumbnailCache[handle] = thumb
            _files.value = _files.value.map { file ->
                if (file.info.handle == handle) {
                    (thumbnail.file ?: file).copy(thumbnail = thumb)
                } else {
                    file
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Thumbnail failed handle=$handle: $e")
            DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail failed handle=$handle", e)
        }
    }

    private fun activeOrPendingThumbnailCount(): Int =
        thumbnailQueue.trackedCount

    private fun ByteArray.decodedBounds(): ThumbnailDecodedBounds {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(this, 0, size, options)
        return ThumbnailDecodedBounds(
            width = options.outWidth,
            height = options.outHeight,
        )
    }

    fun toggleSelection(handle: Int) {
        val current = _selectedHandles.value.toMutableSet()
        if (handle in current) current.remove(handle) else current.add(handle)
        _selectedHandles.value = current
    }

    fun selectAll() {
        _selectedHandles.value = _files.value.map { it.info.handle }.toSet()
    }

    fun selectHandles(handles: Set<Int>) {
        _selectedHandles.value = handles
    }

    fun clearSelection() {
        _selectedHandles.value = emptySet()
    }

    fun reset() {
        loadJob?.cancel()
        fullObjectInfoJob?.cancel()
        thumbnailWorkers.forEach { it.cancel() }
        loadJob = null
        fullObjectInfoJob = null
        thumbnailWorkers.clear()
        thumbnailCache.clear()
        _files.value = emptyList()
        _isLoading.value = false
        _selectedHandles.value = emptySet()
        _error.value = null
        loadedSource = null
    }

    suspend fun prepareThumbnailLoadingForTransfer(cameraSource: CameraFileSource) {
        thumbnailLoadingPaused = true
        thumbnailQueue.clear()
        val workers = thumbnailWorkers.toList()
        workers.forEach { it.cancel() }
        workers.forEach { it.join() }
        thumbnailWorkers.clear()
        DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail loading paused for transfer")
    }

    fun resumeThumbnailLoadingAfterTransfer(cameraSource: CameraFileSource) {
        if (!thumbnailLoadingPaused) return
        thumbnailLoadingPaused = false
        DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail loading resumed after transfer")
    }

    fun getSelectedFiles(): List<CameraFile> {
        val selected = _selectedHandles.value
        return _files.value.filter { it.info.handle in selected }
    }

    private companion object {
        const val TAG = "BrowseViewModel"
    }
}

private data class ThumbnailDecodedBounds(
    val width: Int,
    val height: Int,
)

internal class ThumbnailLoadQueue {
    private val handles = ArrayDeque<Int>()
    private val pendingHandles = mutableSetOf<Int>()
    private val protectedHandles = mutableSetOf<Int>()

    val pendingCount: Int
        @Synchronized get() = handles.size

    val trackedCount: Int
        @Synchronized get() = pendingHandles.size

    @Synchronized
    fun offer(handle: Int): Boolean {
        if (!pendingHandles.add(handle)) return false
        handles.addLast(handle)
        return true
    }

    @Synchronized
    fun offerProtected(handle: Int): Boolean {
        if (!offer(handle)) return false
        protectedHandles.add(handle)
        return true
    }

    @Synchronized
    fun poll(): Int? = handles.removeFirstOrNull()

    @Synchronized
    fun finish(handle: Int) {
        pendingHandles.remove(handle)
        protectedHandles.remove(handle)
    }

    @Synchronized
    fun protect(handles: Set<Int>) {
        protectedHandles.addAll(handles.filter { it in pendingHandles })
    }

    @Synchronized
    fun retain(allowedHandles: Set<Int>) {
        if (allowedHandles.isEmpty()) return
        val retainedAllowedHandles = allowedHandles + protectedHandles
        val retainedHandles = handles.filter { it in retainedAllowedHandles }
        handles.clear()
        retainedHandles.forEach { handles.addLast(it) }
        pendingHandles.retainAll(retainedAllowedHandles)
        protectedHandles.retainAll(pendingHandles)
    }

    @Synchronized
    fun clear() {
        handles.clear()
        pendingHandles.clear()
        protectedHandles.clear()
    }
}

internal object ThumbnailLoadPolicy {
    const val MAX_CONCURRENT_WORKERS = 1

    fun shouldStartWorker(activeWorkers: Int, pendingHandles: Int): Boolean =
        pendingHandles > 0 && activeWorkers < MAX_CONCURRENT_WORKERS
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
