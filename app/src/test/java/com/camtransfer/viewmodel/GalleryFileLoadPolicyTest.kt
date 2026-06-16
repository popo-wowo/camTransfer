package com.camtransfer.viewmodel

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GalleryFileLoadPolicyTest {
    @Test
    fun doesNotLoadAgainWhenSameSourceAlreadyLoaded() {
        val source = Any()

        assertFalse(
            GalleryFileLoadPolicy.shouldLoad(
                currentSource = source,
                loadedSource = source,
                isLoading = false,
                lastLoadFailed = false,
            )
        )
    }

    @Test
    fun loadsWhenSourceChanges() {
        assertTrue(
            GalleryFileLoadPolicy.shouldLoad(
                currentSource = Any(),
                loadedSource = Any(),
                isLoading = false,
                lastLoadFailed = false,
            )
        )
    }

    @Test
    fun allowsRetryAfterFailedLoad() {
        val source = Any()

        assertTrue(
            GalleryFileLoadPolicy.shouldLoad(
                currentSource = source,
                loadedSource = source,
                isLoading = false,
                lastLoadFailed = true,
            )
        )
    }

    @Test
    fun doesNotStartDuplicateLoadWhileLoading() {
        assertFalse(
            GalleryFileLoadPolicy.shouldLoad(
                currentSource = Any(),
                loadedSource = null,
                isLoading = true,
                lastLoadFailed = false,
            )
        )
    }

    @Test
    fun publishesInitialPlaceholdersBeforeFullObjectInfoOnlyWhenListIsEmpty() {
        val initialFiles = listOf(cameraFile(handle = 2))

        assertTrue(
            GalleryFastInitialLoadPolicy.shouldPublishInitialFiles(
                currentFiles = emptyList(),
                initialFiles = initialFiles,
            )
        )
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldPublishInitialFiles(
                currentFiles = listOf(cameraFile(handle = 1)),
                initialFiles = initialFiles,
            )
        )
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldPublishInitialFiles(
                currentFiles = emptyList(),
                initialFiles = emptyList(),
            )
        )
    }

    @Test
    fun fullObjectInfoKeepsThumbnailsLoadedDuringInitialPlaceholderPhase() {
        val existingThumb = byteArrayOf(0x01, 0x02)
        val fullThumb = byteArrayOf(0x03, 0x04)
        val fullFiles = listOf(
            cameraFile(handle = 10, filename = "DSCF0010.RAF"),
            cameraFile(handle = 11, filename = "DSCF0011.JPG", thumbnail = fullThumb),
        )

        val merged = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
            currentFiles = listOf(cameraFile(handle = 10, filename = "0x0000000A.JPG", thumbnail = existingThumb)),
            fullFiles = fullFiles,
        )

        assertEquals("DSCF0010.RAF", merged[0].info.filename)
        assertArrayEquals(existingThumb, merged[0].thumbnail)
        assertSame(fullThumb, merged[1].thumbnail)
    }

    @Test
    fun fullObjectInfoKeepsThumbnailsFromHandleCache() {
        val cachedThumb = byteArrayOf(0x05, 0x06)

        val merged = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
            currentFiles = emptyList(),
            fullFiles = listOf(cameraFile(handle = 12, filename = "DSCF0012.JPG")),
            thumbnailsByHandle = mapOf(12 to cachedThumb),
        )

        assertArrayEquals(cachedThumb, merged.single().thumbnail)
    }

    @Test
    fun partialFullObjectInfoDoesNotDropPlaceholderHandlesForLargeGallery() {
        val placeholders = (1..999).map { handle ->
            cameraFile(handle = handle, filename = "0x%08X.JPG".format(handle))
        }.sortedByDescending { it.info.handle }
        val fullInfos = (800..999).map { handle ->
            cameraFile(handle = handle, filename = "DSCF%04d.JPG".format(handle))
        }.sortedByDescending { it.info.handle }

        val merged = GalleryFastInitialLoadPolicy.mergeWithExistingThumbnails(
            currentFiles = placeholders,
            fullFiles = fullInfos,
        )

        assertEquals(999, merged.size)
        assertEquals("DSCF0999.JPG", merged.first().info.filename)
        assertEquals("0x00000001.JPG", merged.last().info.filename)
    }

    @Test
    fun defersFullObjectInfoWhenLargePlaceholderListCanShowFirstScreen() {
        assertTrue(
            GalleryFastInitialLoadPolicy.shouldDeferFullObjectInfoUntilAfterThumbnails(
                initialFileCount = 1000,
            )
        )
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldDeferFullObjectInfoUntilAfterThumbnails(
                initialFileCount = 200,
            )
        )
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldDeferFullObjectInfoUntilAfterThumbnails(
                initialFileCount = 0,
            )
        )
    }

    @Test
    fun doesNotStartFullObjectInfoAutomaticallyAfterLargeGalleryPlaceholdersArePublished() {
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldContinueFullObjectInfoAfterInitialPlaceholders(
                initialFileCount = 1000,
            )
        )
        assertTrue(
            GalleryFastInitialLoadPolicy.shouldContinueFullObjectInfoAfterInitialPlaceholders(
                initialFileCount = 200,
            )
        )
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldContinueFullObjectInfoAfterInitialPlaceholders(
                initialFileCount = 0,
            )
        )
    }

    @Test
    fun limitsInitialThumbnailRequestsWhileFullObjectInfoIsStillLoading() {
        assertTrue(
            GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isLoadingFullObjectInfo = true,
                hasThumbnail = false,
                activeOrPendingThumbnailCount = GalleryFastInitialLoadPolicy.MAX_INITIAL_THUMBNAIL_REQUESTS - 1,
            )
        )
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isLoadingFullObjectInfo = true,
                hasThumbnail = false,
                activeOrPendingThumbnailCount = GalleryFastInitialLoadPolicy.MAX_INITIAL_THUMBNAIL_REQUESTS,
            )
        )
        assertTrue(
            GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isLoadingFullObjectInfo = false,
                hasThumbnail = false,
                activeOrPendingThumbnailCount = 200,
            )
        )
        assertFalse(
            GalleryFastInitialLoadPolicy.shouldLoadThumbnail(
                isLoadingFullObjectInfo = false,
                hasThumbnail = true,
                activeOrPendingThumbnailCount = 0,
            )
        )
    }

    private fun cameraFile(
        handle: Int,
        filename: String = "DSCF%04d.JPG".format(handle),
        thumbnail: ByteArray? = null,
    ): CameraFile = CameraFile(
        info = ObjectInfo(
            handle = handle,
            storageId = 1,
            format = PtpObjectFormat.JPEG,
            compressedSize = 1024,
            thumbFormat = PtpObjectFormat.JPEG,
            thumbCompressedSize = 128,
            thumbPixWidth = 160,
            thumbPixHeight = 120,
            imagePixWidth = 4000,
            imagePixHeight = 3000,
            parentObject = 0,
            filename = filename,
            captureDate = "20260604T120000",
        ),
        thumbnail = thumbnail,
    )
}
