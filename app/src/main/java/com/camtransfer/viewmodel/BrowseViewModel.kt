package com.camtransfer.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.DiagnosticLog
import com.camtransfer.viewmodel.gallery.GalleryBrowseMode
import com.camtransfer.viewmodel.gallery.GalleryBrowseModeController
import com.camtransfer.viewmodel.gallery.GalleryFilesController
import com.camtransfer.viewmodel.gallery.GalleryMetadataStore
import com.camtransfer.viewmodel.gallery.GalleryPreviewController
import com.camtransfer.viewmodel.gallery.GalleryPreviewStore
import com.camtransfer.viewmodel.gallery.GallerySelectionController
import com.camtransfer.viewmodel.gallery.GallerySessionActor
import com.camtransfer.viewmodel.gallery.GalleryThumbnailController
import com.camtransfer.viewmodel.gallery.GalleryThumbnailStore
import com.camtransfer.viewmodel.gallery.HighDefinitionPreviewSessionPolicy
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.time.LocalDate

class BrowseViewModel : ViewModel() {

    private val sessionActor = GallerySessionActor()
    private val browseModeController = GalleryBrowseModeController()
    private val selectionController = GallerySelectionController()
    private val thumbnailStore = GalleryThumbnailStore()
    private val metadataStore = GalleryMetadataStore()
    private val previewStore = GalleryPreviewStore()
    private var hasActiveThumbnailWorkProvider: () -> Boolean = { false }
    private var highDefinitionPreviewPrepareJob: Job? = null
    private var highDefinitionPreviewPausedSource: CameraFileSource? = null
    private val filesController = GalleryFilesController(
        scope = viewModelScope,
        sessionActor = sessionActor,
        metadataStore = metadataStore,
        hasActiveThumbnailWork = { hasActiveThumbnailWorkProvider() },
    )
    private val thumbnailController = GalleryThumbnailController(
        scope = viewModelScope,
        sessionActor = sessionActor,
        filesController = filesController,
        thumbnailStore = thumbnailStore,
        metadataStore = metadataStore,
    )
    private val previewController = GalleryPreviewController(
        scope = viewModelScope,
        sessionActor = sessionActor,
        thumbnailController = thumbnailController,
        previewStore = previewStore,
    )

    val files = filesController.files
    val isLoading = filesController.isLoading
    val isLoadingHiddenFormats = filesController.isLoadingHiddenFormats
    val browseModeState = browseModeController.state
    val selectedHandles = selectionController.selectedHandles
    val thumbnailsByHandle = thumbnailStore.thumbnails
    val objectInfoByHandle = metadataStore.objectInfoByHandle
    val previewImages = previewController.previewImages
    val loadedPreviewHandles = previewController.loadedPreviewHandles
    val loadingPreviewHandles = previewController.loadingPreviewHandles
    val failedPreviewHandles = previewController.failedPreviewHandles
    val error = filesController.error

