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

private val PreviewActionColor = Color(0xFF177C6D)

@Composable
internal fun PhotoPreviewDialog(
    files: List<CameraFile>,
    initialIndex: Int,
    downloadStates: Map<Int, TransferState>,
    selectedHandles: Set<Int>,
    previewImages: Map<Int, ByteArray>,
    preferCompressedDownloads: Boolean,
    onDismiss: () -> Unit,
    onPreviewVisible: (List<Int>) -> Unit,
    onPreviewImageVisible: (CameraFile) -> Unit,
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
    LaunchedEffect(currentFile.info.handle) {
        onPreviewImageVisible(currentFile)
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
                    previewImage = previewImages[pageFile.info.handle],
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
private fun PreviewActionBar(
    file: CameraFile,
    downloadState: TransferState?,
    isSelected: Boolean,
    canDownload: Boolean,
    hasHighDefinitionPreview: Boolean,
    isLoadingHighDefinitionPreview: Boolean,
    preferCompressedDownloads: Boolean,
    canChangeTransferMode: Boolean,
    onRequestHighDefinitionPreview: () -> Unit,
    onToggleSelection: () -> Unit,
    onPreferenceChanged: (Boolean) -> Unit,
    onDownload: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(start = 18.dp, top = 14.dp, end = 18.dp, bottom = 108.dp),
        shape = RoundedCornerShape(30.dp),
        color = CamTransferColors.WarmFill.copy(alpha = 0.86f),
        border = BorderStroke(1.dp, CamTransferColors.Hairline.copy(alpha = 0.62f)),
        shadowElevation = 8.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(58.dp)
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            PreviewSelectionBox(
                checked = isSelected,
                enabled = canDownload,
                onClick = onToggleSelection,
            )
            Spacer(Modifier.width(10.dp))
            TransferModeCapsule(
                preferCompressedDownloads = preferCompressedDownloads,
                enabled = canChangeTransferMode,
                onPreferenceChanged = onPreferenceChanged,
            )
            Spacer(Modifier.width(10.dp))
            HighDefinitionPreviewCapsule(
                visible = GalleryPreviewActionBarPolicy.canRequestHighDefinitionPreview(file),
                hasHighDefinitionPreview = hasHighDefinitionPreview,
                isLoadingHighDefinitionPreview = isLoadingHighDefinitionPreview,
                onClick = onRequestHighDefinitionPreview,
            )
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(10.dp))
            Button(
                onClick = onDownload,
                enabled = canDownload,
                modifier = Modifier
                    .height(38.dp)
                    .requiredWidth(88.dp),
                shape = RoundedCornerShape(21.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PreviewActionColor,
                    contentColor = CamTransferColors.Card,
                    disabledContainerColor = CamTransferColors.MutedFill,
                    disabledContentColor = CamTransferColors.SecondaryInk,
                ),
                contentPadding = PaddingValues(horizontal = 0.dp),
                elevation = ButtonDefaults.buttonElevation(defaultElevation = 0.dp, pressedElevation = 0.dp),
            ) {
                Text(
                    GalleryPreviewActionBarPolicy.downloadLabel(downloadState),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun HighDefinitionPreviewCapsule(
    visible: Boolean,
    hasHighDefinitionPreview: Boolean,
    isLoadingHighDefinitionPreview: Boolean,
    onClick: () -> Unit,
) {
    if (!visible) return

    val label = GalleryPreviewActionBarPolicy.highDefinitionPreviewLabel(
        hasPreview = hasHighDefinitionPreview,
        isLoading = isLoadingHighDefinitionPreview,
    )
    val enabled = !hasHighDefinitionPreview && !isLoadingHighDefinitionPreview
    Surface(
        modifier = Modifier
            .height(32.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(enabled = enabled, onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        color = if (hasHighDefinitionPreview) {
            PreviewActionColor.copy(alpha = 0.12f)
        } else {
            Color.White.copy(alpha = 0.08f)
        },
        border = BorderStroke(
            1.dp,
            if (hasHighDefinitionPreview) PreviewActionColor.copy(alpha = 0.54f) else Color.White.copy(alpha = 0.26f),
        ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (isLoadingHighDefinitionPreview) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    strokeWidth = 1.6.dp,
                    color = Color.White.copy(alpha = 0.85f),
                )
            } else {
                Text(
                    if (hasHighDefinitionPreview) "HD" else "预",
                    color = if (hasHighDefinitionPreview) PreviewActionColor else Color.White.copy(alpha = 0.85f),
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                )
            }
            Text(
                label,
                color = if (hasHighDefinitionPreview) PreviewActionColor else Color.White.copy(alpha = if (enabled) 0.92f else 0.56f),
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun PreviewSelectionBox(
    checked: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(32.dp)
            .clip(CircleShape)
            .background(
                when {
                    checked -> PreviewActionColor
                    enabled -> PreviewActionColor.copy(alpha = 0.12f)
                    else -> CamTransferColors.MutedFill.copy(alpha = 0.55f)
                }
            )
            .border(
                width = if (enabled) 1.8.dp else 1.5.dp,
                color = when {
                    checked -> PreviewActionColor
                    enabled -> PreviewActionColor.copy(alpha = 0.48f)
                    else -> CamTransferColors.Hairline.copy(alpha = 0.55f)
                },
                shape = CircleShape,
            )
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (checked) {
            Text(
                "✓",
                color = CamTransferColors.Card,
                fontSize = 18.sp,
                fontWeight = FontWeight.Black,
            )
        }
    }
}

@Composable
private fun PreviewFileInfoButton(
    onClick: () -> Unit,
) {
    PreviewTopBarCircleButton(
        label = "!",
        contentDescription = "图片信息",
        size = 30.dp,
        onClick = onClick,
    )
}

@Composable
private fun PreviewTopBarCircleButton(
    label: String,
    contentDescription: String,
    size: androidx.compose.ui.unit.Dp,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .size(size)
            .clickable { onClick() }
            .semantics { this.contentDescription = contentDescription },
        shape = CircleShape,
        color = Color.White.copy(alpha = 0.12f),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.46f)),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(
                label,
                color = Color.White,
                fontSize = if (size <= 30.dp) 15.sp else 18.sp,
                fontWeight = FontWeight.Black,
            )
        }
    }
}

@Composable
private fun PreviewFileInfoDialog(
    file: CameraFile,
    onDismiss: () -> Unit,
) {
    val rows = remember(file.info) { GalleryPreviewFileInfoPolicy.rows(file) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                file.info.filename,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        text = {
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(rows) { row ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            row.label,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontSize = 13.sp,
                            modifier = Modifier.weight(0.38f),
                        )
                        Text(
                            row.value,
                            color = MaterialTheme.colorScheme.onSurface,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(0.62f),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("关闭")
            }
        },
    )
}

@Composable
internal fun ZoomablePreviewImage(
    file: CameraFile,
    previewImage: ByteArray?,
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
    val displayBytes = remember(previewImage, thumb) {
        GalleryPreviewImagePolicy.displayBytes(previewImage = previewImage, thumbnail = thumb)
    }
    val maxDecodedSide = remember(previewImage) {
        if (previewImage != null) {
            GalleryPreviewImagePolicy.FULL_IMAGE_MAX_DECODED_SIDE
        } else {
            GalleryThumbnailDecodePolicy.PREVIEW_MAX_DECODED_SIDE
        }
    }
    val bitmap = remember(displayBytes, maxDecodedSide) {
        displayBytes?.let {
            decodeThumbnailBitmap(
                data = it,
                maxDecodedSide = maxDecodedSide,
            )
        }
    }
    val autoRotationDegrees = remember(file.info, displayBytes, bitmap) {
        if (bitmap == null) {
            0
        } else {
            GalleryPreviewRotationPolicy.autoRotationDegrees(
                file = file,
                decodedWidth = bitmap.width,
                decodedHeight = bitmap.height,
                imageData = displayBytes,
            )
        }
    }
    val displayRotationDegrees = remember(autoRotationDegrees, manualRotationDegrees) {
        (autoRotationDegrees + manualRotationDegrees) % 360
    }
    val displayBitmap = remember(bitmap, displayRotationDegrees) {
        bitmap?.let { rotateGalleryBitmapForDisplay(it, displayRotationDegrees) }
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
