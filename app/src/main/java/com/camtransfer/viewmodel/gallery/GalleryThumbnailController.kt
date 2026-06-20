package com.camtransfer.viewmodel.gallery

import android.graphics.BitmapFactory
import android.util.Log
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.DiagnosticLog
import com.camtransfer.ui.GalleryThumbnailDiagnosticPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield

class GalleryThumbnailController(
    private val scope: CoroutineScope,
    private val requestScheduler: GalleryRequestScheduler,
    private val filesController: GalleryFilesController,
) {
    private val thumbnailQueue = ThumbnailLoadQueue()
    private val thumbnailWorkers = mutableSetOf<Job>()
    private val thumbnailCache = mutableMapOf<Int, ByteArray>()
    private val thumbnailPauseLock = Any()
    private var exclusiveThumbnailPauseCount = 0

    @Volatile
    private var thumbnailLoadingPaused = false

    fun cachedThumbnails(): Map<Int, ByteArray> = thumbnailCache.toMap()

    fun loadThumbnail(cameraSource: CameraFileSource, handle: Int) {
        if (!GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isTransferPreparingOrActive = thumbnailLoadingPaused,
                isLoadingFullObjectInfo = filesController.isLoading.value,
                hasThumbnail = filesController.hasThumbnail(handle),
                activeOrPendingThumbnailCount = activeOrPendingThumbnailCount(),
            )
        ) {
            return
        }
        if (filesController.hasThumbnail(handle)) return
        if (!thumbnailQueue.offer(handle)) return
        startThumbnailWorkers(cameraSource)
    }

    fun loadVisibleThumbnails(cameraSource: CameraFileSource, handles: List<Int>) {
        if (thumbnailLoadingPaused) return
        if (handles.isEmpty()) return
        val visibleHandles = handles.toSet()
        thumbnailQueue.retain(visibleHandles)
        handles.forEach { handle -> loadThumbnail(cameraSource, handle) }
    }

    fun loadPreviewThumbnails(cameraSource: CameraFileSource, handles: List<Int>) {
        if (thumbnailLoadingPaused) return
        if (handles.isEmpty()) return
        handles.forEach { handle -> loadPreviewThumbnail(cameraSource, handle) }
        thumbnailQueue.protect(handles.toSet())
        startThumbnailWorkers(cameraSource)
    }

    suspend fun pauseForExclusiveOperation(cameraSource: CameraFileSource, reason: String) {
        val workers = synchronized(thumbnailPauseLock) {
            exclusiveThumbnailPauseCount += 1
            thumbnailLoadingPaused = true
            thumbnailQueue.clear()
            val workersToCancel = thumbnailWorkers.toList()
            workersToCancel.forEach { it.cancel() }
            thumbnailWorkers.clear()
            workersToCancel
        }
        workers.forEach { it.join() }
        DiagnosticLog.append(
            cameraSource.context,
            TAG,
            "Thumbnail loading paused reason=$reason count=$exclusiveThumbnailPauseCount",
        )
    }

    fun resumeAfterExclusiveOperation(cameraSource: CameraFileSource, reason: String) {
        val pauseCount = synchronized(thumbnailPauseLock) {
            if (exclusiveThumbnailPauseCount == 0) return
            exclusiveThumbnailPauseCount -= 1
            thumbnailLoadingPaused = exclusiveThumbnailPauseCount > 0
            exclusiveThumbnailPauseCount
        }
        DiagnosticLog.append(
            cameraSource.context,
            TAG,
            "Thumbnail loading resume reason=$reason count=$pauseCount paused=$thumbnailLoadingPaused",
        )
    }

    fun reset() {
        thumbnailWorkers.forEach { it.cancel() }
        thumbnailWorkers.clear()
        thumbnailCache.clear()
        synchronized(thumbnailPauseLock) {
            exclusiveThumbnailPauseCount = 0
            thumbnailLoadingPaused = false
        }
        thumbnailQueue.clear()
    }

    private fun loadPreviewThumbnail(cameraSource: CameraFileSource, handle: Int) {
        if (!GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isTransferPreparingOrActive = thumbnailLoadingPaused,
                isLoadingFullObjectInfo = filesController.isLoading.value,
                hasThumbnail = filesController.hasThumbnail(handle),
                activeOrPendingThumbnailCount = activeOrPendingThumbnailCount(),
            )
        ) {
            return
        }
        if (filesController.hasThumbnail(handle)) return
        if (!thumbnailQueue.offerProtected(handle)) {
            thumbnailQueue.protect(setOf(handle))
        }
    }

    private fun startThumbnailWorkers(cameraSource: CameraFileSource) {
        thumbnailWorkers.removeAll { !it.isActive }
        while (ThumbnailLoadPolicy.shouldStartWorker(
                activeWorkers = thumbnailWorkers.count { it.isActive },
                pendingHandles = thumbnailQueue.pendingCount,
            )
        ) {
            val worker = scope.launch(Dispatchers.IO) {
                drainThumbnailQueue(cameraSource)
            }
            thumbnailWorkers.add(worker)
        }
    }

    private suspend fun drainThumbnailQueue(cameraSource: CameraFileSource) {
        while (true) {
            val handle = thumbnailQueue.poll() ?: return
            try {
                if (thumbnailLoadingPaused) return
                loadThumbnailNow(cameraSource, handle)
            } finally {
                thumbnailQueue.finish(handle)
            }
            yield()
        }
    }

    private suspend fun loadThumbnailNow(cameraSource: CameraFileSource, handle: Int) {
        if (filesController.hasThumbnail(handle)) return
        Log.d(TAG, "Thumbnail request handle=$handle")
        DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail request handle=$handle")
        try {
            val thumbnail = requestScheduler.run(GalleryRequestPriority.VisibleThumbnail) {
                cameraSource.getThumbnailWithInfo(handle)
            }
            val thumb = thumbnail.data
            val file = thumbnail.file ?: filesController.files.value.firstOrNull { it.info.handle == handle }
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
            thumbnailCache[handle] = thumb
            filesController.mergeThumbnail(handle, thumb, thumbnail.file)
        } catch (e: Exception) {
            Log.w(TAG, "Thumbnail failed handle=$handle: $e")
            DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail failed handle=$handle", e)
        }
    }

    private fun activeOrPendingThumbnailCount(): Int =
        thumbnailQueue.trackedCount

    private fun ByteArray.decodedBounds(): ThumbnailDecodedBounds {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(this, 0, size, options)
        return ThumbnailDecodedBounds(
            width = options.outWidth,
            height = options.outHeight,
        )
    }

    private companion object {
        const val TAG = "GalleryThumbnailController"
    }
}

