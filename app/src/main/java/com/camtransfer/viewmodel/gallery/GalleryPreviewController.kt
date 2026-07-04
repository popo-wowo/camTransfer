package com.camtransfer.viewmodel.gallery

import android.graphics.BitmapFactory
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.AppCacheUsagePolicy
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import java.io.File

class GalleryPreviewController(
    private val scope: CoroutineScope,
    private val sessionActor: GallerySessionActor,
    private val thumbnailController: GalleryThumbnailController,
    private val previewStore: GalleryPreviewStore,
) {
    val previewImages: StateFlow<Map<Int, ByteArray>> = previewStore.previewImages
    val loadedPreviewHandles: StateFlow<Set<Int>> = previewStore.loadedHandles
    val loadingPreviewHandles: StateFlow<Set<Int>> = previewStore.loadingHandles
    val failedPreviewHandles: StateFlow<Set<Int>> = previewStore.failedHandles

    private var manualPreviewJob: Job? = null
    private var sessionPreviewJob: Job? = null

    @Volatile
    private var pendingPreviewFile: CameraFile? = null

    @Volatile
    private var activeSession: HighDefinitionPreviewSession? = null

    @Volatile
    private var lastPreviewDiskRoot: File? = null

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
                hasPreviewImage = previewStore.hasPreview(handle),
                isAlreadyLoading = handle in previewStore.loadingHandles.value,
                force = force,
            )
        ) {
            return
        }
        pendingPreviewFile = file
        previewStore.markLoading(handle)
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
        val sessionHandles = session.files.map { it.info.handle }.toSet()
        activeSession = session.copy(
            failedHandles = previewStore.failedHandles.value.intersect(sessionHandles),
        )
        previewStore.keepFailuresFor(sessionHandles)
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
            loadedHandles = previewStore.loadedHandles.value,
            loadingHandles = previewStore.loadingHandles.value,
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

    fun clearSessionPreviewCache(cameraSource: CameraFileSource, reason: String) {
        stopSession()
        clearSessionPreviewDiskCache(cameraSource)
        DiagnosticLog.append(
            cameraSource.context,
            TAG,
            "HD preview session cache cleared reason=$reason",
        )
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
        previewStore.clear()
        clearLastSessionPreviewDiskCache()
    }

    private fun startSessionWorker(cameraSource: CameraFileSource) {
        if (sessionPreviewJob?.isActive == true) return
        sessionPreviewJob = scope.launch(Dispatchers.IO) {
            while (true) {
                if (previewLoadingPaused) return@launch
                val session = activeSession ?: return@launch
                if (session.pausedForTransfer) return@launch
                val nextFile = session.nextFile(
                    loadedHandles = previewStore.loadedHandles.value,
                    loadingHandles = previewStore.loadingHandles.value,
                ) ?: return@launch
                val handle = nextFile.info.handle
                previewStore.markLoading(handle)
                loadPreviewImageNow(
                    cameraSource = cameraSource,
                    file = nextFile,
                    onSuccess = { loadedHandle ->
                        activeSession = activeSession?.markLoaded(loadedHandle)
                    },
                    onFailure = { failedHandle ->
                        previewStore.markFailed(failedHandle)
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
        if (previewStore.hasPreview(handle)) {
            previewStore.clearLoading(handle)
            onSuccess(handle)
            return
        }
        DiagnosticLog.append(cameraSource.context, TAG, "Preview image request handle=$handle")
        beginCurrentRead()
        thumbnailController.pauseForExclusiveOperation(cameraSource, reason = "preview")
        try {
            val data = sessionActor.run(GalleryRequestPriority.PreviewImage) {
                cameraSource.getPreviewImage(handle)
            }
            val decodedSize = data.decodedBounds()
            previewStore.markLoaded(
                handle = handle,
                data = data,
                protectedHandles = activeSession?.activeWindowHandleSet().orEmpty(),
            )
            writePreviewImageToDisk(cameraSource, handle, data)
            trimPreviewDiskCache(cameraSource, activeSession?.activeWindowHandleSet().orEmpty())
            DiagnosticLog.append(
                cameraSource.context,
                TAG,
                "Preview image loaded handle=$handle source=compressedPreview bytes=${data.size} " +
                    "decoded=${decodedSize.width}x${decodedSize.height}",
            )
            onSuccess(handle)
        } catch (e: Exception) {
            if (!GalleryPreviewFailurePolicy.shouldMarkFailed(e)) {
                DiagnosticLog.append(
                    cameraSource.context,
                    TAG,
                    "Preview image cancelled handle=$handle reason=${e.message.orEmpty()}",
                )
                throw e
            }
            DiagnosticLog.append(cameraSource.context, TAG, "Preview image failed handle=$handle", e)
            onFailure(handle)
        } finally {
            previewStore.clearLoading(handle)
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

    private fun restoreActiveWindowPreviewImages(
        cameraSource: CameraFileSource,
        activeWindowHandles: Set<Int>,
    ) {
        if (activeWindowHandles.isEmpty()) return
        scope.launch(Dispatchers.IO) {
            var previewSnapshot: Map<Int, ByteArray>? = null
            val restoredHandles = mutableSetOf<Int>()
            val missingLoadedHandles = mutableSetOf<Int>()
            activeWindowHandles.forEach { handle ->
                if (previewStore.hasPreview(handle)) return@forEach
                val data = readPreviewImageFromDisk(cameraSource, handle)
                if (data != null) {
                    previewSnapshot = previewStore.putRestored(handle, data, activeWindowHandles)
                    restoredHandles += handle
                } else if (handle in previewStore.loadedHandles.value) {
                    missingLoadedHandles += handle
                }
            }
            if (missingLoadedHandles.isNotEmpty()) {
                previewStore.removeLoaded(missingLoadedHandles)
                DiagnosticLog.append(
                    cameraSource.context,
                    TAG,
                    "HD preview active window missing cache handles=${missingLoadedHandles.take(8).joinToString()}",
                )
            }
            previewSnapshot?.let { snapshot ->
                previewStore.markRestored(restoredHandles)
                DiagnosticLog.append(
                    cameraSource.context,
                    TAG,
                    "HD preview restored active window from disk count=${restoredHandles.size}",
                )
            }
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

    private fun trimPreviewDiskCache(
        cameraSource: CameraFileSource,
        activeWindowHandles: Set<Int>,
    ) {
        runCatching {
            val root = previewDiskRoot(cameraSource)
            val entries = root.listFiles()
                ?.filter { it.isFile && it.length() > 0L }
                ?.map { file ->
                    GalleryPreviewDiskCacheEntry(
                        fileName = file.name,
                        sizeBytes = file.length(),
                        lastModifiedMs = file.lastModified(),
                        isActiveWindow = previewHandleFromDiskFile(file) in activeWindowHandles,
                    )
                }
                .orEmpty()
            val filesToDelete = GalleryPreviewDiskCachePolicy.filesToDelete(entries)
            if (filesToDelete.isEmpty()) return
            root.listFiles()
                ?.filter { it.name in filesToDelete }
                ?.forEach { it.delete() }
            DiagnosticLog.append(
                cameraSource.context,
                TAG,
                "HD preview disk cache trimmed deleted=${filesToDelete.size}",
            )
        }.onFailure { error ->
            DiagnosticLog.append(cameraSource.context, TAG, "HD preview disk cache trim failed", error)
        }
    }

    private fun previewDiskFile(cameraSource: CameraFileSource, handle: Int): File =
        File(previewDiskRoot(cameraSource), "$handle.bin")

    private fun previewDiskRoot(cameraSource: CameraFileSource): File =
        File(cameraSource.context.cacheDir, AppCacheUsagePolicy.SESSION_PREVIEW_CACHE_DIRECTORY_NAME).also {
            lastPreviewDiskRoot = it
        }

    private fun clearSessionPreviewDiskCache(cameraSource: CameraFileSource) {
        runCatching {
            AppCacheUsagePolicy.clearSessionPreviewCache(cameraSource.context.cacheDir)
        }.also {
            lastPreviewDiskRoot = null
        }
    }

    private fun clearLastSessionPreviewDiskCache() {
        runCatching {
            lastPreviewDiskRoot?.deleteRecursively()
        }.also {
            lastPreviewDiskRoot = null
        }
    }

    private fun previewHandleFromDiskFile(file: File): Int? =
        file.name.removeSuffix(".bin").toIntOrNull()

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

internal object GalleryPreviewFailurePolicy {
    fun shouldMarkFailed(error: Throwable): Boolean =
        error !is CancellationException
}

internal data class GalleryPreviewDiskCacheEntry(
    val fileName: String,
    val sizeBytes: Long,
    val lastModifiedMs: Long,
    val isActiveWindow: Boolean,
)

internal object GalleryPreviewDiskCachePolicy {
    const val MAX_TOTAL_BYTES: Long = 300L * 1024L * 1024L

    fun filesToDelete(
        entries: List<GalleryPreviewDiskCacheEntry>,
        maxTotalBytes: Long = MAX_TOTAL_BYTES,
    ): Set<String> {
        var totalBytes = entries.sumOf { it.sizeBytes }
        if (totalBytes <= maxTotalBytes) return emptySet()
        val deleted = linkedSetOf<String>()
        entries
            .sortedWith(
                compareBy<GalleryPreviewDiskCacheEntry> { it.isActiveWindow }
                    .thenBy { it.lastModifiedMs }
            )
            .forEach { entry ->
                if (totalBytes <= maxTotalBytes) return@forEach
                deleted += entry.fileName
                totalBytes -= entry.sizeBytes
            }
        return deleted
    }
}
