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
private fun ZoomablePreviewImage(
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
