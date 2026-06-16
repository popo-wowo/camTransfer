package com.camtransfer.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import androidx.activity.compose.BackHandler
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
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import kotlin.math.hypot

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BrowseScreen(
    viewModel: BrowseViewModel,
    cameraSource: CameraFileSource,
    transferItems: List<TransferItem>,
    downloadedItems: List<TransferItem>,
    isTransferring: Boolean,
    preferCompressedDownloads: Boolean,
    onFilesLoaded: (List<CameraFile>) -> Unit,
    onDownloadSelected: (List<CameraFile>) -> Unit,
    onOpenDownloads: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val context = LocalContext.current
    val prefs = remember(context) {
        context.getSharedPreferences("camtransfer.gallery", android.content.Context.MODE_PRIVATE)
    }
    val files by viewModel.files.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val selectedHandles by viewModel.selectedHandles.collectAsState()
    val error by viewModel.error.collectAsState()
    var filterState by remember { mutableStateOf(GalleryFilterState()) }
    var sortMode by remember { mutableStateOf(GallerySortMode.NewestFirst) }
    var filtersExpanded by remember { mutableStateOf(GalleryFilterPanelPolicy.defaultExpanded()) }
    var showsDatePicker by remember { mutableStateOf(false) }
    var showsDateRangePicker by remember { mutableStateOf(false) }
    var showsDisconnectConfirm by remember { mutableStateOf(false) }
    var previewFile by remember { mutableStateOf<CameraFile?>(null) }
    var columnCount by remember {
        mutableStateOf(
            prefs.getInt("columnCount", GalleryColumnLayoutPolicy.DEFAULT_COLUMNS)
                .coerceIn(GalleryColumnLayoutPolicy.MIN_COLUMNS, GalleryColumnLayoutPolicy.MAX_COLUMNS)
        )
    }
    val gridState = rememberLazyGridState()
    val today = remember { LocalDate.now() }
    val downloadStates = remember(downloadedItems, transferItems) {
        (downloadedItems + transferItems).associate { it.file.info.handle to it.state }
    }
    val filteredFiles by remember(files, filterState, today) {
        derivedStateOf { GalleryUiPolicy.filteredFiles(files, filterState, today) }
    }
    val sortedFiles by remember(filteredFiles, sortMode, downloadStates) {
        derivedStateOf { GallerySortPolicy.sortedFiles(filteredFiles, sortMode, downloadStates) }
    }
    val visibleGridHandles by remember {
        derivedStateOf {
            gridState.layoutInfo.visibleItemsInfo
                .sortedBy { it.index }
                .mapNotNull { it.key as? Int }
        }
    }
    val visibleGridHandleSet by remember {
        derivedStateOf { visibleGridHandles.toSet() }
    }
    val selectableFilteredHandles = remember(sortedFiles, downloadStates) {
        sortedFiles
            .filter { GalleryDownloadUiPolicy.canSelect(downloadStates[it.info.handle]) }
            .map { it.info.handle }
            .toSet()
    }
    val selectedFiles = remember(files, selectedHandles, downloadStates) {
        files.filter {
            it.info.handle in selectedHandles &&
                GalleryDownloadUiPolicy.canSelect(downloadStates[it.info.handle])
        }
    }
    val captureDays = remember(files) {
        files.mapNotNull { GalleryUiPolicy.captureDate(it) }.distinct().sortedDescending()
    }

    LaunchedEffect(cameraSource) {
        viewModel.loadFilesIfNeeded(cameraSource)
    }

    LaunchedEffect(files) {
        if (files.isNotEmpty()) onFilesLoaded(files)
    }

    LaunchedEffect(filterState, sortMode) {
        if (GalleryScrollResetPolicy.shouldScrollToTopAfterFilterOrSortChange()) {
            gridState.scrollToItem(0)
        }
    }
    LaunchedEffect(filterState.date, files, cameraSource) {
        if (GalleryDateMetadataPolicy.shouldLoadMetadataForDateFilter(files, filterState.date)) {
            viewModel.loadFiles(cameraSource)
        }
    }
    LaunchedEffect(cameraSource, isTransferring) {
        if (!isTransferring) {
            viewModel.resumeThumbnailLoadingAfterTransfer(cameraSource)
        }
    }
    LaunchedEffect(cameraSource, visibleGridHandles, isTransferring) {
        if (!isTransferring) {
            viewModel.loadVisibleThumbnails(cameraSource, visibleGridHandles)
        }
    }

    if (showsDatePicker) {
        DatePickerDialog(
            days = captureDays,
            isLoadingMetadata = isLoading && GalleryDateMetadataPolicy.shouldLoadMetadataForDatePicker(files),
            onDismiss = { showsDatePicker = false },
            onSelect = { day ->
                filterState = filterState.copy(date = GalleryDateFilter.SpecificDay(day))
                showsDatePicker = false
            },
        )
    }
    if (showsDateRangePicker) {
        DateRangePickerDialog(
            days = captureDays,
            initialRange = filterState.date as? GalleryDateFilter.Range,
            isLoadingMetadata = isLoading && GalleryDateMetadataPolicy.shouldLoadMetadataForDatePicker(files),
            onDismiss = { showsDateRangePicker = false },
            onSelect = { start, end ->
                filterState = filterState.copy(date = GalleryDateFilter.Range(start, end))
                showsDateRangePicker = false
            },
        )
    }
    BackHandler(enabled = previewFile == null) {
        if (GalleryDisconnectPolicy.shouldConfirmBeforeDisconnect()) {
            showsDisconnectConfirm = true
        } else {
            onDisconnect()
        }
    }
    if (showsDisconnectConfirm) {
        DisconnectConfirmDialog(
            onDismiss = { showsDisconnectConfirm = false },
            onConfirm = {
                showsDisconnectConfirm = false
                onDisconnect()
            },
        )
    }
    previewFile?.let { file ->
        PhotoPreviewDialog(
            files = sortedFiles,
            initialIndex = GalleryPreviewNavigationPolicy.initialPage(sortedFiles, file.info.handle),
            downloadStates = downloadStates,
            selectedHandles = selectedHandles,
            preferCompressedDownloads = preferCompressedDownloads,
            onDismiss = { previewFile = null },
            onPreviewVisible = { handles ->
                viewModel.loadPreviewThumbnails(cameraSource, handles)
            },
            onToggleSelection = { currentFile ->
                if (GalleryDownloadUiPolicy.canSelect(downloadStates[currentFile.info.handle])) {
                    viewModel.toggleSelection(currentFile.info.handle)
                }
            },
            onDownload = { currentFile ->
                if (GalleryDownloadUiPolicy.canSelect(downloadStates[currentFile.info.handle])) {
                    onDownloadSelected(listOf(currentFile))
                    viewModel.clearSelection()
                }
            },
        )
    }

    Scaffold(
        containerColor = CamTransferColors.Background,
        bottomBar = {
            if (selectedFiles.isNotEmpty()) {
                GalleryDownloadBar(
                    selectedCount = selectedFiles.size,
                    onDownload = {
                        onDownloadSelected(selectedFiles)
                        viewModel.clearSelection()
                    },
                )
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(CamTransferColors.Background)
                .statusBarsPadding(),
        ) {
            GalleryHeader(
                fileCount = filteredFiles.size,
                totalCount = files.size,
                selectedCount = selectedFiles.size,
                columnCount = columnCount,
                activeDownloadCount = transferItems.count {
                    it.state == TransferState.PENDING ||
                        it.state == TransferState.DOWNLOADING ||
                        it.state == TransferState.SAVING
                },
                preferCompressedDownloads = preferCompressedDownloads,
                isLoading = isLoading,
                isTransferring = isTransferring,
                onBack = { showsDisconnectConfirm = true },
                onOpenDownloads = onOpenDownloads,
            )
            GalleryFilterPanel(
                expanded = filtersExpanded,
                onExpandedChange = { filtersExpanded = it },
                state = filterState,
                onStateChange = { filterState = it },
                sortMode = sortMode,
                onSortModeChange = { sortMode = it },
                onPickDate = {
                    if (GalleryDateMetadataPolicy.shouldLoadMetadataForDatePicker(files)) {
                        viewModel.loadFiles(cameraSource)
                    }
                    showsDatePicker = true
                },
                onPickDateRange = {
                    if (GalleryDateMetadataPolicy.shouldLoadMetadataForDatePicker(files)) {
                        viewModel.loadFiles(cameraSource)
                    }
                    showsDateRangePicker = true
                },
            )
            GallerySelectionTools(
                selectedCount = selectedFiles.size,
                selectableCount = selectableFilteredHandles.size,
                allFilteredSelected = selectedHandles.containsAll(selectableFilteredHandles) &&
                    selectableFilteredHandles.isNotEmpty(),
                onSelectAll = {
                    if (selectedHandles.containsAll(selectableFilteredHandles) && selectableFilteredHandles.isNotEmpty()) {
                        viewModel.clearSelection()
                    } else {
                        viewModel.selectHandles(selectableFilteredHandles)
                    }
                },
            )
            Box(Modifier.fillMaxSize()) {
                when {
                    isLoading && files.isEmpty() -> {
                        CircularProgressIndicator(
                            modifier = Modifier.align(Alignment.Center),
                            color = CamTransferColors.Accent,
                        )
                    }
                    error != null -> {
                        Column(
                            modifier = Modifier
                                .align(Alignment.Center)
                                .padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Text(error!!, color = MaterialTheme.colorScheme.error)
                            Spacer(Modifier.height(10.dp))
                            Button(onClick = { viewModel.loadFiles(cameraSource) }) {
                                Text("重试")
                            }
                        }
                    }
                    files.isEmpty() -> {
                        EmptyGalleryMessage("相机中没有文件")
                    }
                    filteredFiles.isEmpty() -> {
                        EmptyGalleryMessage("当前筛选没有照片")
                    }
                    else -> {
                        LazyVerticalGrid(
                            columns = GridCells.Fixed(columnCount),
                            state = gridState,
                            modifier = Modifier
                                .fillMaxSize()
                                .galleryColumnPinchResize(
                                    columnCount = columnCount,
                                    onColumnCountChange = { newCount ->
                                        columnCount = newCount
                                        prefs.edit().putInt("columnCount", newCount).apply()
                                    },
                                )
                                .galleryDragSelection(
                                    gridState = gridState,
                                    files = sortedFiles,
                                    selectedHandles = selectedHandles,
                                    downloadStates = downloadStates,
                                    onSelectionChange = viewModel::selectHandles,
                                ),
                            contentPadding = PaddingValues(start = 12.dp, top = 8.dp, end = 12.dp, bottom = 96.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            items(sortedFiles, key = { it.info.handle }) { file ->
                                val state = downloadStates[file.info.handle]
                                GalleryGridItem(
                                    file = file,
                                    isSelected = file.info.handle in selectedHandles,
                                    downloadState = state,
                                    isLoadingFullObjectInfo = isLoading,
                                    isItemVisible = file.info.handle in visibleGridHandleSet,
                                    onOpen = { previewFile = file },
                                    onToggleSelection = {
                                        if (GalleryDownloadUiPolicy.canSelect(state)) {
                                            viewModel.toggleSelection(file.info.handle)
                                        }
                                    },
                                    onVisible = { viewModel.loadThumbnail(cameraSource, file.info.handle) },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GalleryHeader(
    fileCount: Int,
    totalCount: Int,
    selectedCount: Int,
    columnCount: Int,
    activeDownloadCount: Int,
    preferCompressedDownloads: Boolean,
    isLoading: Boolean,
    isTransferring: Boolean,
    onBack: () -> Unit,
    onOpenDownloads: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 18.dp, top = 10.dp, end = 18.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GalleryHeaderTextAction(
                label = "返回",
                onClick = onBack,
            )
            Spacer(Modifier.weight(1f))
            GalleryHeaderButton(
                label = "下载中心",
                onClick = onOpenDownloads,
            )
        }
        Text(
            "相机照片",
            color = CamTransferColors.Ink,
            fontSize = 30.sp,
            lineHeight = 34.sp,
            fontWeight = FontWeight.Black,
        )
        Text(
            "CAMERA GALLERY",
            color = CamTransferColors.Accent,
            fontSize = 10.sp,
            fontWeight = FontWeight.Black,
            letterSpacing = 2.2.sp,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (isLoading || isTransferring) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = CamTransferColors.Accent,
                )
                Spacer(Modifier.width(8.dp))
            }
            val statusText = when {
                activeDownloadCount > 0 -> "$fileCount 张 · 每行 $columnCount 张 · 下载中 $activeDownloadCount · 已选 $selectedCount"
                totalCount == 0 -> "准备加载图库"
                else -> "$fileCount / $totalCount 张 · 每行 $columnCount 张 · 已选 $selectedCount"
            } + " · 当前模式：${downloadModeLabel(preferCompressedDownloads)}"
            Text(
                statusText,
                color = CamTransferColors.SecondaryInk,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun GalleryHeaderButton(
    label: String,
    onClick: () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = Modifier.height(38.dp),
        shape = RoundedCornerShape(19.dp),
        contentPadding = PaddingValues(horizontal = 14.dp),
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = CamTransferColors.Ink,
        ),
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Text(label, fontWeight = FontWeight.Bold, fontSize = 13.sp, maxLines = 1)
    }
}

@Composable
private fun GalleryHeaderTextAction(
    label: String,
    onClick: () -> Unit,
) {
    TextButton(
        onClick = onClick,
        modifier = Modifier.height(38.dp),
        contentPadding = PaddingValues(horizontal = 6.dp),
        colors = ButtonDefaults.textButtonColors(contentColor = CamTransferColors.Ink),
    ) {
        Text(label, fontWeight = FontWeight.Bold, fontSize = 14.sp, maxLines = 1)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun GalleryFilterPanel(
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    state: GalleryFilterState,
    onStateChange: (GalleryFilterState) -> Unit,
    sortMode: GallerySortMode,
    onSortModeChange: (GallerySortMode) -> Unit,
    onPickDate: () -> Unit,
    onPickDateRange: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 22.dp, top = 6.dp, end = 22.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onExpandedChange(!expanded) },
            shape = RoundedCornerShape(10.dp),
            color = CamTransferColors.MutedFill,
            border = BorderStroke(1.dp, CamTransferColors.Hairline),
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    "筛选/排序",
                    color = CamTransferColors.Ink,
                    fontWeight = FontWeight.Black,
                    fontSize = 13.sp,
                    maxLines = 1,
                )
                Text(
                    GalleryFilterPanelPolicy.summary(state, sortMode),
                    modifier = Modifier.weight(1f),
                    color = CamTransferColors.SecondaryInk,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (expanded) "收起" else "展开",
                    color = CamTransferColors.Ink,
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.sp,
                    maxLines = 1,
                )
            }
        }
        if (expanded) {
            CompactFilterChips(
                state = state,
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
private fun CompactFilterChips(
    state: GalleryFilterState,
    onStateChange: (GalleryFilterState) -> Unit,
    sortMode: GallerySortMode,
    onSortModeChange: (GallerySortMode) -> Unit,
    onPickDate: () -> Unit,
    onPickDateRange: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
            FormatChip("JPG", GalleryFormatFilter.Jpg, state, onStateChange)
            FormatChip("HEIF", GalleryFormatFilter.Heif, state, onStateChange)
            FormatChip("RAW", GalleryFormatFilter.Raw, state, onStateChange)
            FormatChip("视频", GalleryFormatFilter.Video, state, onStateChange)
        }
        FilterChipRow {
            SortChip("最新", GallerySortMode.NewestFirst, sortMode, onSortModeChange)
            SortChip("最早", GallerySortMode.OldestFirst, sortMode, onSortModeChange)
            SortChip("未下载", GallerySortMode.NotDownloadedFirst, sortMode, onSortModeChange)
        }
    }
}

@Composable
private fun GallerySelectionTools(
    selectedCount: Int,
    selectableCount: Int,
    allFilteredSelected: Boolean,
    onSelectAll: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 22.dp, top = 8.dp, end = 22.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "可选 $selectableCount 张 · 已选 $selectedCount",
            modifier = Modifier.weight(1f),
            color = CamTransferColors.SecondaryInk,
            style = MaterialTheme.typography.bodySmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Button(
            onClick = onSelectAll,
            enabled = selectableCount > 0,
            modifier = Modifier.height(38.dp),
            shape = RoundedCornerShape(10.dp),
            contentPadding = PaddingValues(horizontal = 14.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = CamTransferColors.Ink,
                contentColor = CamTransferColors.Card,
                disabledContainerColor = CamTransferColors.MutedFill,
                disabledContentColor = CamTransferColors.SecondaryInk,
            ),
            elevation = ButtonDefaults.buttonElevation(defaultElevation = 0.dp, pressedElevation = 0.dp),
        ) {
            Text(
                if (allFilteredSelected) "取消全选" else "全选当前筛选",
                fontWeight = FontWeight.Bold,
                fontSize = 13.sp,
                maxLines = 1,
            )
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

private fun rangeLabel(start: LocalDate, end: LocalDate): String {
    val first = minOf(start, end)
    val last = maxOf(start, end)
    val formatter = DateTimeFormatter.ofPattern("MM-dd")
    return "${first.format(formatter)}~${last.format(formatter)}"
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FormatChip(
    label: String,
    format: GalleryFormatFilter,
    state: GalleryFilterState,
    onStateChange: (GalleryFilterState) -> Unit,
) {
    LuxuryFilterChip(
        selected = format in state.formats,
        label = label,
        onClick = {
            val formats = state.formats.toMutableSet()
            if (!formats.add(format)) formats.remove(format)
            onStateChange(state.copy(formats = formats))
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LuxuryFilterChip(selected: Boolean, label: String, onClick: () -> Unit) {
    FilterChip(
        selected = selected,
        onClick = onClick,
        label = { Text(label, fontWeight = FontWeight.SemiBold) },
        border = BorderStroke(1.dp, if (selected) CamTransferColors.Ink else CamTransferColors.Hairline),
        colors = androidx.compose.material3.FilterChipDefaults.filterChipColors(
            selectedContainerColor = CamTransferColors.Ink,
            selectedLabelColor = CamTransferColors.Card,
            containerColor = CamTransferColors.MutedFill,
            labelColor = CamTransferColors.Ink,
        ),
    )
}

@Composable
private fun Modifier.galleryColumnPinchResize(
    columnCount: Int,
    onColumnCountChange: (Int) -> Unit,
): Modifier = pointerInput(columnCount) {
    fun distance(first: Offset, second: Offset): Float =
        hypot((first.x - second.x).toDouble(), (first.y - second.y).toDouble()).toFloat()

    awaitEachGesture {
        var startDistance: Float? = null
        while (true) {
            val event = awaitPointerEvent()
            val pressed = event.changes.filter { it.pressed }
            if (pressed.isEmpty()) return@awaitEachGesture
            if (pressed.size < 2) continue

            val currentDistance = distance(pressed[0].position, pressed[1].position)
            val baseDistance = startDistance ?: currentDistance.also { startDistance = it }
            if (baseDistance <= 0f) continue

            val target = GalleryColumnLayoutPolicy.targetColumns(
                currentColumns = columnCount,
                pinchScale = currentDistance / baseDistance,
            )
            if (target != columnCount) {
                pressed.forEach { it.consume() }
                onColumnCountChange(target)
                startDistance = currentDistance
                return@awaitEachGesture
            }
            pressed.forEach { it.consume() }
        }
    }
}

@Composable
private fun Modifier.galleryDragSelection(
    gridState: LazyGridState,
    files: List<CameraFile>,
    selectedHandles: Set<Int>,
    downloadStates: Map<Int, TransferState?>,
    onSelectionChange: (Set<Int>) -> Unit,
): Modifier {
    val currentFiles by rememberUpdatedState(files)
    val currentSelectedHandles by rememberUpdatedState(selectedHandles)
    val currentDownloadStates by rememberUpdatedState(downloadStates)
    val currentOnSelectionChange by rememberUpdatedState(onSelectionChange)

    return pointerInput(gridState) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val startHandle = gridState.handleAt(down.position, currentFiles) ?: return@awaitEachGesture
            if (!GalleryDownloadUiPolicy.canSelect(currentDownloadStates[startHandle])) return@awaitEachGesture

            var shouldSelect: Boolean? = null
            var nextSelection = currentSelectedHandles
            var lastHandle: Int? = null

            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) break
                if (event.changes.count { it.pressed } > 1) break

                val activeShouldSelect = shouldSelect
                val resolvedShouldSelect = if (activeShouldSelect == null) {
                    val delta = change.position - down.position
                    if (GalleryDragSelectionPolicy.shouldStartDragSelection(
                            deltaX = delta.x,
                            deltaY = delta.y,
                            touchSlop = viewConfiguration.touchSlop,
                        )
                    ) {
                        GalleryDragSelectionPolicy.shouldSelectForDrag(
                            startHandleSelected = startHandle in currentSelectedHandles,
                        ).also {
                            shouldSelect = it
                            nextSelection = GalleryDragSelectionPolicy.updatedSelection(
                                currentSelection = nextSelection,
                                handle = startHandle,
                                downloadState = currentDownloadStates[startHandle],
                                shouldSelect = it,
                            )
                            lastHandle = startHandle
                            currentOnSelectionChange(nextSelection)
                        }
                    } else {
                        null
                    }
                } else {
                    activeShouldSelect
                }
                if (resolvedShouldSelect != null) {
                    val handle = gridState.handleAt(change.position, currentFiles)
                    if (handle != null && handle != lastHandle) {
                        val updatedSelection = GalleryDragSelectionPolicy.updatedSelection(
                            currentSelection = nextSelection,
                            handle = handle,
                            downloadState = currentDownloadStates[handle],
                            shouldSelect = resolvedShouldSelect,
                        )
                        if (updatedSelection != nextSelection) {
                            nextSelection = updatedSelection
                            currentOnSelectionChange(nextSelection)
                        }
                        lastHandle = handle
                    }
                    change.consume()
                }
            }
        }
    }
}

private fun LazyGridState.handleAt(position: Offset, files: List<CameraFile>): Int? {
    val item = layoutInfo.visibleItemsInfo.firstOrNull { item ->
        position.x >= item.offset.x &&
            position.x < item.offset.x + item.size.width &&
            position.y >= item.offset.y &&
            position.y < item.offset.y + item.size.height
    } ?: return null
    return files.getOrNull(item.index)?.info?.handle
}

@Composable
private fun DisconnectConfirmDialog(
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(GalleryDisconnectPolicy.confirmTitle) },
        text = { Text(GalleryDisconnectPolicy.confirmMessage) },
        confirmButton = {
            Button(
                onClick = onConfirm,
                colors = ButtonDefaults.buttonColors(
                    containerColor = CamTransferColors.Ink,
                    contentColor = CamTransferColors.Card,
                ),
            ) {
                Text("确认断开")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("继续停留")
            }
        },
    )
}

@Composable
private fun GalleryGridItem(
    file: CameraFile,
    isSelected: Boolean,
    downloadState: TransferState?,
    isLoadingFullObjectInfo: Boolean,
    isItemVisible: Boolean,
    onOpen: () -> Unit,
    onToggleSelection: () -> Unit,
    onVisible: () -> Unit,
) {
    LaunchedEffect(file.info.handle, file.thumbnail, isLoadingFullObjectInfo, isItemVisible) {
        if (
            GalleryThumbnailVisibilityPolicy.shouldRequestThumbnail(
                isItemVisible = isItemVisible,
                isLoadingFullObjectInfo = isLoadingFullObjectInfo,
                hasThumbnail = file.thumbnail != null,
            )
        ) {
            onVisible()
        }
    }
    var tileVisible by remember(file.info.handle) { mutableStateOf(false) }
    LaunchedEffect(file.info.handle) {
        tileVisible = true
    }
    val tileScale by animateFloatAsState(
        targetValue = if (tileVisible) 1f else 0.985f,
        animationSpec = tween(durationMillis = 140, easing = FastOutSlowInEasing),
        label = "galleryTileScale",
    )
    val tileAlpha by animateFloatAsState(
        targetValue = if (tileVisible) 1f else 0.72f,
        animationSpec = tween(durationMillis = 140, easing = FastOutSlowInEasing),
        label = "galleryTileAlpha",
    )

    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .graphicsLayer {
                scaleX = tileScale
                scaleY = tileScale
                alpha = tileAlpha
            }
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0xFFEDEBE5))
            .clickable { onOpen() }
    ) {
        val thumb = file.thumbnail
        if (thumb != null) {
            val bitmap by produceState<Bitmap?>(initialValue = null, thumb, file.info) {
                value = withContext(Dispatchers.Default) {
                    decodeThumbnailBitmapForDisplay(
                        file = file,
                        data = thumb,
                        maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
                    )
                }
            }
            val currentBitmap = bitmap
            if (currentBitmap != null) {
                Image(
                    bitmap = currentBitmap.asImageBitmap(),
                    contentDescription = file.info.filename,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            } else {
                PlaceholderBox(file)
            }
        } else {
            PlaceholderBox(file)
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.55f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.16f),
                    )
                )
        )

        if (GalleryDownloadUiPolicy.canSelect(downloadState)) {
            SelectionDot(
                isSelected = isSelected,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .clickable { onToggleSelection() },
            )
        }

        DownloadStateBadge(downloadState, modifier = Modifier.align(Alignment.TopEnd))
    }
}

@Composable
private fun SelectionDot(isSelected: Boolean, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .padding(7.dp)
            .size(26.dp)
            .clip(CircleShape)
            .background(if (isSelected) CamTransferColors.Ink else Color.White.copy(alpha = 0.72f))
            .border(1.5.dp, Color.White.copy(alpha = 0.72f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        if (isSelected) {
            Text("✓", color = CamTransferColors.Card, fontSize = 15.sp, fontWeight = FontWeight.Black)
        }
    }
}

@Composable
private fun DownloadStateBadge(state: TransferState?, modifier: Modifier = Modifier) {
    when (state) {
        TransferState.PENDING -> SmallBadge("排队", modifier)
        TransferState.DOWNLOADING, TransferState.SAVING -> {
            Box(
                modifier = modifier
                    .padding(7.dp)
                    .size(28.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.42f)),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = Color.White,
                )
            }
        }
        TransferState.DONE -> SmallBadge("已保存", modifier)
        TransferState.ERROR -> SmallBadge("失败", modifier, background = MaterialTheme.colorScheme.error)
        null -> Unit
    }
}

@Composable
private fun SmallBadge(
    label: String,
    modifier: Modifier = Modifier,
    background: Color = CamTransferColors.Ink.copy(alpha = 0.82f),
    foreground: Color = CamTransferColors.Card,
    fontSize: androidx.compose.ui.unit.TextUnit = 8.sp,
) {
    Box(
        modifier = modifier
            .padding(6.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(background)
            .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Text(label, color = foreground, fontSize = fontSize, fontWeight = FontWeight.Black)
    }
}

@Composable
private fun GalleryDownloadBar(
    selectedCount: Int,
    onDownload: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 18.dp, vertical = 14.dp),
        shape = RoundedCornerShape(28.dp),
        color = CamTransferColors.WarmFill,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
        shadowElevation = 12.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp)
                .padding(start = 18.dp, end = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "已选 $selectedCount 张",
                color = CamTransferColors.Ink,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Button(
                onClick = onDownload,
                colors = ButtonDefaults.buttonColors(
                    containerColor = CamTransferColors.Ink,
                    contentColor = CamTransferColors.Card,
                ),
            ) {
                Text(
                    "下载",
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

@Composable
private fun PhotoPreviewDialog(
    files: List<CameraFile>,
    initialIndex: Int,
    downloadStates: Map<Int, TransferState>,
    selectedHandles: Set<Int>,
    preferCompressedDownloads: Boolean,
    onDismiss: () -> Unit,
    onPreviewVisible: (List<Int>) -> Unit,
    onToggleSelection: (CameraFile) -> Unit,
    onDownload: (CameraFile) -> Unit,
) {
    val pagerState = rememberPagerState(
        initialPage = initialIndex.coerceIn(0, (files.size - 1).coerceAtLeast(0)),
        pageCount = { files.size },
    )
    val currentFile = files.getOrNull(pagerState.currentPage) ?: return
    val downloadState = downloadStates[currentFile.info.handle]
    val canDownload = GalleryDownloadUiPolicy.canSelect(downloadState)
    val isSelected = currentFile.info.handle in selectedHandles
    var manualRotationDegrees by remember(currentFile.info.handle) { mutableStateOf(0) }
    var previewVisible by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        previewVisible = true
    }
    val previewThumbnailHandles = remember(files, pagerState.currentPage) {
        GalleryPreviewThumbnailPolicy.handlesToRequest(
            files = files,
            currentPage = pagerState.currentPage,
        )
    }
    LaunchedEffect(previewThumbnailHandles) {
        onPreviewVisible(previewThumbnailHandles)
    }
    val previewAlpha by animateFloatAsState(
        targetValue = if (previewVisible) 1f else 0f,
        animationSpec = tween(durationMillis = 180, easing = FastOutSlowInEasing),
        label = "previewDialogAlpha",
    )
    val previewScale by animateFloatAsState(
        targetValue = if (previewVisible) 1f else 0.975f,
        animationSpec = tween(durationMillis = 180, easing = FastOutSlowInEasing),
        label = "previewDialogScale",
    )

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black)
                .graphicsLayer {
                    alpha = previewAlpha
                    scaleX = previewScale
                    scaleY = previewScale
                }
        ) {
            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize(),
                key = { index -> files[index].info.handle },
            ) { page ->
                val pageFile = files[page]
                ZoomablePreviewImage(
                    file = pageFile,
                    manualRotationDegrees = if (pageFile.info.handle == currentFile.info.handle) {
                        manualRotationDegrees
                    } else {
                        0
                    },
                )
            }

            Row(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .background(Color.Black.copy(alpha = 0.46f))
                    .statusBarsPadding()
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDismiss) {
                    Text("关闭", color = Color.White)
                }
                PreviewSelectionButton(
                    isSelected = isSelected,
                    enabled = canDownload,
                    onClick = { onToggleSelection(currentFile) },
                )
                TextButton(
                    onClick = {
                        manualRotationDegrees =
                            GalleryPreviewRotationPolicy.nextManualRotationDegrees(manualRotationDegrees)
                    },
                ) {
                    Text("旋转", color = Color.White)
                }
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        "${pagerState.currentPage + 1} / ${files.size} · 模式：${downloadModeLabel(preferCompressedDownloads)} · ${currentFile.info.formatLabel}",
                        color = Color.White.copy(alpha = 0.72f),
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                TextButton(
                    onClick = { onDownload(currentFile) },
                    enabled = canDownload,
                ) {
                    Text(
                        when (downloadState) {
                            TransferState.PENDING -> "排队"
                            TransferState.DOWNLOADING -> "下载中"
                            TransferState.SAVING -> "保存中"
                            TransferState.DONE -> "已保存"
                            TransferState.ERROR -> "重试"
                            null -> "下载"
                        },
                        color = if (canDownload) Color.White else Color.White.copy(alpha = 0.5f),
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        }
    }
}

private fun downloadModeLabel(preferCompressedDownloads: Boolean): String =
    if (preferCompressedDownloads) "压缩" else "原图"

@Composable
private fun PreviewSelectionButton(
    isSelected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .size(40.dp)
            .clickable(enabled = enabled) { onClick() },
        shape = CircleShape,
        color = when {
            isSelected -> Color.White
            enabled -> Color.White.copy(alpha = 0.14f)
            else -> Color.White.copy(alpha = 0.06f)
        },
        border = BorderStroke(1.dp, Color.White.copy(alpha = if (enabled) 0.62f else 0.28f)),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(
                if (isSelected) "✓" else "",
                color = CamTransferColors.Ink,
                fontSize = 20.sp,
                fontWeight = FontWeight.Black,
            )
        }
    }
}

