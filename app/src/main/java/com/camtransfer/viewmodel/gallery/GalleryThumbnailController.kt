package com.camtransfer.viewmodel.gallery

import android.graphics.BitmapFactory
import android.util.Log
import com.camtransfer.model.CameraFile
import com.camtransfer.service.AppCacheSettingsStore
import com.camtransfer.service.AppCacheUsagePolicy
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.DiagnosticLog
import com.camtransfer.ui.GalleryThumbnailDiagnosticPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import java.io.File
import java.util.LinkedHashMap

class GalleryThumbnailController(
    private val scope: CoroutineScope,
    private val sessionActor: GallerySessionActor,
    private val filesController: GalleryFilesController,
    private val thumbnailStore: GalleryThumbnailStore,
    private val metadataStore: GalleryMetadataStore,
) {
    private val thumbnailQueue = ThumbnailLoadQueue()
    private val thumbnailWorkers = mutableSetOf<Job>()
    private val thumbnailPauseLock = Any()
    private var exclusiveThumbnailPauseCount = 0
    private var thumbnailDiskWriteCount = 0
    private val thumbnailDiskWriteJobs = mutableSetOf<Job>()
    private var thumbnailDiskTrimJob: Job? = null

    @Volatile
    private var thumbnailLoadingPaused = false

    fun cachedThumbnails(): Map<Int, ByteArray> = thumbnailStore.snapshot()

    fun hasActiveThumbnailWork(): Boolean =
        thumbnailQueue.trackedCount > 0

    fun loadThumbnail(cameraSource: CameraFileSource, handle: Int) {
        loadThumbnail(cameraSource, handle, isExplicitVisibleWindow = false)
    }

    private fun loadThumbnail(
        cameraSource: CameraFileSource,
        handle: Int,
        isExplicitVisibleWindow: Boolean,
    ) {
        if (!GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isTransferPreparingOrActive = thumbnailLoadingPaused,
                isLoadingFullObjectInfo = filesController.isLoadingHiddenFormats.value,
                hasThumbnail = hasThumbnail(handle),
                activeOrPendingThumbnailCount = activeOrPendingThumbnailCount(),
                isExplicitVisibleWindow = isExplicitVisibleWindow,
            )
        ) {
            return
        }
        if (hasThumbnail(handle)) return
        if (!thumbnailQueue.offer(handle)) return
        startThumbnailWorkers(cameraSource)
    }

    fun loadVisibleThumbnails(cameraSource: CameraFileSource, handles: List<Int>) {
        if (thumbnailLoadingPaused) return
        if (handles.isEmpty()) return
        val visibleHandles = handles.toSet()
        thumbnailQueue.retain(visibleHandles)
        handles.forEach { handle ->
            loadThumbnail(cameraSource, handle, isExplicitVisibleWindow = true)
        }
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
        synchronized(thumbnailDiskWriteJobs) {
            thumbnailDiskWriteJobs.forEach { it.cancel() }
            thumbnailDiskWriteJobs.clear()
        }
        thumbnailDiskTrimJob?.cancel()
        thumbnailDiskTrimJob = null
        thumbnailStore.clear()
        synchronized(thumbnailPauseLock) {
            exclusiveThumbnailPauseCount = 0
            thumbnailLoadingPaused = false
        }
        thumbnailQueue.clear()
    }

    private fun loadPreviewThumbnail(cameraSource: CameraFileSource, handle: Int) {
        if (!GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isTransferPreparingOrActive = thumbnailLoadingPaused,
                isLoadingFullObjectInfo = filesController.isLoadingHiddenFormats.value,
                hasThumbnail = hasThumbnail(handle),
                activeOrPendingThumbnailCount = activeOrPendingThumbnailCount(),
            )
        ) {
            return
        }
        if (hasThumbnail(handle)) return
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
        if (hasThumbnail(handle)) return
        val currentFile = filesController.files.value.firstOrNull { it.info.handle == handle }
        val cachedThumbnail = readThumbnailFromDisk(cameraSource, handle, currentFile)
        if (cachedThumbnail != null) {
            thumbnailStore.put(handle, cachedThumbnail)
            DiagnosticLog.append(
                cameraSource.context,
                TAG,
                "Thumbnail loaded handle=$handle source=disk bytes=${cachedThumbnail.size}",
            )
            return
        }
        Log.d(TAG, "Thumbnail request handle=$handle")
        DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail request handle=$handle")
        try {
            val thumbnail = sessionActor.run(GalleryRequestPriority.VisibleThumbnail) {
                cameraSource.getThumbnailWithInfo(handle)
            }
            val thumb = thumbnail.data
            val file = thumbnail.file ?: currentFile
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
            thumbnail.file?.let(metadataStore::put)
            thumbnailStore.put(handle, thumb)
            writeThumbnailToDisk(cameraSource, handle, thumb, file)
        } catch (e: Exception) {
            Log.w(TAG, "Thumbnail failed handle=$handle: $e")
            DiagnosticLog.append(cameraSource.context, TAG, "Thumbnail failed handle=$handle", e)
        }
    }

    private fun readThumbnailFromDisk(
        cameraSource: CameraFileSource,
        handle: Int,
        file: CameraFile?,
    ): ByteArray? =
        runCatching {
            val diskFile = ThumbnailDiskCachePolicy.fileFor(cameraSource.context.cacheDir, handle, file)
            if (diskFile.exists() && diskFile.length() > 0L) diskFile.readBytes() else null
        }.getOrNull()

    private fun writeThumbnailToDisk(
        cameraSource: CameraFileSource,
        handle: Int,
        thumbnail: ByteArray,
        file: CameraFile?,
    ) {
        scheduleThumbnailDiskWrite(
            cameraSource = cameraSource,
            handle = handle,
            thumbnail = thumbnail,
            file = file,
        )
    }

    private fun scheduleThumbnailDiskWrite(
        cameraSource: CameraFileSource,
        handle: Int,
        thumbnail: ByteArray,
        file: CameraFile?,
    ) {
        val context = cameraSource.context.applicationContext
        val job = scope.launch(Dispatchers.IO) {
            runCatching {
                val diskFile = ThumbnailDiskCachePolicy.fileFor(context.cacheDir, handle, file)
                diskFile.parentFile?.mkdirs()
                diskFile.writeBytes(thumbnail)
                thumbnailDiskWriteCount += 1
                if (ThumbnailDiskCachePolicy.shouldTrimAfterWrite(thumbnailDiskWriteCount)) {
                    scheduleThumbnailDiskTrim(cameraSource)
                }
            }.onFailure { error ->
                DiagnosticLog.append(context, TAG, "Thumbnail disk cache write failed handle=$handle", error)
            }
        }
        synchronized(thumbnailDiskWriteJobs) {
            thumbnailDiskWriteJobs.add(job)
        }
        job.invokeOnCompletion {
            synchronized(thumbnailDiskWriteJobs) {
                thumbnailDiskWriteJobs.remove(job)
            }
        }
    }

    private fun scheduleThumbnailDiskTrim(cameraSource: CameraFileSource) {
        if (thumbnailDiskTrimJob?.isActive == true) return
        val context = cameraSource.context.applicationContext
        thumbnailDiskTrimJob = scope.launch(Dispatchers.IO) {
            runCatching {
                val limit = AppCacheSettingsStore(context).loadLimit()
                val result = AppCacheUsagePolicy.trimToLimit(context.cacheDir, limit.bytes)
                if (result.deletedFiles > 0) {
                    DiagnosticLog.append(
                        context,
                        TAG,
                        "Thumbnail disk cache trimmed files=${result.deletedFiles} bytes=${result.deletedBytes}",
                    )
                }
            }.onFailure { error ->
                DiagnosticLog.append(context, TAG, "Thumbnail disk cache trim failed", error)
            }
        }
    }

    private fun activeOrPendingThumbnailCount(): Int =
        thumbnailQueue.trackedCount

    private fun hasThumbnail(handle: Int): Boolean =
        thumbnailStore.hasThumbnail(handle)

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

