package com.camtransfer.viewmodel

import com.camtransfer.model.CameraFile
import com.camtransfer.model.CameraFileFormatHint
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpObjectFormat
import com.camtransfer.viewmodel.gallery.GalleryBrowseMode
import com.camtransfer.viewmodel.gallery.GalleryBrowseModeController
import com.camtransfer.viewmodel.gallery.HighDefinitionPreviewSessionPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class GalleryBrowseModeControllerTest {
    @Test
    fun defaultsToThumbnailModeAndTodayDate() {
        val controller = GalleryBrowseModeController(todayProvider = { LocalDate.of(2026, 7, 3) })

        assertEquals(GalleryBrowseMode.THUMBNAIL, controller.state.value.mode)
        assertEquals(LocalDate.of(2026, 7, 3), controller.state.value.highDefinitionDate)
    }

    @Test
    fun switchingModeDoesNotResetSelectedHighDefinitionDate() {
        val controller = GalleryBrowseModeController(todayProvider = { LocalDate.of(2026, 7, 3) })

        controller.setHighDefinitionDate(LocalDate.of(2026, 7, 1))
        controller.setMode(GalleryBrowseMode.HD_PREVIEW)
        controller.setMode(GalleryBrowseMode.THUMBNAIL)

        assertEquals(LocalDate.of(2026, 7, 1), controller.state.value.highDefinitionDate)
    }

    @Test
    fun previewSessionPolicyKeepsOnlyDisplayFilesForActiveDate() {
        val activeDate = LocalDate.of(2026, 7, 3)
        val files = listOf(
            cameraFile(handle = 1, filename = "DSCF0001.JPG", captureDate = "20260703T101010"),
            cameraFile(handle = 2, filename = "DSCF0002.HEIF", captureDate = "20260703T111010", format = PtpObjectFormat.HEIF),
            cameraFile(handle = 3, filename = "DSCF0003.RAF", captureDate = "20260703T121010", format = PtpObjectFormat.CAMERA_VENDOR_RAF),
            cameraFile(handle = 4, filename = "DSCF0004.JPG", captureDate = "20260702T101010"),
            cameraFile(handle = 5, filename = "DSCF0005.MOV", captureDate = "20260703T131010", format = PtpObjectFormat.MOV),
        )

        val previewFiles = HighDefinitionPreviewSessionPolicy.previewableFilesForDate(files, activeDate)

        assertEquals(listOf(1, 2), previewFiles.map { it.info.handle })
    }

    @Test
    fun previewItemsPairRawSidecarWithDisplayFile() {
        val activeDate = LocalDate.of(2026, 7, 3)
        val files = listOf(
            cameraFile(handle = 10, filename = "DSCF0010.RAF", captureDate = "20260703T101010", format = PtpObjectFormat.CAMERA_VENDOR_RAF),
            cameraFile(handle = 11, filename = "DSCF0010.JPG", captureDate = "20260703T101010"),
            cameraFile(handle = 12, filename = "DSCF0011.HEIF", captureDate = "20260703T111010", format = PtpObjectFormat.HEIF),
            cameraFile(handle = 13, filename = "DSCF0011.RAF", captureDate = "20260703T111010", format = PtpObjectFormat.CAMERA_VENDOR_RAF),
        )

        val items = HighDefinitionPreviewSessionPolicy.previewItemsForDate(files, activeDate)

        assertEquals(listOf(11, 12), items.map { it.previewFile.info.handle })
        assertEquals(listOf(10, 13), items.map { it.rawFile?.info?.handle })
    }

    @Test
    fun preferredActiveDateFallsBackToLatestPreviewableCameraDate() {
        val currentDate = LocalDate.of(2026, 7, 4)
        val files = listOf(
            cameraFile(handle = 1, filename = "DSCF0001.JPG", captureDate = "20260702T101010"),
            cameraFile(handle = 2, filename = "DSCF0002.HEIF", captureDate = "20260703T101010", format = PtpObjectFormat.HEIF),
            cameraFile(handle = 3, filename = "DSCF0003.RAF", captureDate = "20260703T111010", format = PtpObjectFormat.CAMERA_VENDOR_RAF),
        )

        val preferred = HighDefinitionPreviewSessionPolicy.preferredActiveDate(files, currentDate)

        assertEquals(LocalDate.of(2026, 7, 3), preferred)
    }

    @Test
    fun previewItemsMergeAmbiguousHeifRawPlaceholdersWithoutWaitingForThumbnailMetadata() {
        val activeDate = LocalDate.of(2026, 6, 28)
        val files = (1..580).map { handle ->
            cameraFile(
                handle = handle,
                filename = "0x%08X".format(handle),
                captureDate = "20260628",
                format = PtpObjectFormat.UNDEFINED,
                formatHints = setOf(CameraFileFormatHint.HEIF, CameraFileFormatHint.RAW),
            )
        }

        val items = HighDefinitionPreviewSessionPolicy.previewItemsForDate(files, activeDate)

        assertEquals(290, items.size)
        assertEquals((580 downTo 2 step 2).toList(), items.map { it.previewFile.info.handle })
        assertEquals((579 downTo 1 step 2).toList(), items.map { it.rawFile?.info?.handle })
    }

    @Test
    fun ambiguousRawSidecarIsQueuedAsRawOnlyCandidate() {
        val activeDate = LocalDate.of(2026, 6, 28)
        val files = listOf(
            cameraFile(
                handle = 1806,
                filename = "0x0000070E",
                captureDate = "20260628",
                format = PtpObjectFormat.UNDEFINED,
                formatHints = setOf(CameraFileFormatHint.HEIF, CameraFileFormatHint.RAW),
            ),
            cameraFile(
                handle = 1805,
                filename = "0x0000070D",
                captureDate = "20260628",
                format = PtpObjectFormat.UNDEFINED,
                formatHints = setOf(CameraFileFormatHint.HEIF, CameraFileFormatHint.RAW),
            ),
        )

        val item = HighDefinitionPreviewSessionPolicy.previewItemsForDate(files, activeDate).single()

        assertEquals(setOf(CameraFileFormatHint.HEIF), item.previewFile.formatHints)
        assertEquals(setOf(CameraFileFormatHint.RAW), item.rawFile?.formatHints)
    }

    @Test
    fun availableDatesComeFromPlaceholdersBeforeFormatsAreResolved() {
        val files = listOf(
            cameraFile(
                handle = 1,
                filename = "0x00000001",
                captureDate = "20260628",
                format = PtpObjectFormat.UNDEFINED,
                formatHints = setOf(CameraFileFormatHint.HEIF, CameraFileFormatHint.RAW),
            ),
            cameraFile(
                handle = 2,
                filename = "0x00000002",
                captureDate = "20260620",
                format = PtpObjectFormat.UNDEFINED,
                formatHints = setOf(CameraFileFormatHint.HEIF, CameraFileFormatHint.RAW),
            ),
        )

        val dates = HighDefinitionPreviewSessionPolicy.availableDates(files)

        assertEquals(
            listOf(LocalDate.of(2026, 6, 28), LocalDate.of(2026, 6, 20)),
            dates,
        )
    }

    @Test
    fun previewSessionPrioritizesCurrentVisibleUnloadedHandle() {
        val activeDate = LocalDate.of(2026, 7, 3)
        val files = (1..6).map { handle ->
            cameraFile(
                handle = handle,
                filename = "DSCF%04d.JPG".format(handle),
                captureDate = "20260703T101010",
            )
        }
        val session = HighDefinitionPreviewSessionPolicy.build(files, activeDate)
            .prioritizeVisibleHandles(
                visibleHandles = listOf(5, 6),
                loadedHandles = setOf(1, 2),
                loadingHandles = setOf(3),
            )

        assertEquals(5, session.nextFile(loadedHandles = setOf(1, 2), loadingHandles = setOf(3))?.info?.handle)
    }

    @Test
    fun completingEarlierReadDoesNotOverrideVisiblePriority() {
        val activeDate = LocalDate.of(2026, 7, 3)
        val files = (1..6).map { handle ->
            cameraFile(
                handle = handle,
                filename = "DSCF%04d.JPG".format(handle),
                captureDate = "20260703T101010",
            )
        }
        val session = HighDefinitionPreviewSessionPolicy.build(files, activeDate)
            .prioritizeVisibleHandles(
                visibleHandles = listOf(5, 6),
                loadedHandles = emptySet(),
                loadingHandles = setOf(1),
            )
            .markLoaded(1)

        assertEquals(5, session.nextFile(loadedHandles = setOf(1), loadingHandles = emptySet())?.info?.handle)
    }

    @Test
    fun completingLowerScreenReadDoesNotOverrideUpwardVisiblePriority() {
        val activeDate = LocalDate.of(2026, 7, 3)
        val files = (8 downTo 1).map { handle ->
            cameraFile(
                handle = handle,
                filename = "DSCF%04d.JPG".format(handle),
                captureDate = "20260703T101010",
            )
        }
        val session = HighDefinitionPreviewSessionPolicy.build(files, activeDate)
            .prioritizeVisibleHandles(
                visibleHandles = listOf(7, 6),
                loadedHandles = emptySet(),
                loadingHandles = setOf(3),
            )
            .markLoaded(3)

        assertEquals(7, session.nextFile(loadedHandles = setOf(3), loadingHandles = emptySet())?.info?.handle)
    }

    @Test
    fun previewSessionLoadsOnlyVisibleWindowBeforeFallingIdle() {
        val activeDate = LocalDate.of(2026, 7, 3)
        val files = (1..40).map { handle ->
            cameraFile(
                handle = handle,
                filename = "DSCF%04d.JPG".format(handle),
                captureDate = "20260703T101010",
            )
        }
        val session = HighDefinitionPreviewSessionPolicy.build(files, activeDate)
            .prioritizeVisibleHandles(
                visibleHandles = listOf(10, 11),
                loadedHandles = emptySet(),
                loadingHandles = emptySet(),
            )
        val loadedWindow = (5..31).toSet()

        assertEquals(10, session.nextFile(loadedHandles = emptySet(), loadingHandles = emptySet())?.info?.handle)
        assertEquals(null, session.nextFile(loadedHandles = loadedWindow, loadingHandles = emptySet()))
    }

    @Test
    fun availableDatesAreUniqueAndDescending() {
        val files = listOf(
            cameraFile(handle = 1, filename = "DSCF0001.JPG", captureDate = "20260701T101010"),
            cameraFile(handle = 2, filename = "DSCF0002.JPG", captureDate = "20260703T101010"),
            cameraFile(handle = 3, filename = "DSCF0003.JPG", captureDate = "20260703T121010"),
            cameraFile(handle = 4, filename = "DSCF0004.JPG", captureDate = "20260702T101010"),
        )

        val availableDates = HighDefinitionPreviewSessionPolicy.availableDates(files)

        assertEquals(
            listOf(
                LocalDate.of(2026, 7, 3),
                LocalDate.of(2026, 7, 2),
                LocalDate.of(2026, 7, 1),
            ),
            availableDates,
        )
        assertTrue(availableDates.distinct().size == availableDates.size)
    }

    private fun cameraFile(
        handle: Int,
        filename: String,
        captureDate: String,
        format: Int = PtpObjectFormat.JPEG,
        formatHints: Set<CameraFileFormatHint> = emptySet(),
    ): CameraFile =
        CameraFile(
            info = ObjectInfo(
                handle = handle,
                storageId = 1,
                format = format,
                compressedSize = 1_000_000,
                thumbFormat = PtpObjectFormat.JPEG,
                thumbCompressedSize = 24_000,
                thumbPixWidth = 320,
                thumbPixHeight = 240,
                imagePixWidth = 6000,
                imagePixHeight = 4000,
                parentObject = 0,
                filename = filename,
                captureDate = captureDate,
            ),
            formatHints = formatHints,
        )
}
