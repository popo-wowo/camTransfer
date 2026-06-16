package com.camtransfer.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferItem
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.GalleryService
import com.camtransfer.service.TransferService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class TransferViewModel(app: Application) : AndroidViewModel(app) {

    private var transferService: TransferService? = null
    private val emptyItems = MutableStateFlow<List<TransferItem>>(emptyList())
    private val idleTransferring = MutableStateFlow(false)

    val items: StateFlow<List<TransferItem>> get() = transferService?.items ?: emptyItems
    val downloadedItems: StateFlow<List<TransferItem>> get() = transferService?.downloadedItems ?: emptyItems
    val historyItems: StateFlow<List<TransferItem>> get() = transferService?.historyItems ?: emptyItems
    val isTransferring: StateFlow<Boolean> get() = transferService?.isTransferring ?: idleTransferring

    fun init(cameraSource: CameraFileSource) {
        if (transferService != null) return
        val gallery = GalleryService(getApplication())
        transferService = TransferService(cameraSource, gallery)
    }

    fun switchSource(cameraSource: CameraFileSource) {
        val gallery = GalleryService(getApplication())
        transferService = TransferService(cameraSource, gallery)
    }

    fun startTransfer(files: List<CameraFile>) {
        val service = transferService ?: return
        service.enqueue(files)
        viewModelScope.launch { service.startTransfer() }
    }

    fun syncDownloadedFiles(files: List<CameraFile>) {
        transferService?.syncDownloadedFiles(files)
    }

    fun clearCompleted() {
        transferService?.clearCompleted()
    }

    fun clearDownloadedCache() {
        transferService?.clearDownloadedCache()
    }
}
