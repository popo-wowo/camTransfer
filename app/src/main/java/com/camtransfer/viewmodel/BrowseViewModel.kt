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
    private var thumbnailWorker: Job? = null
    private var loadJob: Job? = null
    private var loadedSource: CameraFileSource? = null

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
                    _files.value = initialFiles
                }
                val fileList = cameraSource.listFiles()
                DiagnosticLog.appendFileSummary(cameraSource.context, fileList)
                _files.value = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
                    currentFiles = _files.value,
                    fullFiles = fileList,
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

    fun loadThumbnail(cameraSource: CameraFileSource, handle: Int) {
        if (_files.value.any { it.info.handle == handle && it.thumbnail != null }) return
        if (!thumbnailQueue.offer(handle)) return
        if (thumbnailWorker?.isActive == true) return
        thumbnailWorker = viewModelScope.launch(Dispatchers.IO) {
            drainThumbnailQueue(cameraSource)
        }
    }

    private suspend fun drainThumbnailQueue(cameraSource: CameraFileSource) {
        while (true) {
            val handle = thumbnailQueue.poll() ?: return
            try {
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
            val thumb = cameraSource.getThumbnail(handle)
            val file = _files.value.firstOrNull { it.info.handle == handle }
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
            _files.value = _files.value.map { file ->
                if (file.info.handle == handle) file.copy(thumbnail = thumb) else file
            }
        } catch (e: Exception) {
            Log.w(TAG, "Thumbnail failed handle=$handle: $e")
            DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail failed handle=$handle", e)
        }
    }

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
        thumbnailWorker?.cancel()
        loadJob = null
        thumbnailWorker = null
        _files.value = emptyList()
        _isLoading.value = false
        _selectedHandles.value = emptySet()
        _error.value = null
        loadedSource = null
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

    fun offer(handle: Int): Boolean {
        if (!pendingHandles.add(handle)) return false
        handles.addLast(handle)
        return true
    }

    fun poll(): Int? = handles.removeFirstOrNull()

    fun finish(handle: Int) {
        pendingHandles.remove(handle)
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
    fun shouldPublishInitialFiles(currentFiles: List<CameraFile>, initialFiles: List<CameraFile>): Boolean =
        currentFiles.isEmpty() && initialFiles.isNotEmpty()

    fun mergeWithExistingThumbnails(
        currentFiles: List<CameraFile>,
        fullFiles: List<CameraFile>,
    ): List<CameraFile> {
        val thumbnailsByHandle = currentFiles.mapNotNull { file ->
            file.thumbnail?.let { file.info.handle to it }
        }.toMap()
        if (thumbnailsByHandle.isEmpty()) return fullFiles
        return fullFiles.map { file ->
            val thumbnail = thumbnailsByHandle[file.info.handle]
            if (thumbnail == null || file.thumbnail != null) file else file.copy(thumbnail = thumbnail)
        }
    }
}
