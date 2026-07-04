package com.camtransfer.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferItem
import com.camtransfer.model.TransferState
import com.camtransfer.service.CameraFileSource
import com.camtransfer.viewmodel.BrowseViewModel
import com.camtransfer.viewmodel.gallery.GalleryBrowseMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import kotlin.math.hypot

private val GalleryActionColor = Color(0xFF177C6D)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun GalleryFilterPanel(
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    state: GalleryFilterState,
    stats: GalleryFilterStats,
    isLoadingJpg: Boolean = false,
    isLoadingHiddenFormats: Boolean = false,
    onStateChange: (GalleryFilterState) -> Unit,
    sortMode: GallerySortMode,
    onSortModeChange: (GallerySortMode) -> Unit,
    activeMode: GalleryBrowseMode,
    onModeChange: (GalleryBrowseMode) -> Unit,
    onPickDate: () -> Unit,
    onPickDateRange: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .animateContentSize()
            .padding(start = 18.dp, top = 6.dp, end = 18.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FilterPanelTrigger(
                expanded = expanded,
                onClick = { onExpandedChange(!expanded) },
            )
            Spacer(Modifier.weight(1f))
            GalleryBrowseModeSegmentedControl(
                activeMode = activeMode,
                onModeChange = onModeChange,
            )
        }
        if (expanded) {
            Text(
                GalleryFilterPanelPolicy.summary(state, sortMode),
                modifier = Modifier.padding(start = 2.dp, end = 2.dp),
                color = CamTransferColors.SecondaryInk,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        AnimatedVisibility(
            visible = expanded,
            enter = fadeIn(animationSpec = tween(160)) + expandVertically(animationSpec = tween(180)),
            exit = fadeOut(animationSpec = tween(120)) + shrinkVertically(animationSpec = tween(160)),
        ) {
            CompactFilterChips(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 2.dp, top = 1.dp, end = 2.dp, bottom = 2.dp),
                state = state,
                stats = stats,
                isLoadingJpg = isLoadingJpg,
                isLoadingHiddenFormats = isLoadingHiddenFormats,
                onStateChange = onStateChange,
                sortMode = sortMode,
                onSortModeChange = onSortModeChange,
                onPickDate = onPickDate,
                onPickDateRange = onPickDateRange,
            )
        }
    }
}

@Composable
private fun FilterPanelTrigger(
    expanded: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .clip(RoundedCornerShape(22.dp))
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(22.dp),
        color = CamTransferColors.WarmFill,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
        shadowElevation = 2.dp,
    ) {
        Row(
            modifier = Modifier.padding(start = 9.dp, top = 7.dp, end = 8.dp, bottom = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            FilterPanelIcon(expanded = expanded)
            Text(
                "筛选",
                color = CamTransferColors.Ink,
                fontWeight = FontWeight.Black,
                fontSize = 13.sp,
                maxLines = 1,
            )
            FilterPanelChevron(expanded = expanded)
        }
    }
}

@Composable
internal fun GalleryBrowseModeOnlyBar(
    activeMode: GalleryBrowseMode,
    onModeChange: (GalleryBrowseMode) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 18.dp, top = 6.dp, end = 18.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        GalleryBrowseModeSegmentedControl(
            activeMode = activeMode,
            onModeChange = onModeChange,
        )
    }
}

@Composable
private fun GalleryBrowseModeSegmentedControl(
    activeMode: GalleryBrowseMode,
    onModeChange: (GalleryBrowseMode) -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(22.dp),
        color = CamTransferColors.Card,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
        shadowElevation = 4.dp,
    ) {
        Row(
            modifier = Modifier.padding(start = 10.dp, top = 4.dp, end = 4.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                "预览",
                color = CamTransferColors.SecondaryInk,
                fontSize = 12.sp,
                fontWeight = FontWeight.Black,
                maxLines = 1,
            )
            Box(
                modifier = Modifier
                    .width(1.dp)
                    .height(18.dp)
                    .background(CamTransferColors.Hairline),
            )
            GalleryBrowseModeSegment(
                label = "缩略图",
                selected = activeMode == GalleryBrowseMode.THUMBNAIL,
                onClick = { onModeChange(GalleryBrowseMode.THUMBNAIL) },
            )
            GalleryBrowseModeSegment(
                label = "高清",
                selected = activeMode == GalleryBrowseMode.HD_PREVIEW,
                onClick = { onModeChange(GalleryBrowseMode.HD_PREVIEW) },
            )
        }
    }
}