@Composable
private fun ZoomablePreviewImage(
    file: CameraFile,
    manualRotationDegrees: Int,
) {
    var scale by remember(file.info.handle) { mutableStateOf(1f) }
    var offset by remember(file.info.handle) { mutableStateOf(Offset.Zero) }
    var isTransforming by remember(file.info.handle) { mutableStateOf(false) }
    var imageVisible by remember(file.info.handle) { mutableStateOf(false) }
    LaunchedEffect(file.info.handle) {
        imageVisible = true
    }
    val settleSpec = spring<Float>(
        dampingRatio = Spring.DampingRatioNoBouncy,
        stiffness = Spring.StiffnessMediumLow,
    )
    val displayScale by animateFloatAsState(
        targetValue = scale,
        animationSpec = if (isTransforming) snap() else settleSpec,
        label = "previewImageScale",
    )
    val displayOffsetX by animateFloatAsState(
        targetValue = offset.x,
        animationSpec = if (isTransforming) snap() else settleSpec,
        label = "previewImageOffsetX",
    )
    val displayOffsetY by animateFloatAsState(
        targetValue = offset.y,
        animationSpec = if (isTransforming) snap() else settleSpec,
        label = "previewImageOffsetY",
    )
    val imageAlpha by animateFloatAsState(
        targetValue = if (imageVisible) 1f else 0f,
        animationSpec = tween(durationMillis = 180, easing = FastOutSlowInEasing),
        label = "previewImageAlpha",
    )
    val thumb = file.thumbnail
    val bitmap = remember(thumb) {
        thumb?.let {
            decodeThumbnailBitmap(
                data = it,
                maxDecodedSide = GalleryThumbnailDecodePolicy.PREVIEW_MAX_DECODED_SIDE,
            )
        }
    }
    val autoRotationDegrees = remember(file.info, thumb, bitmap) {
        if (bitmap == null) {
            0
        } else {
            GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = file,
                decodedWidth = bitmap.width,
                decodedHeight = bitmap.height,
                imageData = thumb,
            )
        }
    }
    val displayRotationDegrees = remember(autoRotationDegrees, manualRotationDegrees) {
        (autoRotationDegrees + manualRotationDegrees) % 360
    }
    val displayBitmap = remember(bitmap, displayRotationDegrees) {
        bitmap?.let { rotateBitmapForDisplay(it, displayRotationDegrees) }
    }
    if (displayBitmap != null) {
        Image(
            bitmap = displayBitmap.asImageBitmap(),
            contentDescription = file.info.filename,
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(file.info.handle) {
                    awaitEachGesture {
                        while (true) {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.isEmpty()) break

                            if (pressed.size >= 2) {
                                isTransforming = true
                                val currentDistance = hypot(
                                    (pressed[0].position.x - pressed[1].position.x).toDouble(),
                                    (pressed[0].position.y - pressed[1].position.y).toDouble(),
                                ).toFloat()
                                val previousDistance = hypot(
                                    (pressed[0].previousPosition.x - pressed[1].previousPosition.x).toDouble(),
                                    (pressed[0].previousPosition.y - pressed[1].previousPosition.y).toDouble(),
                                ).toFloat()
                                val zoom = if (previousDistance > 0f) currentDistance / previousDistance else 1f
                                val pan = Offset(
                                    x = ((pressed[0].position.x - pressed[0].previousPosition.x) +
                                        (pressed[1].position.x - pressed[1].previousPosition.x)) / 2f,
                                    y = ((pressed[0].position.y - pressed[0].previousPosition.y) +
                                        (pressed[1].position.y - pressed[1].previousPosition.y)) / 2f,
                                )
                                val nextScale = (scale * zoom).coerceIn(1f, 4f)
                                scale = nextScale
                                offset = if (nextScale == 1f) {
                                    Offset.Zero
                                } else {
                                    offset + pan
                                }
                                event.changes.forEach { it.consume() }
                            }
                        }
                        isTransforming = false
                        if (scale < 1.02f) {
                            scale = 1f
                            offset = Offset.Zero
                        }
                    }
                }
                .graphicsLayer {
                    alpha = imageAlpha
                    scaleX = displayScale
                    scaleY = displayScale
                    translationX = displayOffsetX
                    translationY = displayOffsetY
                },
            contentScale = ContentScale.Fit,
        )
    } else {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(file.info.formatLabel, color = Color.White.copy(alpha = 0.5f))
        }
    }
}

