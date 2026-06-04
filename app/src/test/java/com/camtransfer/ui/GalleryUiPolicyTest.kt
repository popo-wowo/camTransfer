package com.camtransfer.ui

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferState
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class GalleryUiPolicyTest {
    @Test
    fun defaultFilterShowsAllDatesAndAllFormats() {
        val today = LocalDate.of(2026, 5, 29)
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260529T081500"),
            file(2, PtpObjectFormat.HEIF, "20260529T091500"),
            file(3, PtpObjectFormat.CAMERA_VENDOR_RAF, "20260529T101500"),
            file(4, PtpObjectFormat.MP4, "20260529T111500"),
            file(5, PtpObjectFormat.JPEG, "20260528T081500"),
        )

        val filtered = GalleryUiPolicy.filteredFiles(files, GalleryFilterState(), today)

        assertEquals(listOf(1, 2, 3, 4, 5), filtered.map { it.info.handle })
    }

    @Test
    fun selectedDayFilterUsesChosenCaptureDateAcrossAllFormatsByDefault() {
        val today = LocalDate.of(2026, 5, 29)
        val state = GalleryFilterState(date = GalleryDateFilter.SpecificDay(LocalDate.of(2026, 5, 28)))
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260529T081500"),
            file(2, PtpObjectFormat.HEIF, "20260528T091500"),
            file(3, PtpObjectFormat.MP4, "20260528T101500"),
        )

        val filtered = GalleryUiPolicy.filteredFiles(files, state, today)

        assertEquals(listOf(2, 3), filtered.map { it.info.handle })
    }

    @Test
    fun dateRangeFilterIncludesPhotosWithinInclusiveRange() {
        val today = LocalDate.of(2026, 5, 29)
        val state = GalleryFilterState(
            date = GalleryDateFilter.Range(
                start = LocalDate.of(2026, 5, 20),
                end = LocalDate.of(2026, 5, 28),
            )
        )
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260519T081500"),
            file(2, PtpObjectFormat.JPEG, "20260520T091500"),
            file(3, PtpObjectFormat.JPEG, "20260525T101500"),
            file(4, PtpObjectFormat.JPEG, "20260528T111500"),
            file(5, PtpObjectFormat.JPEG, "20260529T121500"),
        )

        val filtered = GalleryUiPolicy.filteredFiles(files, state, today)

        assertEquals(listOf(2, 3, 4), filtered.map { it.info.handle })
    }

    @Test
    fun dateRangeFilterNormalizesReversedStartAndEnd() {
        val today = LocalDate.of(2026, 5, 29)
        val state = GalleryFilterState(
            date = GalleryDateFilter.Range(
                start = LocalDate.of(2026, 5, 28),
                end = LocalDate.of(2026, 5, 20),
            )
        )
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260520T091500"),
            file(2, PtpObjectFormat.JPEG, "20260528T111500"),
            file(3, PtpObjectFormat.JPEG, "20260529T121500"),
        )

        val filtered = GalleryUiPolicy.filteredFiles(files, state, today)

        assertEquals(listOf(1, 2), filtered.map { it.info.handle })
    }

    @Test
    fun multiFormatFilterIncludesRawAndVideoWhenSelected() {
        val today = LocalDate.of(2026, 5, 29)
        val state = GalleryFilterState(
            formats = setOf(GalleryFormatFilter.Raw, GalleryFormatFilter.Video),
        )
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260529T081500"),
            file(2, PtpObjectFormat.CAMERA_VENDOR_RAF, "20260529T091500"),
            file(3, PtpObjectFormat.MP4, "20260529T101500"),
        )

        val filtered = GalleryUiPolicy.filteredFiles(files, state, today)

        assertEquals(listOf(2, 3), filtered.map { it.info.handle })
    }

    @Test
    fun sortModesOrderByNewestOldestAndNotDownloadedFirst() {
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260529T081500"),
            file(2, PtpObjectFormat.JPEG, "20260529T101500"),
            file(3, PtpObjectFormat.JPEG, "20260528T111500"),
            file(4, PtpObjectFormat.JPEG, "20260529T091500"),
        )
        val downloadedStates = mapOf(
            2 to TransferState.DONE,
            4 to TransferState.DOWNLOADING,
        )

        assertEquals(
            listOf(2, 4, 1, 3),
            GallerySortPolicy.sortedFiles(files, GallerySortMode.NewestFirst, downloadedStates).map { it.info.handle },
        )
        assertEquals(
            listOf(3, 1, 4, 2),
            GallerySortPolicy.sortedFiles(files, GallerySortMode.OldestFirst, downloadedStates).map { it.info.handle },
        )
        assertEquals(
            listOf(1, 3, 2, 4),
            GallerySortPolicy.sortedFiles(files, GallerySortMode.NotDownloadedFirst, downloadedStates).map { it.info.handle },
        )
    }

    @Test
    fun listControlsResetGalleryScrollToFirstItem() {
        assertTrue(GalleryScrollResetPolicy.shouldScrollToTopAfterFilterOrSortChange())
    }

    @Test
    fun filterPanelDefaultsCollapsedAndSummarizesActiveControls() {
        assertFalse(GalleryFilterPanelPolicy.defaultExpanded())
        assertEquals(
            "全部日期 · 全部格式 · 最新优先",
            GalleryFilterPanelPolicy.summary(
                state = GalleryFilterState(),
                sortMode = GallerySortMode.NewestFirst,
            ),
        )
        assertEquals(
            "05-20~05-28 · JPG/RAW · 未下载优先",
            GalleryFilterPanelPolicy.summary(
                state = GalleryFilterState(
                    date = GalleryDateFilter.Range(
                        start = LocalDate.of(2026, 5, 28),
                        end = LocalDate.of(2026, 5, 20),
                    ),
                    formats = setOf(GalleryFormatFilter.Jpg, GalleryFormatFilter.Raw),
                ),
                sortMode = GallerySortMode.NotDownloadedFirst,
            ),
        )
    }

    @Test
    fun activeAndSavedDownloadsAreNotSelectableAgain() {
        assertTrue(GalleryDownloadUiPolicy.canSelect(TransferState.ERROR))
        assertTrue(GalleryDownloadUiPolicy.canSelect(null))
        assertFalse(GalleryDownloadUiPolicy.canSelect(TransferState.PENDING))
        assertFalse(GalleryDownloadUiPolicy.canSelect(TransferState.DOWNLOADING))
        assertFalse(GalleryDownloadUiPolicy.canSelect(TransferState.SAVING))
        assertFalse(GalleryDownloadUiPolicy.canSelect(TransferState.DONE))
    }

    @Test
    fun galleryBackActionRequiresDisconnectConfirmation() {
        assertTrue(GalleryDisconnectPolicy.shouldConfirmBeforeDisconnect())
        assertEquals("确认断开相机连接？", GalleryDisconnectPolicy.confirmTitle)
        assertTrue(GalleryDisconnectPolicy.confirmMessage.contains("保持在照片筛选页面"))
        assertTrue(GalleryDisconnectPolicy.confirmMessage.contains("不会断开相机通讯"))
    }

    @Test
    fun dragSelectionAddsOrRemovesOnlySelectableHandles() {
        assertTrue(GalleryDragSelectionPolicy.shouldSelectForDrag(startHandleSelected = false))
        assertFalse(GalleryDragSelectionPolicy.shouldSelectForDrag(startHandleSelected = true))
        assertTrue(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 18f, deltaY = 4f, touchSlop = 8f))
        assertTrue(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 12f, deltaY = 10f, touchSlop = 8f))
        assertFalse(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 3f, deltaY = 2f, touchSlop = 8f))
        assertFalse(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 3f, deltaY = 18f, touchSlop = 8f))

        assertEquals(
            setOf(1, 2),
            GalleryDragSelectionPolicy.updatedSelection(
                currentSelection = setOf(1),
                handle = 2,
                downloadState = null,
                shouldSelect = true,
            ),
        )
        assertEquals(
            setOf(1),
            GalleryDragSelectionPolicy.updatedSelection(
                currentSelection = setOf(1, 2),
                handle = 2,
                downloadState = null,
                shouldSelect = false,
            ),
        )
        assertEquals(
            setOf(1),
            GalleryDragSelectionPolicy.updatedSelection(
                currentSelection = setOf(1),
                handle = 3,
                downloadState = TransferState.DONE,
                shouldSelect = true,
            ),
        )
    }

    @Test
    fun columnLayoutPolicyMapsPinchScaleToTwoThroughFiveColumns() {
        assertEquals(2, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 3, pinchScale = 1.5f))
        assertEquals(4, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 3, pinchScale = 0.65f))
        assertEquals(3, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 3, pinchScale = 1.1f))
        assertEquals(2, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 2, pinchScale = 1.7f))
        assertEquals(5, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 5, pinchScale = 0.5f))
    }

    @Test
    fun previewNavigationStartsAtSelectedHandleAndClampsMissingHandle() {
        val files = listOf(
            file(10, PtpObjectFormat.JPEG, "20260529T081500"),
            file(20, PtpObjectFormat.JPEG, "20260529T091500"),
            file(30, PtpObjectFormat.JPEG, "20260529T101500"),
        )

        assertEquals(1, GalleryPreviewNavigationPolicy.initialPage(files, selectedHandle = 20))
        assertEquals(0, GalleryPreviewNavigationPolicy.initialPage(files, selectedHandle = 99))
    }

    @Test
    fun previewRotationPolicyReadsJpegExifOrientation() {
        assertEquals(90, GalleryPreviewRotationPolicy.exifRotationDegrees(jpegWithExifOrientation(6)))
        assertEquals(180, GalleryPreviewRotationPolicy.exifRotationDegrees(jpegWithExifOrientation(3)))
        assertEquals(270, GalleryPreviewRotationPolicy.exifRotationDegrees(jpegWithExifOrientation(8)))
        assertEquals(null, GalleryPreviewRotationPolicy.exifRotationDegrees(jpegWithExifOrientation(1)))
    }

    @Test
    fun previewRotationPolicyFallsBackToObjectAndDecodedDimensions() {
        val portrait = file(
            handle = 40,
            format = PtpObjectFormat.JPEG,
            captureDate = "20260529T111500",
            imageWidth = 3000,
            imageHeight = 4000,
        )
        val landscape = file(
            handle = 50,
            format = PtpObjectFormat.JPEG,
            captureDate = "20260529T111500",
            imageWidth = 4000,
            imageHeight = 3000,
        )

        assertEquals(
            90,
            GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = portrait,
                decodedWidth = 160,
                decodedHeight = 120,
                imageData = ByteArray(0),
            ),
        )
        assertEquals(
            0,
            GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = landscape,
                decodedWidth = 160,
                decodedHeight = 120,
                imageData = ByteArray(0),
            ),
        )
    }

    @Test
    fun previewRotationPolicyDoesNotDoubleRotateExifImageAlreadyDecodedPortrait() {
        val portraitWithLandscapePixelMetadata = file(
            handle = 60,
            format = PtpObjectFormat.JPEG,
            captureDate = "20260529T111500",
            imageWidth = 4000,
            imageHeight = 3000,
        )

        assertEquals(
            0,
            GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = portraitWithLandscapePixelMetadata,
                decodedWidth = 120,
                decodedHeight = 160,
                imageData = jpegWithExifOrientation(6),
            ),
        )
    }

    @Test
    fun previewRotationPolicyAppliesExifWhenDecodedBitmapIsStillLandscape() {
        val portraitWithLandscapePixelMetadata = file(
            handle = 70,
            format = PtpObjectFormat.JPEG,
            captureDate = "20260529T111500",
            imageWidth = 4000,
            imageHeight = 3000,
        )

        assertEquals(
            90,
            GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = portraitWithLandscapePixelMetadata,
                decodedWidth = 160,
                decodedHeight = 120,
                imageData = jpegWithExifOrientation(6),
            ),
        )
    }

    @Test
    fun previewRotationPolicyCyclesManualClockwiseRotation() {
        assertEquals(90, GalleryPreviewRotationPolicy.nextManualRotationDegrees(0))
        assertEquals(180, GalleryPreviewRotationPolicy.nextManualRotationDegrees(90))
        assertEquals(270, GalleryPreviewRotationPolicy.nextManualRotationDegrees(180))
        assertEquals(0, GalleryPreviewRotationPolicy.nextManualRotationDegrees(270))
    }

    @Test
    fun thumbnailDiagnosticSummaryReportsThumbnailOrientationEvidence() {
        val summary = GalleryThumbnailDiagnosticPolicy.summary(
            handle = 80,
            file = file(handle = 80, format = PtpObjectFormat.CAMERA_VENDOR_RAF, captureDate = "20260529T111500"),
            thumbnail = jpegWithExifOrientation(6),
            decodedWidth = 160,
            decodedHeight = 120,
        )

        assertTrue(summary.contains("handle=80"))
        assertTrue(summary.contains("bytes="))
        assertTrue(summary.contains("thumbExifRotation=90"))
        assertTrue(summary.contains("decoded=160x120"))
        assertTrue(summary.contains("object=4000x3000"))
        assertTrue(summary.contains("thumbInfo=160x120"))
        assertTrue(summary.contains("autoRotation=90"))
    }

    private fun file(handle: Int, format: Int, captureDate: String): CameraFile =
        file(
            handle = handle,
            format = format,
            captureDate = captureDate,
            imageWidth = 4000,
            imageHeight = 3000,
        )

    private fun file(
        handle: Int,
        format: Int,
        captureDate: String,
        imageWidth: Int,
        imageHeight: Int,
    ): CameraFile =
        CameraFile(
            ObjectInfo(
                handle = handle,
                storageId = 1,
                format = format,
                compressedSize = 1024,
                thumbFormat = PtpObjectFormat.JPEG,
                thumbCompressedSize = 128,
                thumbPixWidth = 160,
                thumbPixHeight = 120,
                imagePixWidth = imageWidth,
                imagePixHeight = imageHeight,
                parentObject = 0,
                filename = "DSCF%04d.JPG".format(handle),
                captureDate = captureDate,
            )
        )

    private fun jpegWithExifOrientation(orientation: Int): ByteArray {
        val tiff = byteArrayOf(
            0x49, 0x49, 0x2A, 0x00,
            0x08, 0x00, 0x00, 0x00,
            0x01, 0x00,
            0x12, 0x01,
            0x03, 0x00,
            0x01, 0x00, 0x00, 0x00,
            orientation.toByte(), 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        )
        val exif = "Exif\u0000\u0000".toByteArray(Charsets.US_ASCII) + tiff
        val length = exif.size + 2
        return byteArrayOf(
            0xFF.toByte(), 0xD8.toByte(),
            0xFF.toByte(), 0xE1.toByte(),
            (length shr 8).toByte(),
            length.toByte(),
        ) + exif + byteArrayOf(0xFF.toByte(), 0xD9.toByte())
    }
}
