package com.camtransfer.viewmodel

import com.camtransfer.viewmodel.gallery.GalleryRequestPriority
import com.camtransfer.viewmodel.gallery.GalleryRequestScheduler
import com.camtransfer.viewmodel.gallery.GallerySessionActor
import kotlinx.coroutines.CompletableDeferred
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

    @Test
    fun visibleThumbnailRunsBeforeQueuedBackgroundMetadata() = runBlocking {
        val scheduler = GalleryRequestScheduler()
        val events = mutableListOf<String>()
        val releaseFirst = CompletableDeferred<Unit>()

        val first = async {
            scheduler.run(GalleryRequestPriority.BackgroundMetadata) {
                events += "first-background-start"
                releaseFirst.await()
                events += "first-background-end"
            }
        }
        delay(10)

        val background = async {
            scheduler.run(GalleryRequestPriority.BackgroundMetadata) {
                events += "queued-background"
            }
        }
        delay(10)

        val thumbnail = async {
            scheduler.run(GalleryRequestPriority.VisibleThumbnail) {
                events += "visible-thumbnail"
            }
        }
        delay(10)

        releaseFirst.complete(Unit)
        first.await()
        background.await()
        thumbnail.await()

        assertEquals(
            listOf(
                "first-background-start",
                "first-background-end",
                "visible-thumbnail",
                "queued-background",
            ),
            events,
        )
    }

    @Test
    fun sessionActorHoldsGalleryReadsDuringTransferExclusive() = runBlocking {
        val actor = GallerySessionActor()
        val events = mutableListOf<String>()

        actor.enterTransferExclusive()
        val thumbnail = async {
            actor.run(GalleryRequestPriority.VisibleThumbnail) {
                events += "thumbnail"
            }
        }
        delay(GallerySessionActor.EXCLUSIVE_GATE_POLL_MS * 2)

        assertEquals(emptyList<String>(), events)

        actor.exitTransferExclusive()
        thumbnail.await()

        assertEquals(listOf("thumbnail"), events)
    }
}
