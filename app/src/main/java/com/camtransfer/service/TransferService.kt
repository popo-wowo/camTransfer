package com.camtransfer.service

import android.content.Context
import android.util.Log
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferItem
import com.camtransfer.model.TransferState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

private const val TAG = "TransferService"

class TransferService(
    private val cameraService: CameraService,
    private val galleryService: GalleryService,
) {
    private val _items = MutableStateFlow<List<TransferItem>>(emptyList())
    val items: StateFlow<List<TransferItem>> = _items.asStateFlow()

    private val _isTransferring = MutableStateFlow(false)
    val isTransferring: StateFlow<Boolean> = _isTransferring.asStateFlow()

    fun enqueue(files: List<CameraFile>) {
        val newItems = files.map { TransferItem(file = it) }
        _items.value = _items.value + newItems
    }

    suspend fun startTransfer() {
        if (_isTransferring.value) return
        _isTransferring.value = true

        val current = _items.value.toMutableList()
        for (i in current.indices) {
            val item = current[i]
            if (item.state != TransferState.PENDING) continue

            current[i] = item.copy(state = TransferState.DOWNLOADING, progress = 0f)
            _items.value = current.toList()

            try {
                val data = cameraService.getFile(item.file.info.handle)

                current[i] = item.copy(state = TransferState.SAVING, progress = 0.9f)
                _items.value = current.toList()

                val saved = galleryService.saveToGallery(item.file.info, data)
                current[i] = item.copy(
                    state = if (saved) TransferState.DONE else TransferState.ERROR,
                    progress = if (saved) 1f else 0.9f,
                    error = if (!saved) "保存失败" else null
                )
                _items.value = current.toList()

                Log.d(TAG, "${item.file.info.filename}: ${if (saved) "done" else "save failed"}")
            } catch (e: Exception) {
                current[i] = item.copy(state = TransferState.ERROR, error = e.message)
                _items.value = current.toList()
                Log.e(TAG, "Transfer failed: ${item.file.info.filename}", e)
            }
        }

        _isTransferring.value = false
    }

    fun clearCompleted() {
        _items.value = _items.value.filter { it.state != TransferState.DONE }
    }
}
