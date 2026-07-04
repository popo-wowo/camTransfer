package com.camtransfer.viewmodel.gallery

import kotlinx.coroutines.delay

class GallerySessionActor(
    private val scheduler: GalleryRequestScheduler = GalleryRequestScheduler(),
) {
    private val exclusiveLock = Any()
    private var exclusiveCount = 0

    suspend fun <T> run(
        priority: GalleryRequestPriority,
        block: suspend () -> T,
    ): T {
        waitForExclusiveGate(priority)
        return scheduler.run(priority, block)
    }

    fun enterTransferExclusive() {
        synchronized(exclusiveLock) {
            exclusiveCount += 1
        }
    }

    fun exitTransferExclusive() {
        synchronized(exclusiveLock) {
            exclusiveCount = (exclusiveCount - 1).coerceAtLeast(0)
        }
    }

    fun isTransferExclusive(): Boolean =
        synchronized(exclusiveLock) { exclusiveCount > 0 }

    private suspend fun waitForExclusiveGate(priority: GalleryRequestPriority) {
        if (priority == GalleryRequestPriority.DownloadOriginal) return
        while (isTransferExclusive()) {
            delay(EXCLUSIVE_GATE_POLL_MS)
        }
    }

    companion object {
        const val EXCLUSIVE_GATE_POLL_MS = 25L
    }
}
