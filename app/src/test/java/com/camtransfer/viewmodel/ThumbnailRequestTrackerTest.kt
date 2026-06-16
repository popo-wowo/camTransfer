package com.camtransfer.viewmodel

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
}
