package com.camtransfer.ui

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferState
import com.camtransfer.viewmodel.gallery.HighDefinitionPreviewItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.DateTimeFormatter

@Composable
fun HighDefinitionPreviewScreen(
    items: List<HighDefinitionPreviewItem>,
    isLoading: Boolean,
    error: String?,
    activeDate: LocalDate,
    previewImages: Map<Int, ByteArray>,
    loadedPreviewHandles: Set<Int>,
    loadingPreviewHandles: Set<Int>,
    failedPreviewHandles: Set<Int>,
    downloadStates: Map<Int, TransferState>,
    preferCompressedDownloads: Boolean,
    canChangeTransferMode: Boolean = true,
    canStartDownload: Boolean,
    onPickDate: () -> Unit,
    onPreferenceChanged: (Boolean) -> Unit,
    onVisibleHandlesChanged: (List<Int>) -> Unit,
    onQueueDownload: (CameraFile) -> Unit,
    onCancelQueuedDownload: (CameraFile) -> Unit,
    onQueueDownloadRaw: (CameraFile) -> Unit,
    onCancelQueuedRawDownload: (CameraFile) -> Unit,
    onStartDownload: () -> Unit,
) {
    var fullScreenFile by remember { mutableStateOf<CameraFile?>(null) }
    val listState = rememberLazyListState()
    val dateLabel = remember(activeDate) {
        activeDate.format(DateTimeFormatter.ofPattern("yyyy-MM-dd"))
    }
    val activeHandles = remember(items) { items.map { it.previewFile.info.handle }.toSet() }
    val loadedCount = remember(loadedPreviewHandles, activeHandles) {
        loadedPreviewHandles.count { it in activeHandles }
    }
    val downloadCount = remember(items, downloadStates) {
        items.sumOf { item ->
            listOfNotNull(item.previewFile, item.rawFile).count { file ->
                GalleryDownloadUiPolicy.isQueuedOrActive(downloadStates[file.info.handle])
            }
        }
    }
    val visibleHandles by remember {
        derivedStateOf {
            listState.layoutInfo.visibleItemsInfo
                .sortedBy { it.index }
                .mapNotNull { it.key as? Int }
        }
    }

    LaunchedEffect(visibleHandles) {
        if (visibleHandles.isNotEmpty()) {
            onVisibleHandlesChanged(visibleHandles)
        }
    }

    fullScreenFile?.let { file ->
        val previewImage = previewImages[file.info.handle]
        if (previewImage != null) {
            Dialog(
                onDismissRequest = { fullScreenFile = null },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = Color.Black,
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(12.dp),
                    ) {
                        ZoomablePreviewImage(
                            file = file,
                            previewImage = previewImage,
                            manualRotationDegrees = 0,
                        )
                        Text(
                            text = "×",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .clickable { fullScreenFile = null }
                                .padding(8.dp),
                        )
                    }
                }
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            state = listState,
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            items(
                items = items,
                key = { it.previewFile.info.handle },
            ) { item ->
                val file = item.previewFile
                val handle = file.info.handle
                HighDefinitionPreviewCard(
                    item = item,
                    previewImage = previewImages[handle],
                    isLoading = handle in loadingPreviewHandles,
                    isFailed = handle in failedPreviewHandles,
                    wasLoaded = handle in loadedPreviewHandles,
                    downloadState = downloadStates[handle],
                    rawDownloadState = item.rawFile?.let { rawFile -> downloadStates[rawFile.info.handle] },
                    onOpenFullscreen = {
                        if (previewImages[handle] != null) {
                            fullScreenFile = file
                        }
                    },
                    onQueueDownload = { onQueueDownload(file) },
                    onCancelQueuedDownload = { onCancelQueuedDownload(file) },
                    onDownloadRaw = item.rawFile?.let { rawFile ->
                        { onQueueDownloadRaw(rawFile) }
                    },
                    onCancelQueuedRawDownload = item.rawFile?.let { rawFile ->
                        { onCancelQueuedRawDownload(rawFile) }
                    },
                )
            }
        }

        Row(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (error != null) {
                FloatingLabel(error)
            } else if (isLoading && items.isEmpty()) {
                FloatingLabel("读取中")
            } else if (items.isEmpty()) {
                FloatingLabel("无预览")
            } else {
                FloatingLabel("$loadedCount/${items.size}")
            }
            FloatingChip(label = dateLabel, selected = false, onClick = onPickDate)
        }

        HighDefinitionPreviewBottomBar(
            modifier = Modifier.align(Alignment.BottomCenter),
            downloadCount = downloadCount,
            totalCount = items.size,
            preferCompressedDownloads = preferCompressedDownloads,
            canChangeTransferMode = canChangeTransferMode,
            canStartDownload = canStartDownload,
            onPreferenceChanged = onPreferenceChanged,
            onStartDownload = onStartDownload,
        )
    }
}

