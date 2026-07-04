package com.camtransfer.viewmodel

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import com.camtransfer.viewmodel.gallery.GalleryFastInitialLoadPolicy
import com.camtransfer.viewmodel.gallery.GalleryPreviewFailurePolicy
import com.camtransfer.viewmodel.gallery.GalleryPreviewFullImageLoadPolicy
import com.camtransfer.viewmodel.gallery.ThumbnailLoadPolicy
import com.camtransfer.viewmodel.gallery.ThumbnailLoadQueue
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

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

    private fun file(format: Int): CameraFile = CameraFile(
        ObjectInfo(
            handle = 42,
            storageId = 1,
            format = format,
            compressedSize = 1024,
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