@Composable
private fun DatePickerDialog(
    days: List<LocalDate>,
    isLoadingMetadata: Boolean,
    onDismiss: () -> Unit,
    onSelect: (LocalDate) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
        title = { Text("选择日期") },
        text = {
            if (days.isEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (isLoadingMetadata) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = CamTransferColors.Accent,
                        )
                        Spacer(Modifier.width(10.dp))
                    }
                    Text(GalleryDateDialogPolicy.emptyMessage(isLoadingMetadata))
                }
            } else {
                LazyColumn(modifier = Modifier.height(280.dp)) {
                    items(days) { day ->
                        Text(
                            day.format(DateTimeFormatter.ofPattern("yyyy-MM-dd")),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onSelect(day) }
                                .padding(vertical = 14.dp),
                            color = CamTransferColors.Ink,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }
        },
    )
}

@Composable
private fun DateRangePickerDialog(
    days: List<LocalDate>,
    initialRange: GalleryDateFilter.Range?,
    isLoadingMetadata: Boolean,
    onDismiss: () -> Unit,
    onSelect: (LocalDate, LocalDate) -> Unit,
) {
    var startDay by remember(initialRange) { mutableStateOf(initialRange?.start) }
    var endDay by remember(initialRange) { mutableStateOf(initialRange?.end) }
    val normalizedStart = startDay?.let { start -> endDay?.let { minOf(start, it) } ?: start }
    val normalizedEnd = startDay?.let { start -> endDay?.let { maxOf(start, it) } ?: start }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                enabled = startDay != null,
                onClick = {
                    val start = startDay ?: return@TextButton
                    onSelect(start, endDay ?: start)
                },
            ) {
                Text("确定")
            }
        },
        dismissButton = {
            Row {
                TextButton(
                    onClick = {
                        startDay = null
                        endDay = null
                    },
                ) { Text("清除") }
                TextButton(onClick = onDismiss) { Text("取消") }
            }
        },
        title = { Text("选择时间范围") },
        text = {
            if (days.isEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (isLoadingMetadata) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            strokeWidth = 2.dp,
                            color = CamTransferColors.Accent,
                        )
                        Spacer(Modifier.width(10.dp))
                    }
                    Text(GalleryDateDialogPolicy.emptyMessage(isLoadingMetadata))
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        when {
                            startDay == null -> "先选开始日期"
                            endDay == null -> "再选结束日期；只选一天也可以确定"
                            else -> "已选 ${rangeLabel(startDay!!, endDay!!)}"
                        },
                        color = CamTransferColors.SecondaryInk,
                        style = MaterialTheme.typography.bodySmall,
                    )
                    LazyColumn(modifier = Modifier.height(280.dp)) {
                        items(days) { day ->
                            val selected = normalizedStart != null &&
                                normalizedEnd != null &&
                                day in normalizedStart..normalizedEnd
                            Text(
                                day.format(DateTimeFormatter.ofPattern("yyyy-MM-dd")),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(if (selected) CamTransferColors.MutedFill else Color.Transparent)
                                    .clickable {
                                        if (startDay == null || endDay != null) {
                                            startDay = day
                                            endDay = null
                                        } else {
                                            endDay = day
                                        }
                                    }
                                    .padding(horizontal = 10.dp, vertical = 14.dp),
                                color = CamTransferColors.Ink,
                                fontWeight = if (selected) FontWeight.Black else FontWeight.SemiBold,
                            )
                        }
                    }
                }
            }
        },
    )
}

