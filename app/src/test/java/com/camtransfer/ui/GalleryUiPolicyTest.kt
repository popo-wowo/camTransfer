package com.camtransfer.ui

import com.camtransfer.model.CameraFile
import com.camtransfer.model.CameraFileFormatHint
import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferState
import com.camtransfer.protocol.PtpObjectFormat
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.LocalDate

class GalleryUiPolicyTest {
    @Test
    fun transferModeCanChangeWheneverNoTransferIsRunning() {
        assertTrue(GalleryTransferModeUiPolicy.canChangeTransferMode(isTransferring = false))
        assertFalse(GalleryTransferModeUiPolicy.canChangeTransferMode(isTransferring = true))
    }

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
    fun formatFilterIncludesUnresolvedPlaceholdersWithCameraFormatHints() {
        val today = LocalDate.of(2026, 5, 29)
        val files = listOf(
            file(1, PtpObjectFormat.UNDEFINED, "20260529T081500")
                .copy(formatHints = setOf(CameraFileFormatHint.VIDEO)),
            file(2, PtpObjectFormat.UNDEFINED, "20260529T091500")
                .copy(formatHints = setOf(CameraFileFormatHint.EXTENDED_STILL_CANDIDATE)),
            file(3, PtpObjectFormat.UNDEFINED, "20260529T101500"),
        )

        assertEquals(
            listOf(1),
            GalleryUiPolicy.filteredFiles(
                files,
                GalleryFilterState(formats = setOf(GalleryFormatFilter.Video)),
                today,
            ).map { it.info.handle },
        )
        assertEquals(
            listOf(2),
            GalleryUiPolicy.filteredFiles(
                files,
                GalleryFilterState(formats = setOf(GalleryFormatFilter.Raw)),
                today,
            ).map { it.info.handle },
        )
        assertEquals(
            listOf(2),
            GalleryUiPolicy.filteredFiles(
                files,
                GalleryFilterState(formats = setOf(GalleryFormatFilter.Heif)),
                today,
            ).map { it.info.handle },
        )
    }

    @Test
    fun folderFilterIncludesFilesFromSelectedCameraFolders() {
        val today = LocalDate.of(2026, 5, 29)
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260529T081500", parentObject = 100),
            file(2, PtpObjectFormat.JPEG, "20260529T091500", parentObject = 101),
            file(3, PtpObjectFormat.JPEG, "20260529T101500", parentObject = 100),
        )
        val folder = GalleryFolderFilter(storageId = 1, parentObject = 100)

        val filtered = GalleryUiPolicy.filteredFiles(
            files = files,
            state = GalleryFilterState(folders = setOf(folder)),
            today = today,
        )

