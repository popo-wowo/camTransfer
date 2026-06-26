package com.camtransfer.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraFileSource
import com.camtransfer.viewmodel.gallery.GalleryFilesController
import com.camtransfer.viewmodel.gallery.GalleryPreviewController
import com.camtransfer.viewmodel.gallery.GalleryRequestScheduler
import com.camtransfer.viewmodel.gallery.GallerySelectionController
import com.camtransfer.viewmodel.gallery.GalleryThumbnailController

class BrowseViewModel : ViewModel() {

    private val requestScheduler = GalleryRequestScheduler()
    private val selectionController = GallerySelectionController()
    private var thumbnailCacheProvider: () -> Map<Int, ByteArray> = { emptyMap() }
    private val filesController = GalleryFilesController(
        scope = viewModelScope,
        requestScheduler = requestScheduler,
        thumbnailCache = { thumbnailCacheProvider() },
    )
    private val thumbnailController = GalleryThumbnailController(
        scope = viewModelScope,
        requestScheduler = requestScheduler,
        filesController = filesController,
    )
    private val previewController = GalleryPreviewController(
        scope = viewModelScope,
        requestScheduler = requestScheduler,
        thumbnailController = thumbnailController,
    )

    val files = filesController.files
    val isLoading = filesController.isLoading
    val isLoadingHiddenFormats = filesController.isLoadingHiddenFormats
    val selectedHandles = selectionController.selectedHandles
    val previewImages = previewController.previewImages
    val error = filesController.error

    init {
        thumbnailCacheProvider = thumbnailController::cachedThumbnails
    }

    fun loadFilesIfNeeded(cameraSource: CameraFileSource) {
        filesController.loadIfNeeded(cameraSource)
    }

    fun loadFiles(cameraSource: CameraFileSource) {
        filesController.load(cameraSource)
    }

    fun loadThumbnail(cameraSource: CameraFileSource, handle: Int) {
        thumbnailController.loadThumbnail(cameraSource, handle)
    }

    fun loadVisibleThumbnails(cameraSource: CameraFileSource, handles: List<Int>) {
        thumbnailController.loadVisibleThumbnails(cameraSource, handles)
    }

    fun loadPreviewThumbnails(cameraSource: CameraFileSource, handles: List<Int>) {
        thumbnailController.loadPreviewThumbnails(cameraSource, handles)
    }

    fun loadPreviewImage(cameraSource: CameraFileSource, file: CameraFile) {
        previewController.loadPreviewImage(cameraSource, file)
    }

    fun toggleSelection(handle: Int) {
        selectionController.toggle(handle)
    }

    fun selectAll() {
        selectionController.selectAll(files.value)
    }

    fun selectHandles(handles: Set<Int>) {
        selectionController.selectHandles(handles)
    }

    fun clearSelection() {
        selectionController.clear()
    }

    fun reset() {
        filesController.reset()
        thumbnailController.reset()
        previewController.reset()
        selectionController.clear()
    }

    suspend fun prepareThumbnailLoadingForTransfer(cameraSource: CameraFileSource) {
        filesController.pauseForExclusiveOperation(cameraSource, reason = "transfer")
        thumbnailController.pauseForExclusiveOperation(cameraSource, reason = "transfer")
    }

    fun resumeThumbnailLoadingAfterTransfer(cameraSource: CameraFileSource) {
        filesController.resumeAfterExclusiveOperation(cameraSource, reason = "transfer")
        thumbnailController.resumeAfterExclusiveOperation(cameraSource, reason = "transfer")
    }

    fun getSelectedFiles(): List<CameraFile> =
        selectionController.selectedFiles(files.value)
}
