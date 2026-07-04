package com.camtransfer.viewmodel

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import com.camtransfer.viewmodel.gallery.GalleryFastInitialLoadPolicy
import com.camtransfer.viewmodel.gallery.GalleryPreviewDiskCacheEntry
import com.camtransfer.viewmodel.gallery.GalleryPreviewDiskCachePolicy
import com.camtransfer.viewmodel.gallery.GalleryPreviewFailurePolicy
import com.camtransfer.viewmodel.gallery.GalleryPreviewFullImageLoadPolicy
import com.camtransfer.viewmodel.gallery.ThumbnailDiskCachePolicy
import com.camtransfer.viewmodel.gallery.ThumbnailMemoryCache
import com.camtransfer.viewmodel.gallery.ThumbnailLoadPolicy
import com.camtransfer.viewmodel.gallery.ThumbnailLoadQueue
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ThumbnailRequestTrackerTest {
    @Test
    fun rejectsDuplicateRequestWhileHandleIsPending() {
        val queue = ThumbnailLoadQueue()

        assertTrue(queue.offer(42))
        assertFalse(queue.offer(42))
        assertTrue(queue.trackedCount == 1)
    }

    @Test
    fun allowsSameHandleAfterPreviousRequestFinishes() {
        val queue = ThumbnailLoadQueue()

        assertTrue(queue.offer(42))
        queue.finish(42)

        assertTrue(queue.offer(42))
        assertTrue(queue.trackedCount == 1)
    }

    @Test
    fun pollsHandlesInRequestOrder() {
        val queue = ThumbnailLoadQueue()

        queue.offer(42)
        queue.offer(43)

        assertTrue(queue.poll() == 42)
        assertTrue(queue.poll() == 43)
    }

    @Test
    fun dropsStalePendingHandlesWhenVisibleWindowChanges() {
        val queue = ThumbnailLoadQueue()

        queue.offer(42)
        queue.offer(43)
        queue.offer(44)
        queue.retain(setOf(43, 44))

        assertEquals(2, queue.trackedCount)
        assertTrue(queue.poll() == 43)
        assertTrue(queue.poll() == 44)
    }

    @Test
    fun keepsProtectedPreviewHandlesWhenVisibleWindowChanges() {
        val queue = ThumbnailLoadQueue()

        queue.offer(42)
        queue.offer(43)
        queue.offer(44)
        queue.protect(setOf(42))
        queue.retain(setOf(43, 44))

        assertEquals(3, queue.trackedCount)
        assertTrue(queue.poll() == 42)
        assertTrue(queue.poll() == 43)
        assertTrue(queue.poll() == 44)
    }

    @Test
    fun clearsAllPendingAndProtectedHandlesWhenTransferStarts() {
        val queue = ThumbnailLoadQueue()

        queue.offer(42)
        queue.offer(43)
        queue.protect(setOf(42))
        queue.clear()

        assertEquals(0, queue.trackedCount)
        assertEquals(0, queue.pendingCount)
        assertEquals(null, queue.poll())
        assertTrue(queue.offer(42))
    }

    @Test
    fun thumbnailLoadingUsesSmallConcurrentWindow() {
        assertTrue(ThumbnailLoadPolicy.MAX_CONCURRENT_WORKERS == 1)
        assertTrue(ThumbnailLoadPolicy.shouldStartWorker(activeWorkers = 0, pendingHandles = 3))
        assertFalse(ThumbnailLoadPolicy.shouldStartWorker(activeWorkers = 1, pendingHandles = 3))
        assertFalse(ThumbnailLoadPolicy.shouldStartWorker(activeWorkers = 2, pendingHandles = 3))
        assertFalse(ThumbnailLoadPolicy.shouldStartWorker(activeWorkers = 0, pendingHandles = 0))
    }

    @Test
    fun thumbnailMemoryCacheEvictsOldestEntryWhenOverLimit() {
        val cache = ThumbnailMemoryCache(maxEntries = 2)

        cache.put(1, byteArrayOf(1))
        cache.put(2, byteArrayOf(2))
        cache.put(3, byteArrayOf(3))

        assertFalse(cache.snapshot().containsKey(1))
        assertTrue(cache.snapshot().containsKey(2))
        assertTrue(cache.snapshot().containsKey(3))
    }

    @Test
    fun thumbnailMemoryCacheRefreshesUpdatedHandleAsNewest() {
        val cache = ThumbnailMemoryCache(maxEntries = 2)

        cache.put(1, byteArrayOf(1))
        cache.put(2, byteArrayOf(2))
        cache.put(1, byteArrayOf(9))
        cache.put(3, byteArrayOf(3))

        assertTrue(cache.snapshot().containsKey(1))
        assertFalse(cache.snapshot().containsKey(2))
        assertTrue(cache.snapshot().containsKey(3))
        assertEquals(9, cache.snapshot().getValue(1).single().toInt())
    }

    @Test
    fun thumbnailDiskCacheKeyChangesWhenObjectIdentityChanges() {
        val cacheDir = File("cache")
        val first = ThumbnailDiskCachePolicy.fileFor(cacheDir, 42, file(PtpObjectFormat.JPEG, size = 1024))
        val changed = ThumbnailDiskCachePolicy.fileFor(cacheDir, 42, file(PtpObjectFormat.JPEG, size = 2048))

        assertTrue(first.path.contains("thumbnail-disk-cache"))
        assertFalse(first.name == changed.name)
    }

    @Test
    fun thumbnailDiskCacheTrimsPeriodicallyAfterWrites() {
        assertFalse(ThumbnailDiskCachePolicy.shouldTrimAfterWrite(1))
        assertTrue(ThumbnailDiskCachePolicy.shouldTrimAfterWrite(32))
        assertFalse(ThumbnailDiskCachePolicy.shouldTrimAfterWrite(33))
    }

    @Test
    fun thumbnailDiskTrimRunsOutsideThumbnailWritePath() {
        val source = listOf(
            File("src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailController.kt"),
            File("app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailController.kt"),
        ).first { it.exists() }.readText()
        val writeBlock = source.substring(
            source.indexOf("private fun writeThumbnailToDisk"),
            source.indexOf("private fun scheduleThumbnailDiskWrite"),
        )
        val diskWriteBlock = source.substring(
            source.indexOf("private fun scheduleThumbnailDiskWrite"),
            source.indexOf("private fun scheduleThumbnailDiskTrim"),
        )
        val trimBlock = source.substring(
            source.indexOf("private fun scheduleThumbnailDiskTrim"),
            source.indexOf("private fun activeOrPendingThumbnailCount"),
        )

        assertTrue(writeBlock.contains("scheduleThumbnailDiskWrite("))
        assertFalse(writeBlock.contains("AppCacheUsagePolicy.trimToLimit"))
        assertFalse(writeBlock.contains("writeBytes("))
        assertTrue(diskWriteBlock.contains("scope.launch(Dispatchers.IO)"))
        assertTrue(diskWriteBlock.contains("writeBytes(thumbnail)"))
        assertTrue(trimBlock.contains("scope.launch(Dispatchers.IO)"))
        assertTrue(trimBlock.contains("AppCacheUsagePolicy.trimToLimit"))
    }

    @Test
    fun thumbnailRequestsAreBlockedWhileTransferIsPreparingOrActive() {
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isTransferPreparingOrActive = true,
                isLoadingFullObjectInfo = false,
                hasThumbnail = false,
                activeOrPendingThumbnailCount = 0,
            )
        )
    }

    @Test
    fun fullPreviewRequestsOnlyJpegAndHeifImagesThatAreNotCached() {
        assertTrue(
            GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(
                file = file(PtpObjectFormat.JPEG),
                hasPreviewImage = false,
                isAlreadyLoading = false,
                force = false,
            )
        )
        assertTrue(
            GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(
                file = file(PtpObjectFormat.HEIF),
                hasPreviewImage = false,
                isAlreadyLoading = false,
                force = false,
            )
        )
        assertFalse(
            GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(
                file = file(PtpObjectFormat.CAMERA_VENDOR_RAF),
                hasPreviewImage = false,
                isAlreadyLoading = false,
                force = false,
            )
        )
        assertFalse(
            GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(
                file = file(PtpObjectFormat.JPEG),
                hasPreviewImage = true,
                isAlreadyLoading = false,
                force = false,
            )
        )
    }

    @Test
    fun previewCancellationDoesNotMarkHandleAsFailed() {
        assertFalse(GalleryPreviewFailurePolicy.shouldMarkFailed(CancellationException("transfer pause")))
        assertTrue(GalleryPreviewFailurePolicy.shouldMarkFailed(IllegalStateException("decode failed")))
    }

    @Test
    fun previewDiskCacheTrimsOldUnprotectedEntriesFirst() {
        val entries = listOf(
            GalleryPreviewDiskCacheEntry(fileName = "1.bin", sizeBytes = 40, lastModifiedMs = 1, isActiveWindow = false),
            GalleryPreviewDiskCacheEntry(fileName = "2.bin", sizeBytes = 40, lastModifiedMs = 2, isActiveWindow = true),
            GalleryPreviewDiskCacheEntry(fileName = "3.bin", sizeBytes = 40, lastModifiedMs = 3, isActiveWindow = false),
        )

        assertEquals(
            setOf("1.bin"),
            GalleryPreviewDiskCachePolicy.filesToDelete(entries, maxTotalBytes = 90),
        )
    }

    @Test
    fun previewDiskCacheCanTrimProtectedEntriesOnlyWhenStillOverLimit() {
        val entries = listOf(
            GalleryPreviewDiskCacheEntry(fileName = "1.bin", sizeBytes = 70, lastModifiedMs = 1, isActiveWindow = true),
            GalleryPreviewDiskCacheEntry(fileName = "2.bin", sizeBytes = 70, lastModifiedMs = 2, isActiveWindow = true),
        )

        assertEquals(
            setOf("1.bin"),
            GalleryPreviewDiskCachePolicy.filesToDelete(entries, maxTotalBytes = 100),
        )
    }

    private fun file(format: Int, size: Int = 1024): CameraFile = CameraFile(
        ObjectInfo(
            handle = 42,
            storageId = 1,
            format = format,
            compressedSize = size,
            thumbFormat = PtpObjectFormat.JPEG,
            thumbCompressedSize = 128,
            thumbPixWidth = 160,
            thumbPixHeight = 120,
            imagePixWidth = 4000,
            imagePixHeight = 3000,
            parentObject = 0,
            filename = "DSCF0042.JPG",
            captureDate = "20260604T120000",
        ),
    )
}
