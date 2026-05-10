package com.camtransfer.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferItem
import com.camtransfer.service.CameraService
import com.camtransfer.service.GalleryService
import com.camtransfer.service.TransferService
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class TransferViewModel(app: Application) : AndroidViewModel(app) {

    private var transferService: TransferService? = null

    val items: StateFlow<List<TransferItem>>? get() = transferService?.items
    val isTransferring: StateFlow<Boolean>? get() = transferService?.isTransferring

    fun init(cameraService: CameraService) {
        if (transferService != null) return
        val gallery = GalleryService(getApplication())
        transferService = TransferService(cameraService, gallery)
    }

    fun startTransfer(files: List<CameraFile>) {
        val service = transferService ?: return
        service.enqueue(files)
        viewModelScope.launch { service.startTransfer() }
    }

    fun clearCompleted() {
        transferService?.clearCompleted()
    }
}
