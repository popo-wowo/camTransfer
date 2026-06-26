package com.camtransfer.viewmodel

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class GalleryModularArchitectureTest {
    @Test
    fun galleryControllersAreSplitByFeature() {
        val controllerFiles = listOf(
            "viewmodel/gallery/GalleryRequestScheduler.kt",
            "viewmodel/gallery/GalleryFilesController.kt",
            "viewmodel/gallery/GalleryThumbnailController.kt",
            "viewmodel/gallery/GalleryPreviewController.kt",
            "viewmodel/gallery/GallerySelectionController.kt",
        )

        controllerFiles.forEach { path ->
            assertTrue("Missing gallery controller file: $path", sourceFile(path).exists())
        }
    }

    @Test
    fun browseViewModelDelegatesGalleryFeatureWorkToControllers() {
        val source = sourceFile("viewmodel/BrowseViewModel.kt").readText()

        assertTrue(source.contains("GalleryFilesController"))
        assertTrue(source.contains("GalleryThumbnailController"))
        assertTrue(source.contains("GalleryPreviewController"))
        assertTrue(source.contains("GallerySelectionController"))
        assertTrue(source.contains("filesController.pauseForExclusiveOperation"))
        assertTrue(source.contains("filesController.resumeAfterExclusiveOperation"))
        assertFalse(source.contains("class ThumbnailLoadQueue"))
        assertFalse(source.contains("private val thumbnailQueue"))
        assertFalse(source.contains("private val previewImageCache"))
    }

    @Test
    fun galleryUiDoesNotImportCameraProtocolOrConnectionModules() {
        val uiRoot = listOf(
            File("src/main/java/com/camtransfer/ui"),
            File("app/src/main/java/com/camtransfer/ui"),
        ).first { it.exists() }
        val uiFiles = uiRoot
            .walkTopDown()
            .filter { it.isFile && it.name.startsWith("Gallery") && it.extension == "kt" }
            .toList()

        assertTrue("Expected split Gallery UI files", uiFiles.size >= 5)
        uiFiles.forEach { file ->
            val source = file.readText()
            assertFalse("${file.name} imports PTP commands", source.contains("com.camtransfer.protocol.PtpCommands"))
            assertFalse("${file.name} imports PTP connection", source.contains("com.camtransfer.protocol.PtpConnection"))
            assertFalse("${file.name} imports BLE", source.contains("com.camtransfer.ble"))
            assertFalse("${file.name} imports Wi-Fi", source.contains("com.camtransfer.wifi"))
            assertFalse("${file.name} imports connection module", source.contains("com.camtransfer.service.connection"))
        }
    }

    private fun sourceFile(path: String): File =
        listOf(
            File("src/main/java/com/camtransfer/$path"),
            File("app/src/main/java/com/camtransfer/$path"),
        ).firstOrNull { it.exists() } ?: File("app/src/main/java/com/camtransfer/$path")
}