    init {
        hasActiveThumbnailWorkProvider = thumbnailController::hasActiveThumbnailWork
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

    fun requestPreviewImage(cameraSource: CameraFileSource, file: CameraFile) {
        previewController.loadPreviewImage(cameraSource, file, force = true)
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

    fun setBrowseMode(
        cameraSource: CameraFileSource,
        mode: GalleryBrowseMode,
    ) {
        browseModeController.setMode(mode)
        when (mode) {
            GalleryBrowseMode.THUMBNAIL -> {
                highDefinitionPreviewPrepareJob?.cancel()
                highDefinitionPreviewPrepareJob = null
                previewController.stopSession()
                resumeGalleryLoadingAfterHighDefinitionPreview(cameraSource)
            }
            GalleryBrowseMode.HD_PREVIEW -> prepareHighDefinitionPreviewSession(cameraSource)
        }
    }

    fun setHighDefinitionPreviewDate(
        cameraSource: CameraFileSource,
        date: LocalDate,
    ) {
        browseModeController.setHighDefinitionDate(date)
        if (browseModeState.value.mode == GalleryBrowseMode.HD_PREVIEW) {
            prepareHighDefinitionPreviewSession(cameraSource)
        }
    }

    fun syncHighDefinitionSession(cameraSource: CameraFileSource) {
        if (browseModeState.value.mode != GalleryBrowseMode.HD_PREVIEW) return
        prepareHighDefinitionPreviewSession(cameraSource)
    }

    fun clearHighDefinitionPreviewSessionCache(
        cameraSource: CameraFileSource,
        reason: String,
    ) {
        highDefinitionPreviewPrepareJob?.cancel()
        highDefinitionPreviewPrepareJob = null
        previewController.clearSessionPreviewCache(cameraSource, reason)
    }

    fun prioritizeHighDefinitionPreviewVisibleHandles(
        cameraSource: CameraFileSource,
        visibleHandles: List<Int>,
    ) {
        if (browseModeState.value.mode != GalleryBrowseMode.HD_PREVIEW) return
        previewController.prioritizeSessionVisibleHandles(cameraSource, visibleHandles)
    }

    private fun prepareHighDefinitionPreviewSession(cameraSource: CameraFileSource) {
        if (highDefinitionPreviewPrepareJob?.isActive == true) return
        highDefinitionPreviewPrepareJob = viewModelScope.launch {
            pauseGalleryLoadingForHighDefinitionPreview(cameraSource)
            if (browseModeState.value.mode != GalleryBrowseMode.HD_PREVIEW) return@launch
            startHighDefinitionPreviewSession(cameraSource)
        }
    }

    private suspend fun pauseGalleryLoadingForHighDefinitionPreview(cameraSource: CameraFileSource) {
        if (highDefinitionPreviewPausedSource === cameraSource) return
        highDefinitionPreviewPausedSource?.let { previousSource ->
            filesController.resumeAfterExclusiveOperation(previousSource, reason = "hd-preview")
            thumbnailController.resumeAfterExclusiveOperation(previousSource, reason = "hd-preview")
        }
        filesController.pauseForExclusiveOperation(cameraSource, reason = "hd-preview")
        thumbnailController.pauseForExclusiveOperation(cameraSource, reason = "hd-preview")
        highDefinitionPreviewPausedSource = cameraSource
    }

    private fun resumeGalleryLoadingAfterHighDefinitionPreview(cameraSource: CameraFileSource) {
        if (highDefinitionPreviewPausedSource !== cameraSource) return
        highDefinitionPreviewPausedSource = null
        filesController.resumeAfterExclusiveOperation(cameraSource, reason = "hd-preview")
        thumbnailController.resumeAfterExclusiveOperation(cameraSource, reason = "hd-preview")
    }

    private fun startHighDefinitionPreviewSession(cameraSource: CameraFileSource) {
        val session = HighDefinitionPreviewSessionPolicy.build(
            files = files.value,
            activeDate = browseModeState.value.highDefinitionDate,
        )
        val items = HighDefinitionPreviewSessionPolicy.previewItemsForDate(
            files = files.value,
            activeDate = browseModeState.value.highDefinitionDate,
        )
        DiagnosticLog.append(
            cameraSource.context,
            "GalleryPreviewController",
            "HD preview session date=${browseModeState.value.highDefinitionDate} " +
                "items=${items.size} rawSidecars=${items.count { it.rawFile != null }} " +
                "previewHandles=${items.take(8).joinToString { it.previewFile.info.handle.toString() }} " +
                "rawPairs=${items.take(8).joinToString { item ->
                    val previewHints = item.previewFile.formatHints.joinToString("|").ifBlank { "-" }
                    val rawHints = item.rawFile?.formatHints?.joinToString("|")?.ifBlank { "-" } ?: "-"
                    "${item.previewFile.info.handle}[$previewHints]->${item.rawFile?.info?.handle ?: 0}[$rawHints]"
                }} " +
                "totalFiles=${files.value.size}",
        )
        previewController.startOrReplaceSession(cameraSource, session)
    }

    fun reset() {
        highDefinitionPreviewPrepareJob?.cancel()
        highDefinitionPreviewPrepareJob = null
        highDefinitionPreviewPausedSource = null
        browseModeController.reset()
        filesController.reset()
        thumbnailController.reset()
        previewController.reset()
        selectionController.clear()
    }

    suspend fun prepareGalleryLoadingForTransfer(cameraSource: CameraFileSource) {
        sessionActor.enterTransferExclusive()
        filesController.pauseForExclusiveOperation(cameraSource, reason = "transfer")
        thumbnailController.pauseForExclusiveOperation(cameraSource, reason = "transfer")
        previewController.pauseForExclusiveOperation(cameraSource, reason = "transfer")
    }

    fun resumeGalleryLoadingAfterTransfer(cameraSource: CameraFileSource) {
        sessionActor.exitTransferExclusive()
        if (browseModeState.value.mode != GalleryBrowseMode.HD_PREVIEW) {
            filesController.resumeAfterExclusiveOperation(cameraSource, reason = "transfer")
        }
        thumbnailController.resumeAfterExclusiveOperation(cameraSource, reason = "transfer")
        previewController.resumeAfterExclusiveOperation(
            cameraSource = cameraSource,
            reason = "transfer",
            shouldResumeSequentialSession = browseModeState.value.mode == GalleryBrowseMode.HD_PREVIEW,
        )
    }

    fun getSelectedFiles(): List<CameraFile> =
        selectionController.selectedFiles(files.value)
}
