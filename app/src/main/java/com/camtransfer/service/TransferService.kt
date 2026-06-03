package com.camtransfer.service

import android.content.Context
import android.util.Log
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferItem
import com.camtransfer.model.TransferState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

private const val TAG = "TransferService"

class TransferService(
    private val cameraSource: CameraFileSource,
    private val galleryService: GalleryService,
    private val downloadedFileStore: DownloadedFileStore = DownloadedFileStore(galleryService.context),
) {
    private val _items = MutableStateFlow<List<TransferItem>>(emptyList())
    val items: StateFlow<List<TransferItem>> = _items.asStateFlow()

    private val _downloadedItems = MutableStateFlow<List<TransferItem>>(emptyList())
    val downloadedItems: StateFlow<List<TransferItem>> = _downloadedItems.asStateFlow()

    private val _isTransferring = MutableStateFlow(false)
    val isTransferring: StateFlow<Boolean> = _isTransferring.asStateFlow()

    fun enqueue(files: List<CameraFile>) {
        val retryFilesByHandle = files.associateBy { it.info.handle }
        val resetItems = _items.value.map { item ->
            val retryFile = retryFilesByHandle[item.file.info.handle]
            when {
                retryFile != null && downloadedFileStore.isDownloaded(retryFile) -> {
                    item.copy(file = retryFile, state = TransferState.DONE, progress = 1f, error = null)
                }
                retryFile != null && item.state == TransferState.ERROR -> {
                    item.copy(file = retryFile, state = TransferState.PENDING, progress = 0f, error = null)
                }
                else -> item
            }
        }
        val existingHandles = resetItems.map { it.file.info.handle }.toSet()
        val newItems = files
            .distinctBy { it.info.handle }
            .filterNot { it.info.handle in existingHandles }
            .filterNot { downloadedFileStore.isDownloaded(it) }
            .map { TransferItem(file = it) }
        _items.value = resetItems + newItems
    }

    fun syncDownloadedFiles(files: List<CameraFile>) {
        val currentFilesByHandle = files.associateBy { it.info.handle }
        _downloadedItems.value = downloadedFileStore.downloadedFiles(files)
            .map { TransferItem(file = it, state = TransferState.DONE, progress = 1f) }

        _items.value = _items.value.mapNotNull { item ->
            val currentFile = currentFilesByHandle[item.file.info.handle]
            when {
                currentFile == null -> item
                downloadedFileStore.isDownloaded(currentFile) -> {
                    item.copy(file = currentFile, state = TransferState.DONE, progress = 1f, error = null)
                }
                item.state == TransferState.DONE && !downloadedFileStore.isDownloaded(currentFile) -> null
                else -> item.copy(file = currentFile)
            }
        }
    }

    suspend fun startTransfer() {
        if (_isTransferring.value) return
        if (_items.value.none { it.state == TransferState.PENDING }) {
            Log.d(TAG, "startTransfer ignored: no pending items")
            DiagnosticLog.append(galleryService.context, TAG, "startTransfer ignored: no pending items")
            return
        }
        DiagnosticLog.append(galleryService.context, TAG, "Transfer started pending=${_items.value.count { it.state == TransferState.PENDING }}")
        _isTransferring.value = true

        val current = _items.value.toMutableList()
        for (i in current.indices) {
            val item = current[i]
            if (item.state != TransferState.PENDING) continue

            current[i] = item.copy(state = TransferState.DOWNLOADING, progress = 0f)
            _items.value = current.toList()

            try {
                Log.d(
                    TAG,
                    "Download start handle=${item.file.info.handle} " +
                        "filename=${item.file.info.filename} expected=${item.file.info.compressedSize}",
                )
                DiagnosticLog.append(
                    galleryService.context,
                    TAG,
                    "Download start handle=${item.file.info.handle} " +
                        "format=${item.file.info.formatLabel} expected=${item.file.info.compressedSize}",
                )
                val data = withContext(Dispatchers.IO) {
                    cameraSource.getFile(item.file.info.handle)
                }
                Log.d(
                    TAG,
                    "Download finished handle=${item.file.info.handle} bytes=${data.size}",
                )
                DiagnosticLog.append(
                    galleryService.context,
                    TAG,
                    "Download finished handle=${item.file.info.handle} bytes=${data.size}",
                )

                current[i] = item.copy(state = TransferState.SAVING, progress = 0.9f)
                _items.value = current.toList()

                val saved = withContext(Dispatchers.IO) {
                    galleryService.saveToGallery(item.file.info, data)
                }
                if (saved) {
                    downloadedFileStore.markDownloaded(item.file)
                    markDownloadedInGalleryState(item.file)
                }
                current[i] = item.copy(
                    state = if (saved) TransferState.DONE else TransferState.ERROR,
                    progress = if (saved) 1f else 0.9f,
                    error = if (!saved) "保存失败" else null
                )
                _items.value = current.toList()

                Log.d(TAG, "${item.file.info.filename}: ${if (saved) "done" else "save failed"}")
                DiagnosticLog.append(
                    galleryService.context,
                    TAG,
                    "Save result handle=${item.file.info.handle} result=${if (saved) "done" else "failed"}",
                )
            } catch (e: Exception) {
                current[i] = item.copy(state = TransferState.ERROR, error = e.message)
                _items.value = current.toList()
                Log.e(TAG, "Transfer failed: ${item.file.info.filename}", e)
                DiagnosticLog.append(galleryService.context, TAG, "Transfer failed handle=${item.file.info.handle}", e)
            }
        }

        _isTransferring.value = false
        DiagnosticLog.append(galleryService.context, TAG, "Transfer finished")
    }

    fun clearCompleted() {
        _items.value = _items.value.filter { it.state != TransferState.DONE }
    }

    fun clearDownloadedCache() {
        downloadedFileStore.clear()
        _downloadedItems.value = emptyList()
        _items.value = _items.value.filter { it.state != TransferState.DONE }
        DiagnosticLog.append(galleryService.context, TAG, "Downloaded cache cleared")
    }

    private fun markDownloadedInGalleryState(file: CameraFile) {
        val current = _downloadedItems.value
        val updatedItem = TransferItem(file = file, state = TransferState.DONE, progress = 1f)
        _downloadedItems.value = if (current.any { it.file.info.handle == file.info.handle }) {
            current.map { item ->
                if (item.file.info.handle == file.info.handle) updatedItem else item
            }
        } else {
            current + updatedItem
        }
    }
}
