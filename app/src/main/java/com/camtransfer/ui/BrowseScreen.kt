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
    onPreferenceChanged: (Boolean) -> Unit,
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
    val previewImages by viewModel.previewImages.collectAsState()
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
    val selectableDateDays = remember(today) {
        GalleryDatePickerPolicy.selectableDays(today)
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
            days = selectableDateDays,
            onDismiss = { showsDatePicker = false },
            onSelect = { day ->
                filterState = filterState.copy(date = GalleryDateFilter.SpecificDay(day))
                showsDatePicker = false
            },
        )
    }
    if (showsDateRangePicker) {
        DateRangePickerDialog(
            days = selectableDateDays,
            initialRange = filterState.date as? GalleryDateFilter.Range,
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
            previewImages = previewImages,
            preferCompressedDownloads = preferCompressedDownloads,
            onDismiss = { previewFile = null },
            onPreviewVisible = { handles ->
                viewModel.loadPreviewThumbnails(cameraSource, handles)
            },
            onPreviewImageVisible = { currentFile ->
                viewModel.loadPreviewImage(cameraSource, currentFile)
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
            val allFilteredSelected = selectedHandles.containsAll(selectableFilteredHandles) &&
                selectableFilteredHandles.isNotEmpty()
            GalleryDownloadBar(
                selectedCount = selectedFiles.size,
                totalCount = selectableFilteredHandles.size,
                allFilteredSelected = allFilteredSelected,
                canToggleSelectAll = selectableFilteredHandles.isNotEmpty(),
                preferCompressedDownloads = preferCompressedDownloads,
                canDownload = selectedFiles.isNotEmpty(),
                onToggleSelectAll = {
                    if (allFilteredSelected) {
                        viewModel.clearSelection()
                    } else {
                        viewModel.selectHandles(selectableFilteredHandles)
                    }
                },
                onPreferenceChanged = onPreferenceChanged,
                onDownload = {
                    if (selectedFiles.isNotEmpty()) {
                        onDownloadSelected(selectedFiles)
                        viewModel.clearSelection()
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(CamTransferColors.Background),
        ) {
            GalleryHeader(
                activeDownloadCount = transferItems.count {
                    it.state == TransferState.PENDING ||
                        it.state == TransferState.DOWNLOADING ||
                        it.state == TransferState.SAVING
                },
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
                onPickDate = { showsDatePicker = true },
                onPickDateRange = { showsDateRangePicker = true },
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
                        GalleryGrid(
                            files = sortedFiles,
                            columnCount = columnCount,
                            gridState = gridState,
                            selectedHandles = selectedHandles,
                            downloadStates = downloadStates,
                            isLoadingFullObjectInfo = isLoading,
                            visibleGridHandleSet = visibleGridHandleSet,
                            onColumnCountChange = { newCount ->
                                columnCount = newCount
                                prefs.edit().putInt("columnCount", newCount).apply()
                            },
                            onSelectionChange = viewModel::selectHandles,
                            onOpenFile = { file -> previewFile = file },
                            onToggleSelection = { file -> viewModel.toggleSelection(file.info.handle) },
                            onVisible = { file -> viewModel.loadThumbnail(cameraSource, file.info.handle) },
                        )
                    }
                }
            }
        }
    }
}
