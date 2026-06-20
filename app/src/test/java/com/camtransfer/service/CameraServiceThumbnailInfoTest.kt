package com.camtransfer.service

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class CameraServiceThumbnailInfoTest {
    @Test
    fun ptpGallerySourcePreservesObjectInfoFromThumbnailReads() {
        val gallerySource = listOf(
            File("src/main/java/com/camtransfer/service/gallery/PtpCameraGallerySource.kt"),
            File("app/src/main/java/com/camtransfer/service/gallery/PtpCameraGallerySource.kt"),
        ).first { it.exists() }.readText()

        assertTrue(gallerySource.contains("override suspend fun getThumbnailWithInfo"))
        assertTrue(gallerySource.contains("commands.getThumbWithInfo(handle)"))
        assertTrue(gallerySource.contains("file = info?.let(::CameraFile)"))
        assertTrue(gallerySource.contains("Thumbnail info handle="))
        assertTrue(gallerySource.contains("info?.orientation?.toString()"))
    }

    @Test
    fun cameraServiceDelegatesGalleryReadsToPtpGallerySource() {
        val serviceSource = listOf(
            File("src/main/java/com/camtransfer/service/CameraService.kt"),
            File("app/src/main/java/com/camtransfer/service/CameraService.kt"),
        ).first { it.exists() }.readText()

        assertTrue(serviceSource.contains("private val gallerySource"))
        assertTrue(serviceSource.contains("override suspend fun getThumbnailWithInfo(handle: Int)"))
        assertTrue(serviceSource.contains("gallerySource.getThumbnailWithInfo(handle)"))
    }
}