private data class ThumbnailDecodedBounds(
    val width: Int,
    val height: Int,
)

internal class ThumbnailLoadQueue {
    private val handles = ArrayDeque<Int>()
    private val pendingHandles = mutableSetOf<Int>()
    private val protectedHandles = mutableSetOf<Int>()

    val pendingCount: Int
        @Synchronized get() = handles.size

    val trackedCount: Int
        @Synchronized get() = pendingHandles.size

    @Synchronized
    fun offer(handle: Int): Boolean {
        if (!pendingHandles.add(handle)) return false
        handles.addLast(handle)
        return true
    }

    @Synchronized
    fun offerProtected(handle: Int): Boolean {
        if (!offer(handle)) return false
        protectedHandles.add(handle)
        return true
    }

    @Synchronized
    fun poll(): Int? = handles.removeFirstOrNull()

    @Synchronized
    fun finish(handle: Int) {
        pendingHandles.remove(handle)
        protectedHandles.remove(handle)
    }

    @Synchronized
    fun protect(handles: Set<Int>) {
        protectedHandles.addAll(handles.filter { it in pendingHandles })
    }

    @Synchronized
    fun retain(allowedHandles: Set<Int>) {
        if (allowedHandles.isEmpty()) return
        val retainedAllowedHandles = allowedHandles + protectedHandles
        val retainedHandles = handles.filter { it in retainedAllowedHandles }
        handles.clear()
        retainedHandles.forEach { handles.addLast(it) }
        pendingHandles.retainAll(retainedAllowedHandles)
        protectedHandles.retainAll(pendingHandles)
    }

    @Synchronized
    fun clear() {
        handles.clear()
        pendingHandles.clear()
        protectedHandles.clear()
    }
}

internal object ThumbnailLoadPolicy {
    const val MAX_CONCURRENT_WORKERS = 1

    fun shouldStartWorker(activeWorkers: Int, pendingHandles: Int): Boolean =
        pendingHandles > 0 && activeWorkers < MAX_CONCURRENT_WORKERS
}