@Composable
private fun EmptyGalleryMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = CamTransferColors.SecondaryInk)
    }
}

private fun decodeThumbnailBitmapForDisplay(
    file: CameraFile,
    data: ByteArray,
    maxDecodedSide: Int,
): Bitmap? {
    val bitmap = decodeThumbnailBitmap(data, maxDecodedSide) ?: return null
    val rotationDegrees = GalleryThumbnailDisplayPolicy.rotationDegrees(
        file = file,
        decodedWidth = bitmap.width,
        decodedHeight = bitmap.height,
        thumbnail = data,
    )
    return rotateBitmapForDisplay(bitmap, rotationDegrees)
}

private fun decodeThumbnailBitmap(
    data: ByteArray,
    maxDecodedSide: Int = GalleryThumbnailDecodePolicy.PREVIEW_MAX_DECODED_SIDE,
) = decodeThumbnailBitmapLegacy(data, maxDecodedSide)
    ?: if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        runCatching {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val sampleSize = GalleryThumbnailDecodePolicy.sampleSize(
                    width = info.size.width,
                    height = info.size.height,
                    maxDecodedSide = maxDecodedSide,
                )
                if (sampleSize > 1) {
                    decoder.setTargetSampleSize(sampleSize)
                }
            }
        }.getOrNull()
    } else {
        null
    }

private fun decodeThumbnailBitmapLegacy(data: ByteArray, maxDecodedSide: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
    val sampleSize = GalleryThumbnailDecodePolicy.sampleSize(
        width = bounds.outWidth,
        height = bounds.outHeight,
        maxDecodedSide = maxDecodedSide,
    )
    return BitmapFactory.decodeByteArray(
        data,
        0,
        data.size,
        BitmapFactory.Options().apply { inSampleSize = sampleSize },
    )
}

private fun rotateBitmapForDisplay(bitmap: Bitmap, degrees: Int): Bitmap {
    val normalizedDegrees = ((degrees % 360) + 360) % 360
    if (normalizedDegrees == 0) return bitmap
    val matrix = Matrix().apply { postRotate(normalizedDegrees.toFloat()) }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
}

@Composable
private fun PlaceholderBox(file: CameraFile) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFFEDEBE5)),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            file.info.formatLabel,
            style = MaterialTheme.typography.bodySmall,
            color = CamTransferColors.SecondaryInk,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