@Composable
private fun HighDefinitionPreviewCard(
    item: HighDefinitionPreviewItem,
    previewImage: ByteArray?,
    isLoading: Boolean,
    isFailed: Boolean,
    wasLoaded: Boolean,
    downloadState: TransferState?,
    rawDownloadState: TransferState?,
    onOpenFullscreen: () -> Unit,
    onQueueDownload: () -> Unit,
    onCancelQueuedDownload: () -> Unit,
    onDownloadRaw: (() -> Unit)?,
    onCancelQueuedRawDownload: (() -> Unit)?,
) {
    val file = item.previewFile
    val imageAspectRatio = remember(file.info) {
        highDefinitionPreviewAspectRatio(file)
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(imageAspectRatio)
            .background(Color.Black)
            .clickable(enabled = previewImage != null, onClick = onOpenFullscreen),
        contentAlignment = Alignment.Center,
    ) {
        when {
            previewImage != null -> {
                HighDefinitionPreviewImage(
                    file = file,
                    previewImage = previewImage,
                )
            }
            isLoading -> {
                CircularProgressIndicator(
                    modifier = Modifier.size(28.dp),
                    strokeWidth = 2.dp,
                    color = Color.White,
                )
            }
            isFailed -> {
                Text(
                    "预览失败",
                    color = Color.White.copy(alpha = 0.78f),
                    fontWeight = FontWeight.Bold,
                )
            }
            else -> {
                Text(
                    if (wasLoaded) "已加载" else "等待预览",
                    color = Color.White.copy(alpha = 0.72f),
                    fontWeight = FontWeight.Bold,
                )
            }
        }

        val hasPreviewImage = previewImage != null
        val canDownloadPreview = GalleryDownloadUiPolicy.canDownloadFromHighDefinitionPreview(
            hasPreviewImage = hasPreviewImage,
            state = downloadState,
        )
        val canDownloadRaw = GalleryDownloadUiPolicy.canDownloadFromHighDefinitionPreview(
            hasPreviewImage = hasPreviewImage,
            state = rawDownloadState,
        )
        Row(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            onDownloadRaw?.let { downloadRaw ->
                HdQueueButton(
                    label = hdRawDownloadLabel(hasPreviewImage, rawDownloadState),
                    enabled = canDownloadRaw,
                    queued = rawDownloadState == TransferState.PENDING,
                    onClick = if (rawDownloadState == TransferState.PENDING) {
                        onCancelQueuedRawDownload ?: downloadRaw
                    } else {
                        downloadRaw
                    },
                )
            }
            HdQueueButton(
                label = hdPreviewDownloadLabel(hasPreviewImage, downloadState),
                enabled = canDownloadPreview,
                queued = downloadState == TransferState.PENDING,
                onClick = if (downloadState == TransferState.PENDING) onCancelQueuedDownload else onQueueDownload,
            )
        }
    }
}

@Composable
private fun HdQueueButton(
    label: String,
    enabled: Boolean,
    queued: Boolean,
    onClick: () -> Unit,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(
            containerColor = if (queued) CamTransferColors.Accent.copy(alpha = 0.72f) else CamTransferColors.Accent,
            contentColor = Color.White,
            disabledContainerColor = CamTransferColors.MutedFill,
            disabledContentColor = CamTransferColors.SecondaryInk,
        ),
    ) {
        Text(label, fontWeight = FontWeight.Bold)
    }
}

private fun hdPreviewDownloadLabel(
    hasPreviewImage: Boolean,
    state: TransferState?,
): String =
    if (!hasPreviewImage) {
        "加载后加入"
    } else {
        when (state) {
            null -> "加入"
            TransferState.ERROR -> "重试加入"
            TransferState.PENDING -> "已加入"
            else -> GalleryPreviewActionBarPolicy.downloadLabel(state)
        }
    }

private fun hdRawDownloadLabel(
    hasPreviewImage: Boolean,
    state: TransferState?,
): String =
    if (!hasPreviewImage) {
        "加载后 RAW"
    } else {
        when (state) {
            null -> "加入 RAW"
            TransferState.ERROR -> "重试 RAW"
            TransferState.PENDING -> "RAW 已加入"
            else -> GalleryPreviewActionBarPolicy.downloadLabel(state)
        }
    }

