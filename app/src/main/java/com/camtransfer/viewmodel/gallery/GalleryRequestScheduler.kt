package com.camtransfer.viewmodel.gallery

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
    private val cameraReadMutex = Mutex()

    suspend fun <T> run(
        priority: GalleryRequestPriority,
        block: suspend () -> T,
    ): T {
        @Suppress("UNUSED_VARIABLE")
        val explicitPriority = priority
        return cameraReadMutex.withLock {
            block()
        }
    }
}
