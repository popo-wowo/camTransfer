package com.camtransfer.viewmodel.gallery

import android.graphics.BitmapFactory
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import java.io.File
import java.util.LinkedHashMap

class GalleryPreviewController(
    private val scope: CoroutineScope,
    private val requestScheduler: GalleryRequestScheduler,
    private val thumbnailController: GalleryThumbnailController,
) {
    private val previewImageCache = LinkedHashMap<Int, ByteArray>()
    private val _previewImages = MutableStateFlow<Map<Int, ByteArray>>(emptyMap())
    val previewImages: StateFlow<Map<Int, ByteArray>> = _previewImages.asStateFlow()
    private val _loadedPreviewHandles = MutableStateFlow<Set<Int>>(emptySet())
    val loadedPreviewHandles: StateFlow<Set<Int>> = _loadedPreviewHandles.asStateFlow()
    private val _loadingPreviewHandles = MutableStateFlow<Set<Int>>(emptySet())
    val loadingPreviewHandles: StateFlow<Set<Int>> = _loadingPreviewHandles.asStateFlow()
    private val _failedPreviewHandles = MutableStateFlow<Set<Int>>(emptySet())
    val failedPreviewHandles: StateFlow<Set<Int>> = _failedPreviewHandles.asStateFlow()

    private var manualPreviewJob: Job? = null
    private var sessionPreviewJob: Job? = null

    @Volatile
    private var pendingPreviewFile: CameraFile? = null

    @Volatile
    private var activeSession: HighDefinitionPreviewSession? = null

    private val previewPauseLock = Any()
    private val currentReadLock = Any()
    private var exclusivePreviewPauseCount = 0

    @Volatile
    private var previewLoadingPaused = false

    @Volatile
    private var currentReadGate: CompletableDeferred<Unit>? = null

    fun loadPreviewImage(
        cameraSource: CameraFileSource,
        file: CameraFile,
        force: Boolean = false,
    ) {
        val handle = file.info.handle
        if (previewLoadingPaused) return
        if (!GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(
                file = file,
                hasPreviewImage = previewImageCache.containsKey(handle),
                isAlreadyLoading = handle in _loadingPreviewHandles.value,
                force = force,
            )
        ) {
            return
        }
        pendingPreviewFile = file
        _loadingPreviewHandles.value = _loadingPreviewHandles.value + handle
        if (manualPreviewJob?.isActive == true) return
        manualPreviewJob = scope.launch(Dispatchers.IO) {
            while (true) {
                if (previewLoadingPaused) return@launch
                val nextFile = pendingPreviewFile ?: return@launch
                pendingPreviewFile = null
                loadPreviewImageNow(cameraSource, nextFile)
                yield()
            }
        }
    }

    fun startOrReplaceSession(
        cameraSource: CameraFileSource,
        session: HighDefinitionPreviewSession,
    ) {
        activeSession = session.copy(
            failedHandles = _failedPreviewHandles.value.intersect(session.files.map { it.info.handle }.toSet()),
        )
        _failedPreviewHandles.value = _failedPreviewHandles.value.intersect(session.files.map { it.info.handle }.toSet())
        if (previewLoadingPaused) return
        startSessionWorker(cameraSource)
    }

    fun prioritizeSessionVisibleHandles(
        cameraSource: CameraFileSource,
        visibleHandles: List<Int>,
    ) {
        if (visibleHandles.isEmpty()) return
        val previousSession = activeSession ?: return
        val nextSession = previousSession.prioritizeVisibleHandles(
            visibleHandles = visibleHandles,
            loadedHandles = _loadedPreviewHandles.value,
            loadingHandles = _loadingPreviewHandles.value,
        )
        activeSession = nextSession
        restoreActiveWindowPreviewImages(cameraSource, nextSession.activeWindowHandleSet())
        if (nextSession.currentIndex != previousSession.currentIndex) {
            DiagnosticLog.append(
                cameraSource.context,
                TAG,
                "HD preview priority visible=${visibleHandles.take(6).joinToString()} " +
                    "next=${nextSession.files.getOrNull(nextSession.currentIndex)?.info?.handle ?: "none"}",
            )
        }
        if (!previewLoadingPaused) {
            startSessionWorker(cameraSource)
        }
    }

    fun stopSession() {
        sessionPreviewJob?.cancel()
        sessionPreviewJob = null
    }

    suspend fun awaitIdleOrCurrentReadComplete() {
        currentReadGate?.await()
    }

    suspend fun pauseForExclusiveOperation(
        cameraSource: CameraFileSource,
        reason: String,
    ) {
        val jobsToJoin = synchronized(previewPauseLock) {
            exclusivePreviewPauseCount += 1
            previewLoadingPaused = true
            pendingPreviewFile = null
            activeSession = activeSession?.pauseForTransfer()
            listOfNotNull(
                manualPreviewJob?.also { it.cancel() },
                sessionPreviewJob?.also { it.cancel() },
            ).also {
                manualPreviewJob = null
                sessionPreviewJob = null
            }
        }
        awaitIdleOrCurrentReadComplete()
        jobsToJoin.forEach { it.join() }
        DiagnosticLog.append(
            cameraSource.context,
            TAG,
            "Preview loading paused reason=$reason count=$exclusivePreviewPauseCount",
        )
    }

    fun resumeAfterExclusiveOperation(
        cameraSource: CameraFileSource,
        reason: String,
        shouldResumeSequentialSession: Boolean,
    ) {
        val pauseCount = synchronized(previewPauseLock) {
            if (exclusivePreviewPauseCount == 0) return
            exclusivePreviewPauseCount -= 1
            previewLoadingPaused = exclusivePreviewPauseCount > 0
            if (!previewLoadingPaused && shouldResumeSequentialSession) {
                activeSession = activeSession?.resumeAfterTransfer()
            }
            exclusivePreviewPauseCount
        }
        DiagnosticLog.append(
            cameraSource.context,
            TAG,
            "Preview loading resume reason=$reason count=$pauseCount paused=$previewLoadingPaused",
        )
        if (!previewLoadingPaused && shouldResumeSequentialSession) {
            startSessionWorker(cameraSource)
        }
    }

    fun reset() {
        manualPreviewJob?.cancel()
        sessionPreviewJob?.cancel()
        manualPreviewJob = null
        sessionPreviewJob = null
        previewImageCache.clear()
        pendingPreviewFile = null
        activeSession = null
        synchronized(previewPauseLock) {
            exclusivePreviewPauseCount = 0
            previewLoadingPaused = false
        }
        synchronized(currentReadLock) {
            currentReadGate?.complete(Unit)
            currentReadGate = null
        }
        _previewImages.value = emptyMap()
        _loadedPreviewHandles.value = emptySet()
        _loadingPreviewHandles.value = emptySet()
        _failedPreviewHandles.value = emptySet()
    }

    private fun startSessionWorker(cameraSource: CameraFileSource) {
        if (sessionPreviewJob?.isActive == true) return
        sessionPreviewJob = scope.launch(Dispatchers.IO) {
            while (true) {
                if (previewLoadingPaused) return@launch
                val session = activeSession ?: return@launch
                if (session.pausedForTransfer) return@launch
                val nextFile = session.nextFile(
                    loadedHandles = _loadedPreviewHandles.value,
                    loadingHandles = _loadingPreviewHandles.value,
                ) ?: return@launch
                val handle = nextFile.info.handle
                _loadingPreviewHandles.value = _loadingPreviewHandles.value + handle
                loadPreviewImageNow(
                    cameraSource = cameraSource,
                    file = nextFile,
                    onSuccess = { loadedHandle ->
                        activeSession = activeSession?.markLoaded(loadedHandle)
                    },
                    onFailure = { failedHandle ->
                        _failedPreviewHandles.value = _failedPreviewHandles.value + failedHandle
                        activeSession = activeSession?.markFailed(failedHandle)
                    },
                )
                yield()
            }
        }
    }

    private suspend fun loadPreviewImageNow(
        cameraSource: CameraFileSource,
        file: CameraFile,
        onSuccess: (Int) -> Unit = {},
        onFailure: (Int) -> Unit = {},
    ) {
        val handle = file.info.handle
        if (previewImageCache.containsKey(handle)) {
            _loadingPreviewHandles.value = _loadingPreviewHandles.value - handle
            onSuccess(handle)
            return
        }
        DiagnosticLog.append(cameraSource.context, TAG, "Preview image request handle=$handle")
        beginCurrentRead()
        thumbnailController.pauseForExclusiveOperation(cameraSource, reason = "preview")
        try {
            val data = requestScheduler.run(GalleryRequestPriority.PreviewImage) {
                cameraSource.getPreviewImage(handle)
            }
            val decodedSize = data.decodedBounds()
            cachePreviewImage(handle, data)
            writePreviewImageToDisk(cameraSource, handle, data)
            _previewImages.value = previewImageCache.toMap()
            _loadedPreviewHandles.value = _loadedPreviewHandles.value + handle
            _failedPreviewHandles.value = _failedPreviewHandles.value - handle
            DiagnosticLog.append(
                cameraSource.context,
                TAG,
                "Preview image loaded handle=$handle source=compressedPreview bytes=${data.size} " +
                    "decoded=${decodedSize.width}x${decodedSize.height}",
            )
            onSuccess(handle)
        } catch (e: Exception) {
            DiagnosticLog.append(cameraSource.context, TAG, "Preview image failed handle=$handle", e)
            onFailure(handle)
        } finally {
            _loadingPreviewHandles.value = _loadingPreviewHandles.value - handle
            thumbnailController.resumeAfterExclusiveOperation(cameraSource, reason = "preview")
            endCurrentRead()
        }
    }

    private fun beginCurrentRead() {
        synchronized(currentReadLock) {
            currentReadGate = CompletableDeferred()
        }
    }

    private fun endCurrentRead() {
        synchronized(currentReadLock) {
            currentReadGate?.complete(Unit)
            currentReadGate = null
        }
    }

    private fun cachePreviewImage(handle: Int, data: ByteArray) {
        previewImageCache.remove(handle)
        previewImageCache[handle] = data
        val protectedHandles = activeSession?.activeWindowHandleSet().orEmpty()
        while (previewImageCache.size > MAX_CACHED_PREVIEW_IMAGES) {
            val oldestHandle = previewImageCache.keys.firstOrNull { it !in protectedHandles }
                ?: previewImageCache.keys.firstOrNull()
                ?: return
            previewImageCache.remove(oldestHandle)
        }
    }

    private fun restoreActiveWindowPreviewImages(
        cameraSource: CameraFileSource,
        activeWindowHandles: Set<Int>,
    ) {
        if (activeWindowHandles.isEmpty()) return
        var changed = false
        val missingLoadedHandles = mutableSetOf<Int>()
        activeWindowHandles.forEach { handle ->
            if (previewImageCache.containsKey(handle)) return@forEach
            val data = readPreviewImageFromDisk(cameraSource, handle)
            if (data != null) {
                cachePreviewImage(handle, data)
                _loadedPreviewHandles.value = _loadedPreviewHandles.value + handle
                changed = true
            } else if (handle in _loadedPreviewHandles.value) {
                missingLoadedHandles += handle
            }
        }
        if (missingLoadedHandles.isNotEmpty()) {
            _loadedPreviewHandles.value = _loadedPreviewHandles.value - missingLoadedHandles
            DiagnosticLog.append(
                cameraSource.context,
                TAG,
                "HD preview active window missing cache handles=${missingLoadedHandles.take(8).joinToString()}",
            )
        }
        if (changed) {
            _previewImages.value = previewImageCache.toMap()
            DiagnosticLog.append(
                cameraSource.context,
                TAG,
                "HD preview restored active window from disk count=${activeWindowHandles.count { it in previewImageCache }}",
            )
        }
    }

    private fun readPreviewImageFromDisk(cameraSource: CameraFileSource, handle: Int): ByteArray? =
        runCatching {
            val file = previewDiskFile(cameraSource, handle)
            if (file.exists() && file.length() > 0L) file.readBytes() else null
        }.getOrNull()

    private fun writePreviewImageToDisk(
        cameraSource: CameraFileSource,
        handle: Int,
        data: ByteArray,
    ) {
        runCatching {
            val file = previewDiskFile(cameraSource, handle)
            file.parentFile?.mkdirs()
            file.writeBytes(data)
        }.onFailure { error ->
            DiagnosticLog.append(cameraSource.context, TAG, "HD preview disk cache write failed handle=$handle", error)
        }
    }

    private fun previewDiskFile(cameraSource: CameraFileSource, handle: Int): File =
        File(File(cameraSource.context.cacheDir, "hd-preview-cache"), "$handle.bin")

    private fun ByteArray.decodedBounds(): PreviewDecodedBounds {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(this, 0, size, options)
        return PreviewDecodedBounds(
            width = options.outWidth,
            height = options.outHeight,
        )
    }

    private companion object {
        const val TAG = "GalleryPreviewController"
        const val MAX_CACHED_PREVIEW_IMAGES = 30
    }
}

private data class PreviewDecodedBounds(
    val width: Int,
    val height: Int,
)

internal object GalleryPreviewFullImageLoadPolicy {
    fun shouldRequestFullImagePreview(
        file: CameraFile,
        hasPreviewImage: Boolean,
        isAlreadyLoading: Boolean,
        force: Boolean,
    ): Boolean {
        if (hasPreviewImage && !force) return false
        if (isAlreadyLoading) return false
        return supportsHighDefinitionPreview(file)
    }

    fun supportsHighDefinitionPreview(file: CameraFile): Boolean =
        file.info.isJpeg || file.info.isHeif
}
