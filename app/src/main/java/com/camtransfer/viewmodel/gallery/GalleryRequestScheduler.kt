package com.camtransfer.viewmodel.gallery

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class GalleryRequestPriority(val rank: Int) {
    DownloadOriginal(0),
    PreviewImage(1),
    VisibleThumbnail(2),
    PreviewNeighborThumbnail(3),
    BackgroundMetadata(4),
}

class GalleryRequestScheduler {
    private val stateMutex = Mutex()
    private val waiters = mutableListOf<QueuedRequest>()
    private var isCameraReadActive = false
    private var nextSequence = 0L

    suspend fun <T> run(
        priority: GalleryRequestPriority,
        block: suspend () -> T,
    ): T {
        acquire(priority)
        try {
            return block()
        } finally {
            releaseNext()
        }
    }

    private suspend fun acquire(priority: GalleryRequestPriority) {
        val gate = CompletableDeferred<Unit>()
        var acquiredImmediately = false
        val queuedRequest = stateMutex.withLock {
            if (!isCameraReadActive && waiters.isEmpty()) {
                isCameraReadActive = true
                acquiredImmediately = true
                null
            } else {
                QueuedRequest(
                    priority = priority,
                    sequence = nextSequence++,
                    gate = gate,
                ).also { waiters += it }
            }
        }
        if (acquiredImmediately) return
        try {
            gate.await()
        } catch (error: CancellationException) {
            if (queuedRequest != null) {
                stateMutex.withLock {
                    waiters.remove(queuedRequest)
                }
            }
            throw error
        }
    }

    private suspend fun releaseNext() {
        val next = stateMutex.withLock {
            val queued = waiters.minWithOrNull(
                compareBy<QueuedRequest> { it.priority.rank }
                    .thenBy { it.sequence }
            )
            if (queued != null) {
                waiters.remove(queued)
            } else {
                isCameraReadActive = false
            }
            queued
        }
        next?.gate?.complete(Unit)
    }

    private data class QueuedRequest(
        val priority: GalleryRequestPriority,
        val sequence: Long,
        val gate: CompletableDeferred<Unit>,
    )
}
