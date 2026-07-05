package com.camtransfer.ui

import android.graphics.Bitmap
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferState
import kotlinx.coroutines.flow.StateFlow
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
    thumbnailState: (Int) -> StateFlow<ByteArray?>,
    decodedThumbnailCache: GalleryDecodedThumbnailCache<Bitmap>,
    onColumnCountChange: (Int) -> Unit,
    onSelectionChange: (Set<Int>) -> Unit,
    onToggleDayHours: (LocalDate) -> Unit,
    onToggleDaySelection: (List<CameraFile>) -> Unit,
    onOpenFile: (CameraFile) -> Unit,
    onToggleSelection: (CameraFile) -> Unit,
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
            contentPadding = PaddingValues(start = 12.dp, top = 2.dp, end = 12.dp, bottom = 96.dp),
            horizontalArrangement = Arrangement.spacedBy(GalleryGridSpacingPolicy.HORIZONTAL_DP.dp),
            verticalArrangement = Arrangement.spacedBy(GalleryGridSpacingPolicy.VERTICAL_DP.dp),
        ) {
            if (sections.isEmpty()) {
                items(files, key = { it.info.handle }) { file ->
                    GalleryGridFileItem(
                        file = file,
                        selectedHandles = selectedHandles,
                        downloadStates = downloadStates,
                        thumbnailState = thumbnailState,
                        decodedThumbnailCache = decodedThumbnailCache,
                        onOpenFile = onOpenFile,
                        onToggleSelection = onToggleSelection,
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
                                thumbnailState = thumbnailState,
                                decodedThumbnailCache = decodedThumbnailCache,
                                onOpenFile = onOpenFile,
                                onToggleSelection = onToggleSelection,
                            )
                        }
                    }
                } else {
                    items(section.files, key = { it.info.handle }) { file ->
                        GalleryGridFileItem(
                            file = file,
                            selectedHandles = selectedHandles,
                            downloadStates = downloadStates,
                            thumbnailState = thumbnailState,
                            decodedThumbnailCache = decodedThumbnailCache,
                            onOpenFile = onOpenFile,
                            onToggleSelection = onToggleSelection,
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
            .padding(top = 9.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier.weight(1f),
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = section.day.dayLabel(today),
                color = CamTransferColors.Ink,
                fontSize = GalleryTypeScale.ContentTitle,
                fontWeight = FontWeight.Black,
                maxLines = 1,
            )
            DayCountPill("${section.files.size} 张")
        }
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
private fun DayCountPill(label: String) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(CamTransferColors.Card.copy(alpha = 0.66f))
            .padding(horizontal = 8.dp, vertical = 2.dp),
    ) {
        Text(
            text = label,
            color = CamTransferColors.SecondaryInk,
            fontSize = GalleryTypeScale.Meta,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
        )
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
        fontSize = GalleryTypeScale.Level2,
        fontWeight = FontWeight.SemiBold,
        maxLines = 1,
    )
}

@Composable
private fun HeaderPillButton(label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(CamTransferColors.Card.copy(alpha = 0.48f))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(
            text = label,
            color = CamTransferColors.SecondaryInk,
            fontSize = GalleryTypeScale.Meta,
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
    thumbnailState: (Int) -> StateFlow<ByteArray?>,
    decodedThumbnailCache: GalleryDecodedThumbnailCache<Bitmap>,
    onOpenFile: (CameraFile) -> Unit,
    onToggleSelection: (CameraFile) -> Unit,
) {
    val state = downloadStates[file.info.handle]
    val loadedThumbnail by thumbnailState(file.info.handle).collectAsState()
    GalleryGridItem(
        file = file,
        thumbnail = GalleryThumbnailDisplayPolicy.thumbnailFor(file, loadedThumbnail),
        decodedThumbnailCache = decodedThumbnailCache,
        modifier = modifier,
        isSelected = file.info.handle in selectedHandles,
        downloadState = state,
        onOpen = { onOpenFile(file) },
        onToggleSelection = {
            if (GalleryDownloadUiPolicy.canSelect(state)) {
                onToggleSelection(file)
            }
        },
    )
}

private fun LocalDate?.dayLabel(today: LocalDate): String =
    when (this) {
        null -> "未知日期"
        today -> "今天 ${monthValue}月${dayOfMonth}日"
        else -> "${monthValue}月${dayOfMonth}日"
    }
