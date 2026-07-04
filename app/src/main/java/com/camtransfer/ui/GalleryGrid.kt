package com.camtransfer.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferState
import java.time.LocalDate

@Composable
internal fun GalleryGrid(
    files: List<CameraFile>,
    sections: List<GalleryDaySection>,
    today: LocalDate,
    columnCount: Int,
    gridState: LazyGridState,
    selectedHandles: Set<Int>,
    downloadStates: Map<Int, TransferState?>,
    thumbnailsByHandle: Map<Int, ByteArray>,
    isLoadingFullObjectInfo: Boolean,
    visibleGridHandleSet: Set<Int>,
    onColumnCountChange: (Int) -> Unit,
    onSelectionChange: (Set<Int>) -> Unit,
    onToggleDayHours: (LocalDate) -> Unit,
    onToggleDaySelection: (List<CameraFile>) -> Unit,
    onOpenFile: (CameraFile) -> Unit,
    onToggleSelection: (CameraFile) -> Unit,
    onVisible: (CameraFile) -> Unit,
) {
    val stickySection by remember(sections, gridState) {
        derivedStateOf {
            GalleryStickySectionPolicy.currentStickyDay(
                sections = sections,
                visibleKeys = gridState.layoutInfo.visibleItemsInfo
                    .sortedBy { it.index }
                    .map { it.key },
            )
        }
    }
    Box(modifier = Modifier.fillMaxSize()) {
        LazyVerticalGrid(
            columns = GridCells.Fixed(columnCount),
            state = gridState,
            modifier = Modifier
                .fillMaxSize()
                .galleryColumnPinchResize(
                    columnCount = columnCount,
                    onColumnCountChange = onColumnCountChange,
                )
                .galleryDragSelection(
                    gridState = gridState,
                    files = files,
                    selectedHandles = selectedHandles,
                    downloadStates = downloadStates,
                    onSelectionChange = onSelectionChange,
                ),
            contentPadding = PaddingValues(start = 12.dp, top = 8.dp, end = 12.dp, bottom = 96.dp),
            horizontalArrangement = Arrangement.spacedBy(GalleryGridSpacingPolicy.HORIZONTAL_DP.dp),
            verticalArrangement = Arrangement.spacedBy(GalleryGridSpacingPolicy.VERTICAL_DP.dp),
        ) {
            if (sections.isEmpty()) {
                items(files, key = { it.info.handle }) { file ->
                    GalleryGridFileItem(
                        file = file,
                        selectedHandles = selectedHandles,
                        downloadStates = downloadStates,
                        thumbnailsByHandle = thumbnailsByHandle,
                        isLoadingFullObjectInfo = isLoadingFullObjectInfo,
                        visibleGridHandleSet = visibleGridHandleSet,
                        onOpenFile = onOpenFile,
                        onToggleSelection = onToggleSelection,
                        onVisible = onVisible,
                    )
                }
                return@LazyVerticalGrid
            }

            sections.forEach { section ->
                item(
                    key = GalleryStickySectionPolicy.dayKey(section.day),
                    span = { GridItemSpan(maxLineSpan) },
                ) {
                    DaySectionHeader(
                        section = section,
                        today = today,
                        selectedHandles = selectedHandles,
                        downloadStates = downloadStates,
                        onToggleDaySelection = { onToggleDaySelection(section.files) },
                        onToggleDayHours = {
                            section.day?.let(onToggleDayHours)
                        },
                    )
                }

                if (section.hourGroups.isNotEmpty()) {
                    section.hourGroups.forEach { hourGroup ->
                        item(
                            key = GalleryStickySectionPolicy.hourKey(section.day, hourGroup.hour),
                            span = { GridItemSpan(maxLineSpan) },
                        ) {
                            HourSectionHeader(hourGroup.hour)
                        }
                        items(hourGroup.files, key = { it.info.handle }) { file ->
                            GalleryGridFileItem(
                                file = file,
                                selectedHandles = selectedHandles,
                                downloadStates = downloadStates,
                                thumbnailsByHandle = thumbnailsByHandle,
                                isLoadingFullObjectInfo = isLoadingFullObjectInfo,
                                visibleGridHandleSet = visibleGridHandleSet,
                                onOpenFile = onOpenFile,
                                onToggleSelection = onToggleSelection,
                                onVisible = onVisible,
                            )
                        }
                    }
                } else {
                    items(section.files, key = { it.info.handle }) { file ->
                        GalleryGridFileItem(
                            file = file,
                            selectedHandles = selectedHandles,
                            downloadStates = downloadStates,
                            thumbnailsByHandle = thumbnailsByHandle,
                            isLoadingFullObjectInfo = isLoadingFullObjectInfo,
                            visibleGridHandleSet = visibleGridHandleSet,
                            onOpenFile = onOpenFile,
                            onToggleSelection = onToggleSelection,
                            onVisible = onVisible,
                        )
                    }
                }
            }
        }
        stickySection?.let { section ->
            StickyDaySectionHeader(
                section = section,
                today = today,
                selectedHandles = selectedHandles,
                downloadStates = downloadStates,
                onToggleDaySelection = { onToggleDaySelection(section.files) },
                onToggleDayHours = {
                    section.day?.let(onToggleDayHours)
                },
            )
        }
    }
}

