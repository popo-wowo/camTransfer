package com.camtransfer.viewmodel

import com.camtransfer.viewmodel.gallery.GalleryRequestPriority
import com.camtransfer.viewmodel.gallery.GalleryRequestScheduler
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GalleryRequestSchedulerTest {
    @Test
    fun requestPrioritiesDocumentCameraReadOrdering() {
        assertTrue(GalleryRequestPriority.DownloadOriginal.rank < GalleryRequestPriority.PreviewImage.rank)
        assertTrue(GalleryRequestPriority.PreviewImage.rank < GalleryRequestPriority.VisibleThumbnail.rank)
        assertTrue(GalleryRequestPriority.VisibleThumbnail.rank < GalleryRequestPriority.PreviewNeighborThumbnail.rank)
        assertTrue(GalleryRequestPriority.PreviewNeighborThumbnail.rank < GalleryRequestPriority.BackgroundMetadata.rank)
    }

    @Test
    fun schedulerSerializesCameraReads() = runBlocking {
        val scheduler = GalleryRequestScheduler()
        val events = mutableListOf<String>()

        val first = async {
            scheduler.run(GalleryRequestPriority.VisibleThumbnail) {
                events += "first-start"
                delay(30)
                events += "first-end"
            }
        }
        val second = async {
            scheduler.run(GalleryRequestPriority.PreviewImage) {
                events += "second-start"
                events += "second-end"
            }
        }

        first.await()
        second.await()

        assertEquals(
            listOf("first-start", "first-end", "second-start", "second-end"),
            events,
        )
    }
}