@Composable
private fun GalleryBrowseModeSegment(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val background = if (selected) CamTransferColors.Ink else Color.Transparent
    val textColor = if (selected) CamTransferColors.Card else CamTransferColors.SecondaryInk
    Box(
        modifier = Modifier
            .height(30.dp)
            .clip(RoundedCornerShape(15.dp))
            .background(background)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            color = textColor,
            fontSize = 12.sp,
            fontWeight = FontWeight.Black,
            maxLines = 1,
        )
    }
}
@Composable
private fun CompactFilterChips(
    modifier: Modifier = Modifier,
    state: GalleryFilterState,
    stats: GalleryFilterStats,
    isLoadingJpg: Boolean = false,
    isLoadingHiddenFormats: Boolean = false,
    onStateChange: (GalleryFilterState) -> Unit,
    sortMode: GallerySortMode,
    onSortModeChange: (GallerySortMode) -> Unit,
    onPickDate: () -> Unit,
    onPickDateRange: () -> Unit,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        FilterChipRow {
            LuxuryFilterChip(
                selected = state.date == GalleryDateFilter.All,
                label = "全部",
                onClick = { onStateChange(state.copy(date = GalleryDateFilter.All)) },
            )
            LuxuryFilterChip(
                selected = state.date == GalleryDateFilter.Today,
                label = "今天",
                onClick = { onStateChange(state.copy(date = GalleryDateFilter.Today)) },
            )
            val specificDay = state.date as? GalleryDateFilter.SpecificDay
            LuxuryFilterChip(
                selected = specificDay != null,
                label = specificDay?.day?.format(DateTimeFormatter.ofPattern("MM-dd")) ?: "日期",
                onClick = onPickDate,
            )
            val range = state.date as? GalleryDateFilter.Range
            LuxuryFilterChip(
                selected = range != null,
                label = range?.let { rangeLabel(it.start, it.end) } ?: "范围",
                onClick = onPickDateRange,
            )
        }
        FilterChipRow {
            LuxuryFilterChip(
                selected = state.formats.isEmpty(),
                label = "全部格式",
                onClick = { onStateChange(state.copy(formats = emptySet())) },
            )
            FormatChip("JPG", GalleryFormatFilter.Jpg, stats, state, onStateChange)
            FormatChip("HEIF", GalleryFormatFilter.Heif, stats, state, onStateChange)
            FormatChip("RAW", GalleryFormatFilter.Raw, stats, state, onStateChange)
            FormatChip("视频", GalleryFormatFilter.Video, stats, state, onStateChange)
        }
        if (stats.folderCounts.isNotEmpty()) {
            FilterChipRow {
                LuxuryFilterChip(
                    selected = state.folders.isEmpty(),
                    label = "全部文件夹",
                    onClick = { onStateChange(state.copy(folders = emptySet())) },
                )
                stats.folderCounts.forEach { folderCount ->
                    FolderChip(folderCount, state, onStateChange)
                }
            }
        }
        FilterChipRow {
            SortChip("最新", GallerySortMode.NewestFirst, sortMode, onSortModeChange)
            SortChip("最早", GallerySortMode.OldestFirst, sortMode, onSortModeChange)
            SortChip("未下载", GallerySortMode.NotDownloadedFirst, sortMode, onSortModeChange)
        }
    }
}

@Composable
private fun FilterChipRow(content: @Composable () -> Unit) {
    Row(
        modifier = Modifier.horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        content()
    }
}

internal fun rangeLabel(start: LocalDate, end: LocalDate): String {
    val first = minOf(start, end)
    val last = maxOf(start, end)
    val formatter = DateTimeFormatter.ofPattern("MM-dd")
    return "${first.format(formatter)}~${last.format(formatter)}"
}

