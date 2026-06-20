package com.camtransfer.ui

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferState
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertArrayEquals
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
    fun activeDateFilterDoesNotMatchFilesWithUnknownCaptureDate() {
        val today = LocalDate.of(2026, 5, 29)
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, ""),
            file(2, PtpObjectFormat.JPEG, "20260529T091500"),
            file(3, PtpObjectFormat.JPEG, "20260528T101500"),
        )

        assertEquals(
            listOf(1, 2, 3),
            GalleryUiPolicy.filteredFiles(files, GalleryFilterState(), today).map { it.info.handle },
        )
        assertEquals(
            listOf(2),
            GalleryUiPolicy.filteredFiles(
                files,
                GalleryFilterState(date = GalleryDateFilter.Today),
                today,
            ).map { it.info.handle },
        )
        assertEquals(
            listOf(3),
            GalleryUiPolicy.filteredFiles(
                files,
                GalleryFilterState(date = GalleryDateFilter.SpecificDay(LocalDate.of(2026, 5, 28))),
                today,
            ).map { it.info.handle },
        )
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
    fun visibleThumbnailRequestsCanStartBeforeFullObjectInfoFinishes() {
        assertTrue(
            GalleryThumbnailVisibilityPolicy.shouldRequestThumbnail(
                isItemVisible = true,
                isLoadingFullObjectInfo = true,
                hasThumbnail = false,
            )
        )
        assertTrue(
            GalleryThumbnailVisibilityPolicy.shouldRequestThumbnail(
                isItemVisible = true,
                isLoadingFullObjectInfo = false,
                hasThumbnail = false,
            )
        )
        assertFalse(
            GalleryThumbnailVisibilityPolicy.shouldRequestThumbnail(
                isItemVisible = true,
                isLoadingFullObjectInfo = false,
                hasThumbnail = true,
            )
        )
    }

    @Test
    fun offscreenThumbnailRequestsDoNotStartFromLazyGridPrefetch() {
        assertFalse(
            GalleryThumbnailVisibilityPolicy.shouldRequestThumbnail(
                isItemVisible = false,
                isLoadingFullObjectInfo = false,
                hasThumbnail = false,
            )
        )
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
    fun dateMetadataPolicyLoadsMetadataWhenDateFilterNeedsRealCaptureDates() {
        val placeholders = listOf(
            file(1, PtpObjectFormat.JPEG, ""),
            file(2, PtpObjectFormat.JPEG, ""),
        )
        val filesWithKnownDate = placeholders + file(3, PtpObjectFormat.JPEG, "20260529T101500")

        assertFalse(
            GalleryDateMetadataPolicy.shouldLoadMetadataForDateFilter(
                files = placeholders,
                dateFilter = GalleryDateFilter.All,
            )
        )
        assertTrue(
            GalleryDateMetadataPolicy.shouldLoadMetadataForDateFilter(
                files = placeholders,
                dateFilter = GalleryDateFilter.Today,
            )
        )
        assertTrue(GalleryDateMetadataPolicy.shouldLoadMetadataForDatePicker(placeholders))
        assertFalse(
            GalleryDateMetadataPolicy.shouldLoadMetadataForDateFilter(
                files = filesWithKnownDate,
                dateFilter = GalleryDateFilter.Today,
            )
        )
        assertFalse(GalleryDateMetadataPolicy.shouldLoadMetadataForDatePicker(filesWithKnownDate))
    }

    @Test
    fun dateDialogPolicyDistinguishesLoadingMetadataFromNoRecognizedDates() {
        assertEquals(
            "正在读取相机照片日期...",
            GalleryDateDialogPolicy.emptyMessage(isLoadingMetadata = true),
        )
        assertEquals(
            "相机文件里没有可识别日期",
            GalleryDateDialogPolicy.emptyMessage(isLoadingMetadata = false),
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
    fun downloadRecordCleanupLivesInDownloadCenterNotGalleryHeader() {
        assertFalse(GalleryHeaderActionPolicy.shouldShowClearDownloadRecords)
        assertEquals("清理记录", DownloadCenterActionPolicy.clearDownloadRecordsLabel)
    }

    @Test
    fun dragSelectionAddsOrRemovesOnlySelectableHandles() {
        assertTrue(GalleryDragSelectionPolicy.shouldSelectForDrag(startHandleSelected = false))
        assertFalse(GalleryDragSelectionPolicy.shouldSelectForDrag(startHandleSelected = true))
        assertTrue(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 18f, deltaY = 4f, touchSlop = 8f))
        assertTrue(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 12f, deltaY = 10f, touchSlop = 8f))
        assertFalse(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 3f, deltaY = 2f, touchSlop = 8f))
        assertFalse(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 3f, deltaY = 18f, touchSlop = 8f))
        assertTrue(
            GalleryDragSelectionPolicy.shouldStartDragSelection(
                deltaX = 3f,
                deltaY = 18f,
                touchSlop = 8f,
                selectionActive = true,
            )
        )

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
    fun dragSelectionSelectsContiguousRangeAcrossRowsSkippingUnavailableHandles() {
        val handles = (1..12).toList()
        val downloadStates = mapOf(
            5 to TransferState.DONE,
            8 to TransferState.DOWNLOADING,
        )

        assertEquals(
            setOf(2, 3, 4, 6, 7, 9),
            GalleryDragSelectionPolicy.updatedRangeSelection(
                currentSelection = emptySet(),
                orderedHandles = handles,
                startHandle = 2,
                endHandle = 9,
                downloadStates = downloadStates,
                shouldSelect = true,
            ),
        )
    }

    @Test
    fun dragSelectionCanRemoveContiguousRangeAcrossRows() {
        val handles = (1..12).toList()

        assertEquals(
            setOf(1, 10, 11, 12),
            GalleryDragSelectionPolicy.updatedRangeSelection(
                currentSelection = handles.toSet(),
                orderedHandles = handles,
                startHandle = 2,
                endHandle = 9,
                downloadStates = emptyMap(),
                shouldSelect = false,
            ),
        )
    }

    @Test
    fun dragSelectionAutoScrollsNearViewportEdgesOnly() {
        assertEquals(
            -30f,
            GalleryDragSelectionPolicy.autoScrollDelta(
                pointerY = 0f,
                viewportStart = 0f,
                viewportEnd = 600f,
                edgeSize = 80f,
                maxDelta = 30f,
            ),
        )
        assertEquals(
            30f,
            GalleryDragSelectionPolicy.autoScrollDelta(
                pointerY = 600f,
                viewportStart = 0f,
                viewportEnd = 600f,
                edgeSize = 80f,
                maxDelta = 30f,
            ),
        )
        assertEquals(
            0f,
            GalleryDragSelectionPolicy.autoScrollDelta(
                pointerY = 300f,
                viewportStart = 0f,
                viewportEnd = 600f,
                edgeSize = 80f,
                maxDelta = 30f,
            ),
        )
    }

    @Test
    fun columnLayoutPolicyMapsPinchScaleToTwoThroughSixColumns() {
        assertEquals(2, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 3, pinchScale = 1.5f))
        assertEquals(4, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 3, pinchScale = 0.65f))
        assertEquals(3, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 3, pinchScale = 1.1f))
        assertEquals(2, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 2, pinchScale = 1.7f))
        assertEquals(6, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 5, pinchScale = 0.5f))
        assertEquals(6, GalleryColumnLayoutPolicy.targetColumns(currentColumns = 6, pinchScale = 0.5f))
    }

    @Test
    fun galleryGridSpacingKeepsPhotoGapsCompact() {
        assertEquals(5, GalleryGridSpacingPolicy.HORIZONTAL_DP)
        assertEquals(7, GalleryGridSpacingPolicy.VERTICAL_DP)
    }

    @Test
    fun thumbnailDecodePolicyDownsamplesFullSizeFallbackImages() {
        assertEquals(
            16,
            GalleryThumbnailDecodePolicy.sampleSize(
                width = 7728,
                height = 5152,
                maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
            ),
        )
        assertEquals(
            8,
            GalleryThumbnailDecodePolicy.sampleSize(
                width = 7728,
                height = 5152,
                maxDecodedSide = GalleryThumbnailDecodePolicy.PREVIEW_MAX_DECODED_SIDE,
            ),
        )
        assertEquals(1, GalleryThumbnailDecodePolicy.sampleSize(width = 640, height = 480))
        assertEquals(1, GalleryThumbnailDecodePolicy.sampleSize(width = 0, height = 0))
    }

    @Test
    fun previewImagePolicyPrefersHighResolutionPreviewOverListThumbnail() {
        val highResolutionPreview = byteArrayOf(0x01, 0x02)
        val listThumbnail = byteArrayOf(0x03, 0x04)

        assertArrayEquals(
            highResolutionPreview,
            GalleryPreviewImagePolicy.displayBytes(
                previewImage = highResolutionPreview,
                thumbnail = listThumbnail,
            ),
        )
        assertArrayEquals(
            listThumbnail,
            GalleryPreviewImagePolicy.displayBytes(
                previewImage = null,
                thumbnail = listThumbnail,
            ),
        )
    }

    @Test
    fun previewImagePolicyDecodesFullObjectLargerThanThumbnailPreview() {
        assertTrue(
            GalleryPreviewImagePolicy.FULL_IMAGE_MAX_DECODED_SIDE >
                GalleryThumbnailDecodePolicy.PREVIEW_MAX_DECODED_SIDE,
        )
        assertEquals(
            4,
            GalleryThumbnailDecodePolicy.sampleSize(
                width = 7728,
                height = 5152,
                maxDecodedSide = GalleryPreviewImagePolicy.FULL_IMAGE_MAX_DECODED_SIDE,
            ),
        )
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
    fun previewThumbnailPolicyRequestsCurrentPageAndNeighborsOnly() {
        val files = listOf(
            file(10, PtpObjectFormat.JPEG, "20260529T081500"),
            file(20, PtpObjectFormat.JPEG, "20260529T091500"),
            file(30, PtpObjectFormat.JPEG, "20260529T101500"),
            file(40, PtpObjectFormat.JPEG, "20260529T111500"),
        )

        assertEquals(
            listOf(20, 30, 40),
            GalleryPreviewThumbnailPolicy.handlesToRequest(files, currentPage = 2),
        )
        assertEquals(
            listOf(10, 20),
            GalleryPreviewThumbnailPolicy.handlesToRequest(files, currentPage = 0),
        )
        assertEquals(
            listOf(30, 40),
            GalleryPreviewThumbnailPolicy.handlesToRequest(files, currentPage = 3),
        )
        assertEquals(
            emptyList<Int>(),
            GalleryPreviewThumbnailPolicy.handlesToRequest(files, currentPage = 99),
        )
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
    fun previewRotationPolicyUsesCameraVendorOrientationBeforeDimensionFallback() {
        val portraitWithLandscapePixelMetadata = file(
            handle = 72,
            format = PtpObjectFormat.JPEG,
            captureDate = "20260529T111500",
            imageWidth = 4000,
            imageHeight = 3000,
            orientation = 2,
        )

        assertEquals(
            90,
            GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = portraitWithLandscapePixelMetadata,
                decodedWidth = 160,
                decodedHeight = 120,
                imageData = ByteArray(0),
            ),
        )
    }

    @Test
    fun thumbnailDisplayRotationPolicyMatchesPreviewAutoRotation() {
        val portrait = file(
            handle = 75,
            format = PtpObjectFormat.JPEG,
            captureDate = "20260529T111500",
            imageWidth = 4000,
            imageHeight = 3000,
        )

        assertEquals(
            90,
            GalleryThumbnailDisplayPolicy.rotationDegrees(
                file = portrait,
                decodedWidth = 160,
                decodedHeight = 120,
                thumbnail = jpegWithExifOrientation(6),
            ),
        )
    }

    @Test
    fun thumbnailDisplayRotationPolicyUsesCameraVendorOrientationFour() {
        val portrait = file(
            handle = 76,
            format = PtpObjectFormat.JPEG,
            captureDate = "20260529T111500",
            imageWidth = 4000,
            imageHeight = 3000,
            orientation = 4,
        )

        assertEquals(
            270,
            GalleryThumbnailDisplayPolicy.rotationDegrees(
                file = portrait,
                decodedWidth = 640,
                decodedHeight = 480,
                thumbnail = ByteArray(0),
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
        assertTrue(summary.contains("objectOrientation=unknown"))
        assertTrue(summary.contains("autoRotation=90"))
    }

    @Test
    fun thumbnailDiagnosticSummaryReportsCameraVendorOrientationRotation() {
        val summary = GalleryThumbnailDiagnosticPolicy.summary(
            handle = 81,
            file = file(
                handle = 81,
                format = PtpObjectFormat.JPEG,
                captureDate = "20260529T111500",
                imageWidth = 4000,
                imageHeight = 3000,
                orientation = 4,
            ),
            thumbnail = ByteArray(0),
            decodedWidth = 640,
            decodedHeight = 480,
        )

        assertTrue(summary.contains("objectOrientation=4"))
        assertTrue(summary.contains("autoRotation=270"))
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
        orientation: Int? = null,
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
                orientation = orientation,
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
