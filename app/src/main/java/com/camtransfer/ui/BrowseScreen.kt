package com.camtransfer.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import android.util.Log
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
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
import com.camtransfer.localproofing.LocalProofingPhotoMapper
import com.camtransfer.localproofing.LocalProofingQrCode
import com.camtransfer.localproofing.LocalProofingRequestRouter
import com.camtransfer.localproofing.LocalProofingServer
import com.camtransfer.localproofing.LocalProofingSessionToken
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.AppCacheLimitOption
import com.camtransfer.service.AppCacheSettingsStore
import com.camtransfer.service.AppCacheUsagePolicy
import com.camtransfer.service.DownloadFolderPathPolicy
import com.camtransfer.service.DownloadFolderSaveMode
import com.camtransfer.service.DownloadFolderSettings
import com.camtransfer.service.DownloadFolderSettingsStore
import com.camtransfer.service.DiagnosticLog
import com.camtransfer.viewmodel.BrowseViewModel
import com.camtransfer.viewmodel.gallery.GalleryBrowseMode
import com.camtransfer.viewmodel.gallery.HighDefinitionPreviewSessionPolicy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
    canChangeTransferMode: Boolean = true,
    onFilesLoaded: (List<CameraFile>) -> Unit,
    onPreferenceChanged: (Boolean) -> Unit,
    onQueueDownloadSelected: (List<CameraFile>) -> Unit,
    onCancelQueuedDownloads: (List<CameraFile>) -> Unit,
    onDownloadSelected: (List<CameraFile>) -> Unit,
    onStartQueuedDownloads: () -> Unit,
    onOpenDownloads: () -> Unit,
    onDisconnect: () -> Unit,
) {
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    var cacheRefreshToken by remember { mutableStateOf(0) }
    val prefs = remember(context) {
        context.getSharedPreferences("camtransfer.gallery", android.content.Context.MODE_PRIVATE)
    }
    val downloadFolderSettingsStore = remember(context) { DownloadFolderSettingsStore(context) }
    val appCacheSettingsStore = remember(context) { AppCacheSettingsStore(context) }
    val files by viewModel.files.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isLoadingHiddenFormats by viewModel.isLoadingHiddenFormats.collectAsState()
    val browseModeState by viewModel.browseModeState.collectAsState()
    val selectedHandles by viewModel.selectedHandles.collectAsState()
    val previewImages by viewModel.previewImages.collectAsState()
    val loadedPreviewHandles by viewModel.loadedPreviewHandles.collectAsState()
    val loadingPreviewHandles by viewModel.loadingPreviewHandles.collectAsState()
    val failedPreviewHandles by viewModel.failedPreviewHandles.collectAsState()
    val error by viewModel.error.collectAsState()
    val hasGalleryFiles = files.isNotEmpty()
    val cacheUsageLabel by produceState<String?>(initialValue = null, context, cacheRefreshToken, hasGalleryFiles, isLoading) {
        if (!GalleryCacheUsageUiPolicy.shouldScanCacheUsage(hasFiles = hasGalleryFiles, isLoading = isLoading)) {
            value = null
            return@produceState
        }
        delay(GalleryCacheUsageUiPolicy.INITIAL_SCAN_DELAY_MS)
        value = withContext(Dispatchers.IO) {
            AppCacheUsagePolicy.format(AppCacheUsagePolicy.usage(context.cacheDir).bytes)
        }
    }
    var filterState by remember { mutableStateOf(GalleryFilterState()) }
    var sortMode by remember { mutableStateOf(GallerySortMode.NewestFirst) }
    var filtersExpanded by remember { mutableStateOf(GalleryFilterPanelPolicy.defaultExpanded()) }
    var expandedSectionDays by remember { mutableStateOf<Set<LocalDate>>(emptySet()) }
    var showsDatePicker by remember { mutableStateOf(false) }
    var showsDateRangePicker by remember { mutableStateOf(false) }
    var showsDisconnectConfirm by remember { mutableStateOf(false) }
    var previewFile by remember { mutableStateOf<CameraFile?>(null) }
    var localProofingServer by remember { mutableStateOf<LocalProofingServer?>(null) }
    var localProofingState by remember { mutableStateOf<LocalProofingShareUiState?>(null) }
    var localProofingError by remember { mutableStateOf<String?>(null) }
    var showsDownloadFolderSettings by remember { mutableStateOf(false) }
    var showsCacheSettings by remember { mutableStateOf(false) }
    var downloadFolderSettings by remember { mutableStateOf(downloadFolderSettingsStore.load()) }
    var cacheLimitOption by remember { mutableStateOf(appCacheSettingsStore.loadLimit()) }
    var columnCount by remember {
        mutableStateOf(
            prefs.getInt("columnCount", GalleryColumnLayoutPolicy.DEFAULT_COLUMNS)
                .coerceIn(GalleryColumnLayoutPolicy.MIN_COLUMNS, GalleryColumnLayoutPolicy.MAX_COLUMNS)
        )
    }
    val customFolderPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocumentTree(),
    ) { uri ->
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
            val updated = downloadFolderSettings.copy(
                saveMode = DownloadFolderSaveMode.CUSTOM_TREE,
                customTreeUri = uri.toString(),
                customTreeLabel = DownloadFolderPathPolicy.customTreeLabel(uri),
            )
            downloadFolderSettings = updated
        }
    }
    val gridState = rememberLazyGridState()
    val today = remember { LocalDate.now() }
    val downloadStates = remember(downloadedItems, transferItems) {
        (downloadedItems + transferItems).associate { it.file.info.handle to it.state }
    }
    val hasPendingQueuedDownloads by remember(transferItems) {
        derivedStateOf {
            transferItems.any { it.state == TransferState.PENDING }
        }
    }
    val filteredFiles by remember(files, filterState, today) {
        derivedStateOf { GalleryUiPolicy.filteredFiles(files, filterState, today) }
    }
    val filterStats by remember(files) {
        derivedStateOf { GalleryFilterStatsPolicy.stats(files) }
    }
    val sortedFiles by remember(filteredFiles, sortMode, downloadStates) {
        derivedStateOf { GallerySortPolicy.sortedFiles(filteredFiles, sortMode, downloadStates) }
    }
    val highDefinitionPreviewFiles by remember(files, browseModeState.highDefinitionDate) {
        derivedStateOf {
            HighDefinitionPreviewSessionPolicy.previewableFilesForDate(
                files = files,
                activeDate = browseModeState.highDefinitionDate,
            )
        }
    }
    val highDefinitionPreviewItems by remember(files, browseModeState.highDefinitionDate) {
        derivedStateOf {
            HighDefinitionPreviewSessionPolicy.previewItemsForDate(
                files = files,
                activeDate = browseModeState.highDefinitionDate,
            )
        }
    }
    val gallerySections by remember(sortedFiles, expandedSectionDays) {
        derivedStateOf {
            if (GallerySectionPolicy.shouldShowDateSections(sortedFiles)) {
                GallerySectionPolicy.sections(
                    files = sortedFiles,
                    expandedDays = expandedSectionDays,
                )
            } else {
                emptyList()
            }
        }
    }
    val visibleGridHandles by remember {
        derivedStateOf {
            gridState.layoutInfo.visibleItemsInfo
                .sortedBy { it.index }
                .mapNotNull { it.key as? Int }
        }
    }
    val thumbnailRequestHandles by remember {
        derivedStateOf {
            GalleryThumbnailRequestWindowPolicy.handlesToRequest(
                orderedHandles = sortedFiles.map { it.info.handle },
                visibleHandles = visibleGridHandles,
                columnCount = columnCount,
            )
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
    val currentFiles by rememberUpdatedState(files)
    val selectableDateDays = remember(today) {
        GalleryDatePickerPolicy.selectableDays(today)
    }
    val highDefinitionPreviewDateDays by remember(files) {
        derivedStateOf { HighDefinitionPreviewSessionPolicy.availableDates(files) }
    }

    fun stopLocalProofing() {
        localProofingServer?.stop()
        localProofingServer = null
        localProofingState = null
    }

    fun logLocalProofing(message: String) {
        Log.d("LocalProofing", message)
        DiagnosticLog.append(context, "LocalProofing", message)
    }

    fun startLocalProofing() {
        stopLocalProofing()
        val token = LocalProofingSessionToken.make()
        val router = LocalProofingRequestRouter(
            sessionToken = token,
            photosProvider = {
                currentFiles
                    .filterNot { it.info.isFolder }
                    .map(LocalProofingPhotoMapper::photo)
            },
            previewProvider = { id ->
                val handle = id.toIntOrNull()
                currentFiles.firstOrNull { it.info.handle == handle }?.thumbnail
            },
            logger = ::logLocalProofing,
        )
        val server = LocalProofingServer(router = router, token = token, logger = ::logLocalProofing)
        runCatching {
            logLocalProofing(
                "start requested files=${currentFiles.size} " +
                    "photos=${currentFiles.count { !it.info.isFolder }} " +
                    "previews=${currentFiles.count { !it.info.isFolder && it.thumbnail != null }}"
            )
            val started = server.start()
            localProofingServer = server
            localProofingState = LocalProofingShareUiState(
                url = started.url,
                qrBitmap = LocalProofingQrCode.bitmap(started.url),
                photoCount = currentFiles.count { !it.info.isFolder },
            )
        }.onFailure { error ->
            server.stop()
            logLocalProofing("start failed error=${error.message}")
            localProofingError = error.message ?: "启动现场分享失败"
        }
    }

    DisposableEffect(Unit) {
        onDispose { stopLocalProofing() }
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
            viewModel.resumeGalleryLoadingAfterTransfer(cameraSource)
        }
    }
    LaunchedEffect(cameraSource, browseModeState.mode, browseModeState.highDefinitionDate, files) {
        if (browseModeState.mode == GalleryBrowseMode.HD_PREVIEW) {
            val preferredDate = HighDefinitionPreviewSessionPolicy.preferredActiveDate(
                files = files,
                currentDate = browseModeState.highDefinitionDate,
            )
            if (preferredDate != browseModeState.highDefinitionDate) {
                viewModel.setHighDefinitionPreviewDate(cameraSource, preferredDate)
            } else {
                viewModel.syncHighDefinitionSession(cameraSource)
            }
        }
    }
    LaunchedEffect(cameraSource, thumbnailRequestHandles, isTransferring) {
        if (!isTransferring && browseModeState.mode == GalleryBrowseMode.THUMBNAIL) {
            viewModel.loadVisibleThumbnails(cameraSource, thumbnailRequestHandles)
        }
    }

    if (showsDatePicker) {
        DatePickerDialog(
            days = if (browseModeState.mode == GalleryBrowseMode.HD_PREVIEW && highDefinitionPreviewDateDays.isNotEmpty()) {
                highDefinitionPreviewDateDays
            } else {
                selectableDateDays
            },
            onDismiss = { showsDatePicker = false },
            onSelect = { day ->
                if (browseModeState.mode == GalleryBrowseMode.HD_PREVIEW) {
                    viewModel.setHighDefinitionPreviewDate(cameraSource, day)
                } else {
                    filterState = filterState.copy(date = GalleryDateFilter.SpecificDay(day))
                }
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
    if (showsDownloadFolderSettings) {
        DownloadFolderSettingsDialog(
            settings = downloadFolderSettings,
            cameraDisplayName = cameraSource.displayName,
            sampleCaptureDate = files.firstOrNull { !it.info.isFolder }?.info?.captureDate.orEmpty(),
            onPickCustomFolder = { customFolderPicker.launch(null) },
            onDismiss = { showsDownloadFolderSettings = false },
            onSave = { updated ->
                downloadFolderSettings = updated
                downloadFolderSettingsStore.save(updated)
                showsDownloadFolderSettings = false
            },
        )
    }
    if (showsCacheSettings) {
        CacheSettingsDialog(
            cacheUsageLabel = cacheUsageLabel ?: AppCacheUsagePolicy.format(0),
            selectedLimit = cacheLimitOption,
            onDismiss = { showsCacheSettings = false },
            onSaveLimit = { option ->
                cacheLimitOption = option
                appCacheSettingsStore.saveLimit(option)
                coroutineScope.launch {
                    withContext(Dispatchers.IO) {
                        AppCacheUsagePolicy.trimToLimit(context.cacheDir, option.bytes)
                    }
                    cacheRefreshToken += 1
                }
                showsCacheSettings = false
            },
            onClearCache = {
                coroutineScope.launch {
                    withContext(Dispatchers.IO) {
                        AppCacheUsagePolicy.trimToLimit(context.cacheDir, maxBytes = 0)
                    }
                    cacheRefreshToken += 1
                }
                showsCacheSettings = false
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
                stopLocalProofing()
                onDisconnect()
            },
        )
    }
    localProofingState?.let { state ->
        LocalProofingShareDialog(
            state = state,
            onDismiss = { stopLocalProofing() },
        )
    }
    localProofingError?.let { errorMessage ->
        AlertDialog(
            onDismissRequest = { localProofingError = null },
            confirmButton = {
                TextButton(onClick = { localProofingError = null }) {
                    Text("知道了")
                }
            },
            title = { Text("无法开始分享") },
            text = { Text(errorMessage) },
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
            canChangeTransferMode = canChangeTransferMode,
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
            onPreferenceChanged = onPreferenceChanged,
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
            if (browseModeState.mode == GalleryBrowseMode.THUMBNAIL) {
                val allFilteredSelected = selectedHandles.containsAll(selectableFilteredHandles) &&
                    selectableFilteredHandles.isNotEmpty()
                GalleryDownloadBar(
                    selectedCount = selectedFiles.size,
                    totalCount = selectableFilteredHandles.size,
                    allFilteredSelected = allFilteredSelected,
                    canToggleSelectAll = selectableFilteredHandles.isNotEmpty(),
                    preferCompressedDownloads = preferCompressedDownloads,
                    canDownload = selectedFiles.isNotEmpty(),
                    canChangeTransferMode = canChangeTransferMode,
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
            }
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
                cacheUsageLabel = cacheUsageLabel,
                isLoading = isLoading,
                isTransferring = isTransferring,
                onBack = { showsDisconnectConfirm = true },
                onOpenLocalProofing = { startLocalProofing() },
                onOpenDownloadFolderSettings = { showsDownloadFolderSettings = true },
                onOpenDownloads = onOpenDownloads,
                onClearCacheClick = { showsCacheSettings = true },
            )
            GalleryBrowseModeRow(
                activeMode = browseModeState.mode,
                onModeChange = { mode ->
                    previewFile = null
                    viewModel.setBrowseMode(cameraSource, mode)
                },
            )
            if (browseModeState.mode == GalleryBrowseMode.HD_PREVIEW) {
                Box(Modifier.fillMaxSize()) {
                    HighDefinitionPreviewScreen(
                        items = highDefinitionPreviewItems,
                        isLoading = isLoading,
                        error = error,
                        activeDate = browseModeState.highDefinitionDate,
                        previewImages = previewImages,
                        loadedPreviewHandles = loadedPreviewHandles,
                        loadingPreviewHandles = loadingPreviewHandles,
                        failedPreviewHandles = failedPreviewHandles,
                        downloadStates = downloadStates,
                        preferCompressedDownloads = preferCompressedDownloads,
                        canChangeTransferMode = canChangeTransferMode,
                        canStartDownload = hasPendingQueuedDownloads && !isTransferring,
                        onPickDate = { showsDatePicker = true },
                        onPreferenceChanged = onPreferenceChanged,
                        onVisibleHandlesChanged = { visibleHandles ->
                            viewModel.prioritizeHighDefinitionPreviewVisibleHandles(cameraSource, visibleHandles)
                        },
                        onQueueDownload = { file ->
                            if (GalleryDownloadUiPolicy.canSelect(downloadStates[file.info.handle])) {
                                onQueueDownloadSelected(listOf(file))
                            }
                        },
                        onCancelQueuedDownload = { file ->
                            if (downloadStates[file.info.handle] == TransferState.PENDING) {
                                onCancelQueuedDownloads(listOf(file))
                            }
                        },
                        onQueueDownloadRaw = { file ->
                            if (GalleryDownloadUiPolicy.canSelect(downloadStates[file.info.handle])) {
                                onQueueDownloadSelected(listOf(file))
                            }
                        },
                        onCancelQueuedRawDownload = { file ->
                            if (downloadStates[file.info.handle] == TransferState.PENDING) {
                                onCancelQueuedDownloads(listOf(file))
                            }
                        },
                        onStartDownload = onStartQueuedDownloads,
                    )
                }
            } else {
                GalleryFilterPanel(
                    expanded = filtersExpanded,
                    onExpandedChange = { filtersExpanded = it },
                    state = filterState,
                    stats = filterStats,
                    isLoadingJpg = isLoading,
                    isLoadingHiddenFormats = isLoadingHiddenFormats,
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
                                sections = gallerySections,
                                today = today,
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
                                onToggleDayHours = { day ->
                                    expandedSectionDays = if (day in expandedSectionDays) {
                                        expandedSectionDays - day
                                    } else {
                                        expandedSectionDays + day
                                    }
                                },
                                onToggleDaySelection = { dayFiles ->
                                    val dayHandles = dayFiles
                                        .filter { GalleryDownloadUiPolicy.canSelect(downloadStates[it.info.handle]) }
                                        .map { it.info.handle }
                                        .toSet()
                                    if (dayHandles.isNotEmpty()) {
                                        val nextSelection = if (selectedHandles.containsAll(dayHandles)) {
                                            selectedHandles - dayHandles
                                        } else {
                                            selectedHandles + dayHandles
                                        }
                                        viewModel.selectHandles(nextSelection)
                                    }
                                },
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
}

@Composable
private fun GalleryBrowseModeRow(
    activeMode: GalleryBrowseMode,
    onModeChange: (GalleryBrowseMode) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        GalleryBrowseModeChip(
            label = "缩略图",
            selected = activeMode == GalleryBrowseMode.THUMBNAIL,
            onClick = { onModeChange(GalleryBrowseMode.THUMBNAIL) },
        )
        GalleryBrowseModeChip(
            label = "高清预览",
            selected = activeMode == GalleryBrowseMode.HD_PREVIEW,
            onClick = { onModeChange(GalleryBrowseMode.HD_PREVIEW) },
        )
    }
}

@Composable
private fun GalleryBrowseModeChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val background = if (selected) CamTransferColors.Accent.copy(alpha = 0.18f) else CamTransferColors.Card
    val border = if (selected) CamTransferColors.Accent else CamTransferColors.Hairline
    val textColor = if (selected) CamTransferColors.Ink else CamTransferColors.SecondaryInk
    Surface(
        modifier = Modifier.clip(RoundedCornerShape(16.dp)),
        color = background,
        border = BorderStroke(1.dp, border),
        shape = RoundedCornerShape(16.dp),
        onClick = onClick,
    ) {
        Text(
            text = label,
            color = textColor,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        )
    }
}
