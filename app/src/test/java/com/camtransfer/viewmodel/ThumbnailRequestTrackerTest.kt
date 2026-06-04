package com.camtransfer.viewmodel

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ThumbnailRequestTrackerTest {
    @Test
    fun rejectsDuplicateRequestWhileHandleIsPending() {
        val queue = ThumbnailLoadQueue()

        assertTrue(queue.offer(42))
        assertFalse(queue.offer(42))
    }

    @Test
    fun allowsSameHandleAfterPreviousRequestFinishes() {
        val queue = ThumbnailLoadQueue()

        assertTrue(queue.offer(42))
        queue.finish(42)

        assertTrue(queue.offer(42))
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
    fun thumbnailLoadingUsesSmallConcurrentWindow() {
        assertTrue(ThumbnailLoadPolicy.MAX_CONCURRENT_WORKERS == 1)
        assertTrue(ThumbnailLoadPolicy.shouldStartWorker(activeWorkers = 0, pendingHandles = 3))
        assertFalse(ThumbnailLoadPolicy.shouldStartWorker(activeWorkers = 1, pendingHandles = 3))
        assertFalse(ThumbnailLoadPolicy.shouldStartWorker(activeWorkers = 2, pendingHandles = 3))
        assertFalse(ThumbnailLoadPolicy.shouldStartWorker(activeWorkers = 0, pendingHandles = 0))
    }
}