@Composable
private fun FormatChip(
    label: String,
    format: GalleryFormatFilter,
    stats: GalleryFilterStats,
    state: GalleryFilterState,
    onStateChange: (GalleryFilterState) -> Unit,
    isLoading: Boolean = false,
) {
    LuxuryFilterChip(
        selected = format in state.formats,
        label = label,
        isLoading = isLoading,
        onClick = {
            val formats = state.formats.toMutableSet()
            if (!formats.add(format)) formats.remove(format)
            onStateChange(state.copy(formats = formats))
        },
    )
}

@Composable
private fun SortChip(
    label: String,
    mode: GallerySortMode,
    sortMode: GallerySortMode,
    onSortModeChange: (GallerySortMode) -> Unit,
) {
    LuxuryFilterChip(
        selected = sortMode == mode,
        label = label,
        onClick = { onSortModeChange(mode) },
    )
}

@Composable
private fun FolderChip(
    folderCount: GalleryFolderCount,
    state: GalleryFilterState,
    onStateChange: (GalleryFilterState) -> Unit,
) {
    LuxuryFilterChip(
        selected = folderCount.folder in state.folders,
        label = folderCount.label,
        onClick = {
            val folders = state.folders.toMutableSet()
            if (!folders.add(folderCount.folder)) folders.remove(folderCount.folder)
            onStateChange(state.copy(folders = folders))
        },
    )
}

@Composable
private fun LuxuryFilterChip(
    selected: Boolean,
    label: String,
    count: Int? = null,
    isLoading: Boolean = false,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .height(32.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        color = if (selected) CamTransferColors.Ink else Color.Transparent,
        border = BorderStroke(1.dp, if (selected) CamTransferColors.Ink else CamTransferColors.Hairline),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Text(
                label,
                color = if (selected) CamTransferColors.Card else CamTransferColors.Ink,
                fontSize = 12.sp,
                fontWeight = FontWeight.Black,
                maxLines = 1,
            )
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(10.dp),
                    strokeWidth = 1.5.dp,
                    color = if (selected) CamTransferColors.Card else CamTransferColors.SecondaryInk,
                )
            } else if (count != null) {
                Text(
                    count.toString(),
                    color = if (selected) CamTransferColors.Card.copy(alpha = 0.72f) else CamTransferColors.SecondaryInk,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun FilterPanelIcon(expanded: Boolean) {
    Box(
        modifier = Modifier
            .size(30.dp)
            .clip(CircleShape)
            .background(if (expanded) CamTransferColors.Ink else CamTransferColors.MutedFill),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.foundation.Canvas(modifier = Modifier.size(16.dp)) {
            val color = if (expanded) CamTransferColors.Card else CamTransferColors.Ink
            val strokeWidth = 1.8.dp.toPx()
            val rows = listOf(0.28f, 0.50f, 0.72f)
            rows.forEachIndexed { index, yFactor ->
                val knobX = when (index) {
                    0 -> 0.68f
                    1 -> 0.34f
                    else -> 0.56f
                }
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.18f, size.height * yFactor),
                    end = Offset(size.width * 0.82f, size.height * yFactor),
                    strokeWidth = strokeWidth,
                    cap = StrokeCap.Round,
                )
                drawCircle(
                    color = color,
                    radius = 2.2.dp.toPx(),
                    center = Offset(size.width * knobX, size.height * yFactor),
                )
            }
        }
    }
}

@Composable
private fun FilterPanelChevron(expanded: Boolean) {
    Box(
        modifier = Modifier
            .size(28.dp)
            .clip(CircleShape)
            .background(CamTransferColors.MutedFill),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.foundation.Canvas(modifier = Modifier.size(14.dp)) {
            val yStart = if (expanded) 0.60f else 0.40f
            val yEnd = if (expanded) 0.40f else 0.60f
            drawLine(
                color = CamTransferColors.Ink,
                start = Offset(size.width * 0.22f, size.height * yStart),
                end = Offset(size.width * 0.50f, size.height * yEnd),
                strokeWidth = 2.dp.toPx(),
                cap = StrokeCap.Round,
            )
            drawLine(
                color = CamTransferColors.Ink,
                start = Offset(size.width * 0.78f, size.height * yStart),
                end = Offset(size.width * 0.50f, size.height * yEnd),
                strokeWidth = 2.dp.toPx(),
                cap = StrokeCap.Round,
            )
        }
    }
}