@Composable
private fun HighDefinitionPreviewBottomBar(
    modifier: Modifier = Modifier,
    downloadCount: Int,
    totalCount: Int,
    preferCompressedDownloads: Boolean,
    canChangeTransferMode: Boolean,
    canStartDownload: Boolean,
    onPreferenceChanged: (Boolean) -> Unit,
    onStartDownload: () -> Unit,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 12.dp),
        shape = RoundedCornerShape(30.dp),
        color = CamTransferColors.WarmFill,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
        shadowElevation = 14.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(58.dp)
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            HdDownloadCountDot(
                checked = downloadCount > 0,
            )
            Spacer(Modifier.width(9.dp))
            Text(
                "已加入 $downloadCount / 共 $totalCount 张",
                modifier = Modifier.weight(1f),
                color = CamTransferColors.Ink,
                fontWeight = FontWeight.SemiBold,
            )
            TransferModeCapsule(
                preferCompressedDownloads = preferCompressedDownloads,
                enabled = canChangeTransferMode,
                onPreferenceChanged = onPreferenceChanged,
            )
            Spacer(Modifier.width(9.dp))
            Button(
                onClick = onStartDownload,
                enabled = canStartDownload,
                colors = ButtonDefaults.buttonColors(
                    containerColor = CamTransferColors.Accent,
                    contentColor = Color.White,
                    disabledContainerColor = CamTransferColors.MutedFill,
                    disabledContentColor = CamTransferColors.SecondaryInk,
                ),
            ) {
                Text("下载", fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun HdDownloadCountDot(checked: Boolean) {
    Box(
        modifier = Modifier
            .size(30.dp)
            .background(
                if (checked) CamTransferColors.Accent else CamTransferColors.MutedFill.copy(alpha = 0.55f),
                CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            if (checked) "✓" else "",
            color = Color.White,
            fontWeight = FontWeight.Black,
        )
    }
}

@Composable
private fun HighDefinitionPreviewImage(
    file: CameraFile,
    previewImage: ByteArray,
) {
    val displayBitmap by produceState<Bitmap?>(
        initialValue = null,
        file.info,
        previewImage,
    ) {
        value = withContext(Dispatchers.Default) {
            val decoded = decodeThumbnailBitmap(
                data = previewImage,
                maxDecodedSide = GalleryPreviewImagePolicy.FULL_IMAGE_MAX_DECODED_SIDE,
            ) ?: return@withContext null
            val rotationDegrees = GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = file,
                decodedWidth = decoded.width,
                decodedHeight = decoded.height,
                imageData = previewImage,
            )
            rotateGalleryBitmapForDisplay(decoded, rotationDegrees)
        }
    }
    val currentBitmap = displayBitmap
    if (currentBitmap != null) {
        Image(
            bitmap = currentBitmap.asImageBitmap(),
            contentDescription = file.info.filename,
            modifier = Modifier.fillMaxSize(),
            contentScale = ContentScale.Fit,
        )
    } else {
        Text(
            file.info.formatLabel,
            color = Color.White.copy(alpha = 0.55f),
            fontWeight = FontWeight.Bold,
        )
    }
}

private fun highDefinitionPreviewAspectRatio(
    file: CameraFile,
): Float {
    val width = file.info.imagePixWidth
    val height = file.info.imagePixHeight
    if (width > 0 && height > 0) return (width.toFloat() / height.toFloat()).coerceIn(0.45f, 2.4f)
    return 1.5f
}

@Composable
private fun FloatingChip(label: String, selected: Boolean, onClick: () -> Unit) {
    val background = if (selected) CamTransferColors.Accent.copy(alpha = 0.18f) else CamTransferColors.Card
    val border = if (selected) CamTransferColors.Accent else CamTransferColors.Hairline
    val textColor = if (selected) CamTransferColors.Ink else CamTransferColors.SecondaryInk
    Surface(
        modifier = Modifier.clickable(onClick = onClick),
        color = background,
        border = BorderStroke(1.dp, border),
        shape = RoundedCornerShape(14.dp),
    ) {
        Text(
            text = label,
            color = textColor,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 9.dp),
        )
    }
}

@Composable
private fun FloatingLabel(label: String) {
    Surface(
        color = Color.Black.copy(alpha = 0.48f),
        shape = RoundedCornerShape(14.dp),
    ) {
        Text(
            text = label,
            color = Color.White,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
        )
    }
}