@Composable
private fun StickyDaySectionHeader(
    section: GalleryDaySection,
    today: LocalDate,
    selectedHandles: Set<Int>,
    downloadStates: Map<Int, TransferState?>,
    onToggleDaySelection: () -> Unit,
    onToggleDayHours: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(CamTransferColors.Background)
            .padding(start = 12.dp, end = 12.dp),
    ) {
        DaySectionHeader(
            section = section,
            today = today,
            selectedHandles = selectedHandles,
            downloadStates = downloadStates,
            onToggleDaySelection = onToggleDaySelection,
            onToggleDayHours = onToggleDayHours,
        )
    }
}

@Composable
private fun DaySectionHeader(
    section: GalleryDaySection,
    today: LocalDate,
    selectedHandles: Set<Int>,
    downloadStates: Map<Int, TransferState?>,
    onToggleDaySelection: () -> Unit,
    onToggleDayHours: () -> Unit,
) {
    val selectableHandles = section.files
        .filter { GalleryDownloadUiPolicy.canSelect(downloadStates[it.info.handle]) }
        .map { it.info.handle }
        .toSet()
    val allSelected = selectableHandles.isNotEmpty() && selectedHandles.containsAll(selectableHandles)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 14.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = "${section.day.dayLabel(today)} ${section.files.size} 张",
            modifier = Modifier.weight(1f),
            color = CamTransferColors.Ink,
            fontSize = 15.sp,
            fontWeight = FontWeight.Black,
            maxLines = 1,
        )
        HeaderPillButton(
            label = if (allSelected) "取消" else "全选",
            onClick = onToggleDaySelection,
        )
        if (section.day != null) {
            HeaderPillButton(
                label = if (section.hourGroups.isEmpty()) "小时" else "收起",
                onClick = onToggleDayHours,
            )
        }
    }
}

@Composable
private fun HourSectionHeader(hour: Int) {
    Text(
        text = "%02d:00".format(hour),
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp, bottom = 5.dp),
        color = CamTransferColors.SecondaryInk,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        maxLines = 1,
    )
}

@Composable
private fun HeaderPillButton(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(CamTransferColors.MutedFill)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Text(
            text = label,
            color = CamTransferColors.Ink,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
        )
    }
}

@Composable
private fun GalleryGridFileItem(
    file: CameraFile,
    modifier: Modifier = Modifier,
    selectedHandles: Set<Int>,
    downloadStates: Map<Int, TransferState?>,
    thumbnailsByHandle: Map<Int, ByteArray>,
    isLoadingFullObjectInfo: Boolean,
    visibleGridHandleSet: Set<Int>,
    onOpenFile: (CameraFile) -> Unit,
    onToggleSelection: (CameraFile) -> Unit,
    onVisible: (CameraFile) -> Unit,
) {
    val state = downloadStates[file.info.handle]
    GalleryGridItem(
        file = file,
        thumbnail = GalleryThumbnailDisplayPolicy.thumbnailFor(file, thumbnailsByHandle),
        modifier = modifier,
        isSelected = file.info.handle in selectedHandles,
        downloadState = state,
        isLoadingFullObjectInfo = isLoadingFullObjectInfo,
        isItemVisible = file.info.handle in visibleGridHandleSet,
        onOpen = { onOpenFile(file) },
        onToggleSelection = {
            if (GalleryDownloadUiPolicy.canSelect(state)) {
                onToggleSelection(file)
            }
        },
        onVisible = { onVisible(file) },
    )
}

private fun LocalDate?.dayLabel(today: LocalDate): String =
    when (this) {
        null -> "未知日期"
        today -> "今天 ${monthValue}月${dayOfMonth}日"
        else -> "${monthValue}月${dayOfMonth}日"
    }
