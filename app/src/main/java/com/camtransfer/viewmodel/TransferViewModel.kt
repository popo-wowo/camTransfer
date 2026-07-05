package com.camtransfer.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferDownloadMode
import com.camtransfer.model.TransferItem
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.GalleryService
import com.camtransfer.service.TransferService
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch

class TransferViewModel(app: Application) : AndroidViewModel(app) {

    private var transferService: TransferService? = null
    private var transferJob: Job? = null
    private val emptyItems = MutableStateFlow<List<TransferItem>>(emptyList())
    private val idleTransferring = MutableStateFlow(false)

    val items: StateFlow<List<TransferItem>> get() = transferService?.items ?: emptyItems
    val downloadedItems: StateFlow<List<TransferItem>> get() = transferService?.downloadedItems ?: emptyItems
    val historyItems: StateFlow<List<TransferItem>> get() = transferService?.historyItems ?: emptyItems
    val isTransferring: StateFlow<Boolean> get() = transferService?.isTransferring ?: idleTransferring

    fun init(cameraSource: CameraFileSource) {
        if (transferService != null) return
        val gallery = GalleryService(getApplication()) { cameraSource.displayName }
        transferService = TransferService(cameraSource, gallery)
    }

    fun switchSource(cameraSource: CameraFileSource) {
        val gallery = GalleryService(getApplication()) { cameraSource.displayName }
        transferService = TransferService(cameraSource, gallery)
    }

    fun startTransfer(
        files: List<CameraFile>,
        downloadMode: TransferDownloadMode = TransferDownloadMode.ORIGINAL,
        beforeStart: (suspend () -> Unit)? = null,
    ) {
        val service = transferService ?: return
        service.enqueue(files, downloadMode)
        startQueuedTransfer(downloadMode, beforeStart)
    }

    fun enqueue(
        files: List<CameraFile>,
        downloadMode: TransferDownloadMode = TransferDownloadMode.ORIGINAL,
    ) {
        val service = transferService ?: return
        service.enqueue(files, downloadMode)
    }

    fun removePending(files: List<CameraFile>) {
        val service = transferService ?: return
        service.removePending(files.map { it.info.handle }.toSet())
    }

    fun pauseTransfers(onPaused: (() -> Unit)? = null) {
        val service = transferService ?: return
        service.pauseTransfers()
        val activeJob = transferJob
        if (activeJob == null) {
            onPaused?.invoke()
            return
        }
        viewModelScope.launch {
            activeJob.cancelAndJoin()
            if (transferJob === activeJob) {
                transferJob = null
            }
            onPaused?.invoke()
        }
    }

    fun startQueuedTransfer(
        downloadMode: TransferDownloadMode = TransferDownloadMode.ORIGINAL,
        beforeStart: (suspend () -> Unit)? = null,
    ) {
        val service = transferService ?: return
        if (transferJob?.isActive == true) return
        service.updatePendingDownloadMode(downloadMode)
        val job = viewModelScope.launch {
            beforeStart?.invoke()
            service.startTransfer()
        }
        transferJob = job
        job.invokeOnCompletion {
            if (transferJob === job) {
                transferJob = null
            }
        }
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