internal class ThumbnailMemoryCache(
    private val maxEntries: Int = MAX_CACHED_THUMBNAILS,
) {
    private val entries = LinkedHashMap<Int, ByteArray>(maxEntries, 0.75f, true)

    @Synchronized
    fun put(handle: Int, thumbnail: ByteArray) {
        entries.remove(handle)
        entries[handle] = thumbnail
        while (entries.size > maxEntries) {
            val oldestHandle = entries.keys.firstOrNull() ?: return
            entries.remove(oldestHandle)
        }
    }

    @Synchronized
    fun snapshot(): Map<Int, ByteArray> =
        entries.toMap()

    @Synchronized
    fun clear() {
        entries.clear()
    }

    companion object {
        const val MAX_CACHED_THUMBNAILS = 300
    }
}

internal object ThumbnailDiskCachePolicy {
    private const val TRIM_EVERY_WRITES = 32
    private val UnsafeFileNameChars = Regex("""[^A-Za-z0-9._-]""")

    fun fileFor(cacheDir: File, handle: Int, file: CameraFile?): File {
        val info = file?.info
        val identity = listOf(
            handle.toString(),
            (info?.format ?: 0).toString(),
            (info?.compressedSize ?: 0).toString(),
            info?.filename.orEmpty(),
        ).joinToString("-")
        val safeName = identity
            .replace(UnsafeFileNameChars, "_")
            .take(140)
            .ifBlank { handle.toString() }
        return File(File(cacheDir, "thumbnail-disk-cache"), "$safeName.bin")
    }

    fun shouldTrimAfterWrite(writeCount: Int): Boolean =
        writeCount > 0 && writeCount % TRIM_EVERY_WRITES == 0
}