        assertEquals(listOf(1, 3), filtered.map { it.info.handle })
    }

    @Test
    fun filterStatsCountFoldersAndFormatsFromCurrentFileSet() {
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260529T081500", parentObject = 100),
            file(2, PtpObjectFormat.HEIF, "20260529T091500", parentObject = 101),
            file(3, PtpObjectFormat.CAMERA_VENDOR_RAF, "20260529T101500", parentObject = 100),
        )

        val stats = GalleryFilterStatsPolicy.stats(files)

        assertEquals(3, stats.totalCount)
        assertEquals(
            listOf(
                GalleryFolderCount(GalleryFolderFilter(storageId = 1, parentObject = 100), "文件夹 100", 2),
                GalleryFolderCount(GalleryFolderFilter(storageId = 1, parentObject = 101), "文件夹 101", 1),
            ),
            stats.folderCounts,
        )
        assertEquals(1, stats.formatCounts[GalleryFormatFilter.Jpg])
        assertEquals(1, stats.formatCounts[GalleryFormatFilter.Heif])
        assertEquals(1, stats.formatCounts[GalleryFormatFilter.Raw])
    }

    @Test
    fun filterStatsDoNotCountUndefinedPlaceholdersAsJpg() {
        val files = listOf(
            file(1, PtpObjectFormat.UNDEFINED, "20260529"),
            file(2, PtpObjectFormat.JPEG, "20260529T091500"),
        )

        val stats = GalleryFilterStatsPolicy.stats(files)

        assertEquals(1, stats.formatCounts[GalleryFormatFilter.Jpg])
        assertEquals(0, stats.formatCounts[GalleryFormatFilter.Heif])
        assertEquals(0, stats.formatCounts[GalleryFormatFilter.Raw])
    }

    @Test
    fun gallerySectionsGroupFilesByDateAndHourForExpandedDays() {
        val files = listOf(
            file(1, PtpObjectFormat.JPEG, "20260520T151500"),
            file(2, PtpObjectFormat.JPEG, "20260520T153000"),
            file(3, PtpObjectFormat.JPEG, "20260520T100500"),
            file(4, PtpObjectFormat.JPEG, "20260519T093000"),
        )

        val sections = GallerySectionPolicy.sections(
            files = files,
            expandedDays = setOf(LocalDate.of(2026, 5, 20)),
        )

        assertEquals(LocalDate.of(2026, 5, 20), sections[0].day)
        assertEquals(3, sections[0].files.size)
        assertEquals(listOf(1, 2), sections[0].hourGroups[0].files.map { it.info.handle })
        assertEquals(15, sections[0].hourGroups[0].hour)
        assertEquals(listOf(3), sections[0].hourGroups[1].files.map { it.info.handle })
        assertEquals(10, sections[0].hourGroups[1].hour)
        assertEquals(LocalDate.of(2026, 5, 19), sections[1].day)
        assertEquals(emptyList<GalleryHourGroup>(), sections[1].hourGroups)
    }

    @Test
    fun hourGroupsFollowCurrentSortedFileOrderWithinExpandedDay() {
        val sortedOldestFirst = listOf(
            file(1, PtpObjectFormat.JPEG, "20260520T081500"),
            file(2, PtpObjectFormat.JPEG, "20260520T091500"),
            file(3, PtpObjectFormat.JPEG, "20260520T101500"),
        )

        val sections = GallerySectionPolicy.sections(
            files = sortedOldestFirst,
            expandedDays = setOf(LocalDate.of(2026, 5, 20)),
        )

        assertEquals(listOf(8, 9, 10), sections[0].hourGroups.map { it.hour })
        assertEquals(listOf(1), sections[0].hourGroups[0].files.map { it.info.handle })
        assertEquals(listOf(2), sections[0].hourGroups[1].files.map { it.info.handle })
        assertEquals(listOf(3), sections[0].hourGroups[2].files.map { it.info.handle })
    }

    @Test
    fun dateSectionsStayDisabledWhileInitialPlaceholdersHaveNoCaptureDates() {
        val files = listOf(
            file(3, PtpObjectFormat.JPEG, ""),
            file(2, PtpObjectFormat.JPEG, ""),
            file(1, PtpObjectFormat.JPEG, ""),
        )

        assertFalse(GallerySectionPolicy.shouldShowDateSections(files))
        assertTrue(
            GallerySectionPolicy.shouldShowDateSections(
                files + file(4, PtpObjectFormat.JPEG, "20260520T151500"),
            )
        )
    }

    @Test
    fun unknownDateSectionStaysAfterRecognizedCaptureDates() {
        val files = listOf(
            file(3, PtpObjectFormat.JPEG, "20260520T151500"),
            file(2, PtpObjectFormat.JPEG, "20260519T093000"),
            file(1, PtpObjectFormat.JPEG, ""),
        )

        val sections = GallerySectionPolicy.sections(files = files, expandedDays = emptySet())

        assertEquals(LocalDate.of(2026, 5, 20), sections[0].day)
        assertEquals(LocalDate.of(2026, 5, 19), sections[1].day)
        assertEquals(null, sections[2].day)
        assertEquals(listOf(1), sections[2].files.map { it.info.handle })
    }

    @Test
    fun dateSectionsFollowCurrentSortedFileOrderAcrossDays() {
        val sortedOldestFirst = listOf(
            file(1, PtpObjectFormat.JPEG, "20260518T081500"),
            file(2, PtpObjectFormat.JPEG, "20260519T091500"),
            file(3, PtpObjectFormat.JPEG, "20260520T101500"),
            file(4, PtpObjectFormat.JPEG, ""),
        )

        val sections = GallerySectionPolicy.sections(files = sortedOldestFirst, expandedDays = emptySet())

        assertEquals(
            listOf(
                LocalDate.of(2026, 5, 18),
                LocalDate.of(2026, 5, 19),
                LocalDate.of(2026, 5, 20),
                null,
            ),
            sections.map { it.day },
        )
    }

    @Test
    fun stickyDateHeaderUsesTopVisibleItemSectionUntilNextDateReachesTop() {
        val sections = GallerySectionPolicy.sections(
            files = listOf(
                file(1, PtpObjectFormat.JPEG, "20260520T151500"),
                file(2, PtpObjectFormat.JPEG, "20260520T101500"),
                file(3, PtpObjectFormat.JPEG, "20260519T151500"),
            ),
            expandedDays = emptySet(),
        )

        assertEquals(
            LocalDate.of(2026, 5, 20),
            GalleryStickySectionPolicy.currentStickyDay(
                sections = sections,
                visibleKeys = listOf(2, "day-2026-05-19"),
            )?.day,
        )
        assertEquals(
            LocalDate.of(2026, 5, 19),
            GalleryStickySectionPolicy.currentStickyDay(
                sections = sections,
                visibleKeys = listOf("day-2026-05-19", 3),
            )?.day,
        )
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
    fun newestSortUsesFullCaptureTimeWhenAvailable() {
        val cameraOrder = listOf(
            file(1, PtpObjectFormat.JPEG, "20260624T081500"),
            file(2, PtpObjectFormat.JPEG, "20260624T101500"),
            file(3, PtpObjectFormat.JPEG, "20260624T091500"),
        )

        assertEquals(
            listOf(2, 3, 1),
            GallerySortPolicy.sortedFiles(cameraOrder, GallerySortMode.NewestFirst, emptyMap()).map { it.info.handle },
        )
    }

    @Test
    fun oldestSortUsesFullCaptureTimeWhenAvailableAfterFormatFiltering() {
        val jpgFiles = listOf(
            file(1, PtpObjectFormat.JPEG, "20260624T081500"),
            file(2, PtpObjectFormat.HEIF, "20260624T101500"),
            file(3, PtpObjectFormat.JPEG, "20260624T091500"),
            file(4, PtpObjectFormat.JPEG, "20260624T071500"),
        )
        val filtered = GalleryUiPolicy.filteredFiles(
            files = jpgFiles,
            state = GalleryFilterState(formats = setOf(GalleryFormatFilter.Jpg)),
            today = LocalDate.of(2026, 6, 24),
        )

        assertEquals(
            listOf(4, 1, 3),
            GallerySortPolicy.sortedFiles(filtered, GallerySortMode.OldestFirst, emptyMap()).map { it.info.handle },
        )
    }

    @Test
    fun listControlsResetGalleryScrollToFirstItem() {
        assertTrue(GalleryScrollResetPolicy.shouldScrollToTopAfterFilterOrSortChange())
    }

    @Test
    fun thumbnailRequestWindowKeepsVisibleHandlesFirstThenNearbyRows() {
        val allHandles = listOf(10, 9, 8, 7, 6, 5, 4, 3)

        assertEquals(
            listOf(8, 7, 9, 6, 5),
            GalleryThumbnailRequestWindowPolicy.handlesToRequest(
                orderedHandles = allHandles,
                visibleHandles = listOf(8, 7),
                columnCount = 1,
            ),
        )
    }

    @Test
    fun thumbnailRequestWindowUsesColumnCountForRowPrefetch() {
        val allHandles = listOf(12, 11, 10, 9, 8, 7, 6, 5, 4, 3)

        assertEquals(
            listOf(9, 8, 11, 10, 7, 6, 5, 4),
            GalleryThumbnailRequestWindowPolicy.handlesToRequest(
                orderedHandles = allHandles,
                visibleHandles = listOf(9, 8),
                columnCount = 2,
            ),
        )
    }

    @Test
    fun thumbnailRequestWindowFallsBackToFirstRowsWhenVisibleHandlesAreStaleAfterFiltering() {
        val filteredHandles = listOf(30, 29, 28, 27, 26, 25, 24, 23, 22, 21)

        assertEquals(
            listOf(30, 29, 28, 27, 26, 25, 24, 23, 22),
            GalleryThumbnailRequestWindowPolicy.handlesToRequest(
                orderedHandles = filteredHandles,
                visibleHandles = listOf(10, 9, 8),
                columnCount = 3,
            ),
        )
    }

    @Test
    fun thumbnailRequestWindowFallsBackToFirstRowsBeforeLazyGridReportsVisibility() {
        val filteredHandles = listOf(40, 39, 38, 37, 36)

        assertEquals(
            listOf(40, 39, 38, 37, 36),
            GalleryThumbnailRequestWindowPolicy.handlesToRequest(
                orderedHandles = filteredHandles,
                visibleHandles = emptyList(),
                columnCount = 3,
            ),
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
    fun browseModeSwitcherUsesSeparatePreviewFrameNextToFilterButton() {
        val browseSource = listOf(
            File("src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
        ).first { it.exists() }.readText()
        val filterSource = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryFilterPanel.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryFilterPanel.kt"),
        ).first { it.exists() }.readText()
        val headerSource = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryHeader.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryHeader.kt"),
        ).first { it.exists() }.readText()

        assertFalse(browseSource.contains("private fun GalleryBrowseModeRow("))
        assertFalse(browseSource.contains("private fun GalleryBrowseModeChip("))
        assertFalse(filterSource.contains("GalleryBrowseModeSegmentedControl(\n                activeMode = activeMode"))
        assertTrue(headerSource.contains("GalleryFilterHeaderButton("))
        assertTrue(headerSource.contains("GalleryBrowseModeSegmentedControl("))
        assertTrue(headerSource.contains("GalleryHeaderIcon.Menu"))
        assertTrue(headerSource.contains("\"高清预览\""))
        assertTrue(headerSource.contains("activeMode: GalleryBrowseMode"))
        assertTrue(browseSource.contains("activeMode = browseModeState.mode"))
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
    fun dateRangePickerPolicyUsesSeparateStartAndEndFields() {
        val start = LocalDate.of(2026, 5, 20)
        val end = LocalDate.of(2026, 5, 28)

        assertEquals("选择日期", GalleryDateRangePickerPolicy.fieldValue(null))
        assertEquals("2026-05-20", GalleryDateRangePickerPolicy.fieldValue(start))
        assertEquals(GalleryDateRangeEndpoint.End, GalleryDateRangePickerPolicy.nextEndpointAfterDate(GalleryDateRangeEndpoint.Start))
        assertEquals(GalleryDateRangeEndpoint.End, GalleryDateRangePickerPolicy.nextEndpointAfterDate(GalleryDateRangeEndpoint.End))
        assertEquals(start, GalleryDateRangePickerPolicy.normalizedStart(start, end))
        assertEquals(end, GalleryDateRangePickerPolicy.normalizedEnd(end, start))
    }

    @Test
    fun activeDownloadsAreNotSelectableButSavedDownloadsCanBeSelectedAgain() {
        assertTrue(GalleryDownloadUiPolicy.canSelect(TransferState.ERROR))
        assertTrue(GalleryDownloadUiPolicy.canSelect(null))
        assertTrue(GalleryDownloadUiPolicy.canSelect(TransferState.DONE))
        assertFalse(GalleryDownloadUiPolicy.canSelect(TransferState.PENDING))
        assertFalse(GalleryDownloadUiPolicy.canSelect(TransferState.DOWNLOADING))
        assertFalse(GalleryDownloadUiPolicy.canSelect(TransferState.SAVING))
    }

    @Test
    fun startedDownloadCountExcludesErrorsAndNeverQueuedItems() {
        assertFalse(GalleryDownloadUiPolicy.hasStarted(null))
        assertFalse(GalleryDownloadUiPolicy.hasStarted(TransferState.ERROR))
        assertTrue(GalleryDownloadUiPolicy.hasStarted(TransferState.PENDING))
        assertTrue(GalleryDownloadUiPolicy.hasStarted(TransferState.DOWNLOADING))
        assertTrue(GalleryDownloadUiPolicy.hasStarted(TransferState.SAVING))
        assertTrue(GalleryDownloadUiPolicy.hasStarted(TransferState.DONE))
    }

    @Test
    fun highDefinitionPreviewDownloadWaitsForLoadedPreviewBytes() {
        assertFalse(GalleryDownloadUiPolicy.canDownloadFromHighDefinitionPreview(hasPreviewImage = false, state = null))
        assertTrue(GalleryDownloadUiPolicy.canDownloadFromHighDefinitionPreview(hasPreviewImage = true, state = TransferState.PENDING))
        assertTrue(GalleryDownloadUiPolicy.canDownloadFromHighDefinitionPreview(hasPreviewImage = true, state = null))
        assertTrue(GalleryDownloadUiPolicy.canDownloadFromHighDefinitionPreview(hasPreviewImage = true, state = TransferState.DONE))
        assertFalse(GalleryDownloadUiPolicy.canDownloadFromHighDefinitionPreview(hasPreviewImage = true, state = TransferState.DOWNLOADING))
    }

    @Test
    fun highDefinitionPreviewQueuesPerCardAndStartsOnlyFromBottomBar() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/HighDefinitionPreviewScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/HighDefinitionPreviewScreen.kt"),
        ).first { it.exists() }.readText()
        val cardBlock = source.substring(
            source.indexOf("private fun HighDefinitionPreviewCard("),
            source.indexOf("private fun hdRawDownloadLabel("),
        )
        val bottomBarBlock = source.substring(
            source.indexOf("private fun HighDefinitionPreviewBottomBar("),
            source.indexOf("private fun HdDownloadCountDot("),
        )

        assertTrue(cardBlock.contains("onQueueDownload"))
        assertTrue(cardBlock.contains("onCancelQueuedDownload"))
        assertFalse(cardBlock.contains("onStartDownload"))
        assertTrue(cardBlock.contains("HdQueueButton("))
        assertTrue(bottomBarBlock.contains("onStartDownload"))
        assertTrue(bottomBarBlock.contains("Text(\"下载\""))
    }

    @Test
    fun highDefinitionPreviewScreenUsesSessionItemsFromViewModel() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
        ).first { it.exists() }.readText()
        val screenIndex = source.indexOf("HighDefinitionPreviewScreen(")
        val screenBlock = source.substring(
            screenIndex,
            source.indexOf("GalleryFilterPanel(", startIndex = screenIndex),
        )

        assertTrue(source.contains("val highDefinitionPreviewItems by viewModel.highDefinitionPreviewItems.collectAsState()"))
        assertTrue(screenBlock.contains("items = highDefinitionPreviewItems"))
        assertFalse(source.contains("HighDefinitionPreviewSessionPolicy.previewItemsForDate(\n                files = files"))
    }

    @Test
    fun mainActivitySeparatesQueueingFromStartingQueuedDownloads() {
        val source = listOf(
            File("src/main/java/com/camtransfer/MainActivity.kt"),
            File("app/src/main/java/com/camtransfer/MainActivity.kt"),
        ).first { it.exists() }.readText()
        val browseCall = source.substring(
            source.indexOf("BrowseScreen("),
            source.indexOf("                onDisconnect = {"),
        )

        assertTrue(browseCall.contains("onQueueDownloadSelected = { files ->"))
        assertTrue(browseCall.contains("transferVM.enqueue("))
        assertTrue(browseCall.contains("onStartQueuedDownloads = {"))
        assertTrue(browseCall.contains("transferVM.startQueuedTransfer("))
    }

    @Test
    fun returningFromBrowseToConnectClearsHighDefinitionSessionCache() {
        val source = listOf(
            File("src/main/java/com/camtransfer/MainActivity.kt"),
            File("app/src/main/java/com/camtransfer/MainActivity.kt"),
        ).first { it.exists() }.readText()
        val disconnectBlock = source.substring(
            source.indexOf("                onDisconnect = {"),
            source.indexOf("                },", source.indexOf("                onDisconnect = {")),
        )

        assertTrue(source.contains("browseVM.clearHighDefinitionPreviewSessionCache("))
        assertTrue(disconnectBlock.contains("browseVM.clearHighDefinitionPreviewSessionCache("))
    }

    @Test
    fun galleryTileBadgesUseFormatLettersAndIconForDownloadedFiles() {
        assertEquals(
            "RAW",
            GalleryTileBadgePolicy.formatLabel(file(1, PtpObjectFormat.CAMERA_VENDOR_RAF, "20260529T081500")),
        )
        assertEquals(
            "HEIF",
            GalleryTileBadgePolicy.formatLabel(file(2, PtpObjectFormat.HEIF, "20260529T081500")),
        )
        assertEquals(
            null,
            GalleryTileBadgePolicy.formatLabel(file(3, PtpObjectFormat.UNDEFINED, "20260529")),
        )
        assertEquals(GalleryTileDownloadBadge.DownloadedIcon, GalleryTileBadgePolicy.downloadBadge(TransferState.DONE))
        assertEquals(GalleryTileDownloadBadge.Progress, GalleryTileBadgePolicy.downloadBadge(TransferState.DOWNLOADING))
        assertEquals(GalleryTileDownloadBadge.PendingText, GalleryTileBadgePolicy.downloadBadge(TransferState.PENDING))
        assertEquals(null, GalleryTileBadgePolicy.downloadBadge(null))
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
    fun downloadCenterAllowsReturningToGalleryWhileQueueIsActive() {
        assertTrue(DownloadCenterActionPolicy.canReturnToGallery(activeCount = 1))
        assertTrue(DownloadCenterActionPolicy.canReturnToGallery(activeCount = 0))
        assertTrue(DownloadCenterActionPolicy.canPauseDownloads(activeCount = 1))
        assertFalse(DownloadCenterActionPolicy.canPauseDownloads(activeCount = 0))
    }

    @Test
    fun downloadCenterBlocksRecordCleanupWhileQueueIsActive() {
        assertFalse(DownloadCenterActionPolicy.canClearRecords(totalCount = 3, activeCount = 1))
        assertTrue(DownloadCenterActionPolicy.canClearRecords(totalCount = 3, activeCount = 0))
        assertFalse(DownloadCenterActionPolicy.canClearRecords(totalCount = 0, activeCount = 0))
    }

    @Test
    fun transferScreenAllowsBackAndAddsPauseWhileQueueIsActive() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/TransferScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/TransferScreen.kt"),
        ).first { it.exists() }.readText()

        assertTrue(source.contains("val canReturnToGallery = !isTransferring && DownloadCenterActionPolicy.canReturnToGallery(activeCount)"))
        assertTrue(source.contains("BackHandler"))
        assertTrue(source.contains("if (canReturnToGallery)"))
        assertTrue(source.contains("enabled = canReturnToGallery"))
        assertTrue(source.contains("DownloadCenterActionPolicy.pauseDownloadsLabel"))
        assertTrue(source.contains("DownloadCenterActionPolicy.canPauseDownloads(activeCount)"))
        assertTrue(source.contains("DownloadCenterActionPolicy.canClearRecords(totalCount, activeCount)"))
    }

    @Test
    fun galleryHeaderAddsDownloadFolderAction() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryHeader.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryHeader.kt"),
        ).first { it.exists() }.readText()

        assertTrue(source.contains("GalleryHeaderIcon.Folder"))
        assertTrue(source.contains("\"下载文件夹\""))
    }

    @Test
    fun browseScreenShowsDownloadFolderSettingsDialog() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
        ).first { it.exists() }.readText()

        assertTrue(source.contains("DownloadFolderSettingsDialog("))
        assertTrue(source.contains("downloadFolderSettingsStore.save("))
    }

    @Test
    fun downloadFolderDialogIncludesCustomFolderPickerAction() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryDialogs.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryDialogs.kt"),
        ).first { it.exists() }.readText()

        assertTrue(source.contains("选择手机文件夹"))
        assertTrue(source.contains("DownloadFolderModeOptionRow("))
        assertTrue(source.contains("onPickCustomFolder"))
    }

    @Test
    fun browseScreenShowsCacheSettingsDialog() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
        ).first { it.exists() }.readText()

        assertTrue(source.contains("CacheSettingsDialog("))
        assertTrue(source.contains("AppCacheSettingsStore("))
        assertTrue(source.contains("AppCacheUsagePolicy.trimToLimit("))
    }

    @Test
    fun cacheSettingsDialogDescribesPersistentThumbnailCacheLimits() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryDialogs.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryDialogs.kt"),
        ).first { it.exists() }.readText()

        assertTrue(source.contains("AppCacheLimitOption.entries"))
        assertTrue(source.contains("高清预览只保留在本次浏览会话"))
        assertTrue(source.contains("配对记录和已下载文件不属于缓存"))
    }

    @Test
    fun cacheUsageScanWaitsUntilGalleryInitialLoadSettles() {
        assertFalse(GalleryCacheUsageUiPolicy.shouldScanCacheUsage(hasFiles = false, isLoading = true))
        assertFalse(GalleryCacheUsageUiPolicy.shouldScanCacheUsage(hasFiles = true, isLoading = true))
        assertTrue(GalleryCacheUsageUiPolicy.shouldScanCacheUsage(hasFiles = true, isLoading = false))
        assertTrue(GalleryCacheUsageUiPolicy.INITIAL_SCAN_DELAY_MS >= 1_000L)
    }

    @Test
    fun dragSelectionAddsOrRemovesOnlySelectableHandles() {
        assertTrue(GalleryDragSelectionPolicy.shouldSelectForDrag(startHandleSelected = false))
        assertFalse(GalleryDragSelectionPolicy.shouldSelectForDrag(startHandleSelected = true))
        assertTrue(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 18f, deltaY = 4f, touchSlop = 8f))
        assertFalse(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 12f, deltaY = 10f, touchSlop = 8f))
        assertTrue(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 16f, deltaY = 10f, touchSlop = 8f))
        assertFalse(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 3f, deltaY = 2f, touchSlop = 8f))
        assertFalse(GalleryDragSelectionPolicy.shouldStartDragSelection(deltaX = 3f, deltaY = 18f, touchSlop = 8f))
        assertFalse(
            GalleryDragSelectionPolicy.shouldStartDragSelection(
                deltaX = 3f,
                deltaY = 18f,
                touchSlop = 8f,
                selectionActive = true,
            )
        )
        assertTrue(
            GalleryDragSelectionPolicy.shouldStartDragSelection(
                deltaX = 18f,
                deltaY = 4f,
                touchSlop = 8f,
                selectionActive = true,
            )
        )
        assertFalse(
            GalleryDragSelectionPolicy.shouldCommitDragSelection(
                startHandle = 1,
                endHandle = 1,
                endDownloadState = null,
            )
        )
        assertFalse(
            GalleryDragSelectionPolicy.shouldCommitDragSelection(
                startHandle = 1,
                endHandle = null,
                endDownloadState = null,
            )
        )
        assertTrue(
            GalleryDragSelectionPolicy.shouldCommitDragSelection(
                startHandle = 1,
                endHandle = 2,
                endDownloadState = TransferState.DONE,
            )
        )
        assertTrue(
            GalleryDragSelectionPolicy.shouldCommitDragSelection(
                startHandle = 1,
                endHandle = 2,
                endDownloadState = null,
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
            setOf(1, 3),
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
            setOf(2, 3, 4, 5, 6, 7, 9),
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
    fun cameraGalleryKeepsPinchColumnsAndThumbnailPrefetchUsesCurrentColumnCount() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
        ).first { it.exists() }.readText()
        val thumbnailRequestBlock = source.substring(
            source.indexOf("val thumbnailRequestHandles"),
            source.indexOf("val selectableFilteredHandles"),
        )

        assertTrue(source.contains("var columnCount by remember"))
        assertTrue(source.contains("prefs.getInt(\"columnCount\""))
        assertTrue(source.contains("prefs.edit().putInt(\"columnCount\", newCount).apply()"))
        assertTrue(thumbnailRequestBlock.contains("columnCount = columnCount"))
        assertFalse(thumbnailRequestBlock.contains("GalleryColumnLayoutPolicy.DEFAULT_COLUMNS"))
    }

    @Test
    fun galleryGridDoesNotPassPerFrameVisibleStateIntoEveryTile() {
        val browseSource = listOf(
            File("src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
        ).first { it.exists() }.readText()
        val gridSource = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryGrid.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryGrid.kt"),
        ).first { it.exists() }.readText()
        val itemSource = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryGridItem.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryGridItem.kt"),
        ).first { it.exists() }.readText()

        assertFalse(browseSource.contains("val visibleGridHandleSet"))
        assertFalse(gridSource.contains("visibleGridHandleSet"))
        assertFalse(itemSource.contains("isItemVisible"))
        assertFalse(itemSource.contains("onVisible()"))
    }

    @Test
    fun galleryGridSpacingKeepsPhotoGapsCompact() {
        assertEquals(2, GalleryGridSpacingPolicy.HORIZONTAL_DP)
        assertEquals(2, GalleryGridSpacingPolicy.VERTICAL_DP)
    }

    @Test
    fun galleryGridItemsDoNotAnimateDuringScroll() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryGridItem.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryGridItem.kt"),
        ).first { it.exists() }.readText()

        assertFalse(source.contains("galleryTileScale"))
        assertFalse(source.contains("galleryTileAlpha"))
        assertFalse(source.contains("tileVisible"))
        assertFalse(source.contains("alpha = tileAlpha"))
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
    fun decodedThumbnailCacheReusesSameThumbnailIdentity() {
        val cache = GalleryDecodedThumbnailCache<String>(maxEntries = 2)
        val file = file(42, PtpObjectFormat.JPEG, "20260529T081500")
        val key = GalleryDecodedThumbnailCache.key(
            file = file,
            thumbnailSize = 128,
            maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
        )

        cache.put(key, "bitmap-42")

        assertEquals("bitmap-42", cache.get(key))
    }

    @Test
    fun decodedThumbnailCacheMissesWhenObjectIdentityChanges() {
        val cache = GalleryDecodedThumbnailCache<String>(maxEntries = 2)
        val file = file(42, PtpObjectFormat.JPEG, "20260529T081500")
        val changedFile = file.copy(info = file.info.copy(compressedSize = 2048))
        val originalKey = GalleryDecodedThumbnailCache.key(
            file = file,
            thumbnailSize = 128,
            maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
        )
        val changedKey = GalleryDecodedThumbnailCache.key(
            file = changedFile,
            thumbnailSize = 128,
            maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
        )

        cache.put(originalKey, "bitmap-42")

        assertEquals(null, cache.get(changedKey))
    }

    @Test
    fun decodedThumbnailCacheEvictsLeastRecentlyUsedEntry() {
        val cache = GalleryDecodedThumbnailCache<String>(maxEntries = 2)
        val first = GalleryDecodedThumbnailCache.key(
            file = file(1, PtpObjectFormat.JPEG, "20260529T081500"),
            thumbnailSize = 128,
            maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
        )
        val second = GalleryDecodedThumbnailCache.key(
            file = file(2, PtpObjectFormat.JPEG, "20260529T081500"),
            thumbnailSize = 128,
            maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
        )
        val third = GalleryDecodedThumbnailCache.key(
            file = file(3, PtpObjectFormat.JPEG, "20260529T081500"),
            thumbnailSize = 128,
            maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
        )

        cache.put(first, "one")
        cache.put(second, "two")
        assertEquals("one", cache.get(first))
        cache.put(third, "three")

        assertEquals("one", cache.get(first))
        assertEquals(null, cache.get(second))
        assertEquals("three", cache.get(third))
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
    fun thumbnailDisplayPolicyPrefersStoreThumbnailByHandle() {
        val oldThumbnail = byteArrayOf(0x01)
        val storeThumbnail = byteArrayOf(0x02)
        val item = file(10, PtpObjectFormat.JPEG, "20260529T081500").copy(thumbnail = oldThumbnail)

        assertArrayEquals(
            storeThumbnail,
            GalleryThumbnailDisplayPolicy.thumbnailFor(item, mapOf(10 to storeThumbnail)),
        )
        assertArrayEquals(
            oldThumbnail,
            GalleryThumbnailDisplayPolicy.thumbnailFor(item, emptyMap()),
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
    fun previewFileInfoPolicyReportsCameraObjectMetadata() {
        val file = file(
            handle = 42,
            format = PtpObjectFormat.HEIF,
            captureDate = "20260529T111530",
            imageWidth = 7728,
            imageHeight = 5152,
            orientation = 2,
        )

        val rows = GalleryPreviewFileInfoPolicy.rows(file)

        assertEquals("DSCF0042.JPG", rows.first { it.label == "文件" }.value)
        assertEquals("HEIF", rows.first { it.label == "格式" }.value)
        assertEquals("7728 x 5152", rows.first { it.label == "尺寸" }.value)
        assertEquals("160 x 120", rows.first { it.label == "缩略图" }.value)
        assertEquals("1 KB", rows.first { it.label == "大小" }.value)
        assertEquals("2026-05-29 11:15:30", rows.first { it.label == "拍摄时间" }.value)
        assertEquals("42", rows.first { it.label == "Handle" }.value)
        assertEquals("2", rows.first { it.label == "方向" }.value)
    }

    @Test
    fun previewActionBarPolicyMatchesDownloadStateLabels() {
        assertEquals("下载", GalleryPreviewActionBarPolicy.downloadLabel(null))
        assertEquals("排队", GalleryPreviewActionBarPolicy.downloadLabel(TransferState.PENDING))
        assertEquals("下载中", GalleryPreviewActionBarPolicy.downloadLabel(TransferState.DOWNLOADING))
        assertEquals("保存中", GalleryPreviewActionBarPolicy.downloadLabel(TransferState.SAVING))
        assertEquals("已保存", GalleryPreviewActionBarPolicy.downloadLabel(TransferState.DONE))
        assertEquals("重试", GalleryPreviewActionBarPolicy.downloadLabel(TransferState.ERROR))
        assertEquals("原图", GalleryPreviewActionBarPolicy.downloadModeLabel(preferCompressedDownloads = false))
        assertEquals("压缩", GalleryPreviewActionBarPolicy.downloadModeLabel(preferCompressedDownloads = true))
    }

    @Test
    fun previewDialogKeepsOnlySelectionTransferModeAndDownloadInBottomBar() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/GalleryPreviewDialog.kt"),
            File("app/src/main/java/com/camtransfer/ui/GalleryPreviewDialog.kt"),
        ).first { it.exists() }.readText()
        val topBarBlock = source.substring(
            source.indexOf("Row("),
            source.indexOf("PreviewActionBar("),
        )
        val bottomBarBlock = source.substring(
            source.indexOf("private fun PreviewActionBar("),
            source.indexOf("private fun PreviewSelectionBox("),
        )

        assertFalse(topBarBlock.contains("Text(\"旋转\""))
        assertFalse(bottomBarBlock.contains("RotateLeftPreviewButton("))
        assertFalse(bottomBarBlock.contains("RotateRightPreviewButton("))
        assertTrue(bottomBarBlock.contains("TransferModeCapsule("))
        assertFalse(bottomBarBlock.contains("file.info.filename"))
    }

    @Test
    fun browseScreenForwardsTransferModeToggleIntoPreviewDialog() {
        val source = listOf(
            File("src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
            File("app/src/main/java/com/camtransfer/ui/BrowseScreen.kt"),
        ).first { it.exists() }.readText()
        val previewDialogCall = source.substring(
            source.indexOf("PhotoPreviewDialog("),
            source.indexOf("        )\n    }\n\n    Scaffold("),
        )

        assertTrue(previewDialogCall.contains("canChangeTransferMode = canChangeTransferMode"))
        assertTrue(previewDialogCall.contains("onPreferenceChanged = onPreferenceChanged"))
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

    private fun file(
        handle: Int,
        format: Int,
        captureDate: String,
        parentObject: Int = 0,
    ): CameraFile =
        file(
            handle = handle,
            format = format,
            captureDate = captureDate,
            imageWidth = 4000,
            imageHeight = 3000,
            parentObject = parentObject,
        )

    private fun file(
        handle: Int,
        format: Int,
        captureDate: String,
        imageWidth: Int,
        imageHeight: Int,
        parentObject: Int = 0,
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
                parentObject = parentObject,
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
