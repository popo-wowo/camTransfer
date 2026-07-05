package com.camtransfer.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferItem
import com.camtransfer.model.TransferState
import com.camtransfer.service.TransferHistoryPolicy
import com.camtransfer.viewmodel.TransferViewModel
import java.nio.ByteBuffer

@Composable
fun TransferScreen(
    viewModel: TransferViewModel,
    onBack: () -> Unit,
    onClearDownloadCache: () -> Unit,
    onPauseDownloads: () -> Unit,
) {
    val items by viewModel.items.collectAsState()
    val historyItems by viewModel.historyItems.collectAsState()
    val isTransferring by viewModel.isTransferring.collectAsState()
    val visibleItems = remember(historyItems, items) {
        TransferHistoryPolicy.downloadCenterItems(
            historyItems = historyItems,
            queueItems = items,
        )
    }
    val doneCount = visibleItems.count { it.state == TransferState.DONE }
    val activeCount = visibleItems.count {
        it.state == TransferState.PENDING ||
            it.state == TransferState.DOWNLOADING ||
            it.state == TransferState.SAVING
    }
    val canReturnToGallery = !isTransferring && DownloadCenterActionPolicy.canReturnToGallery(activeCount)

    BackHandler {
        if (canReturnToGallery) {
            onBack()
        }
    }

    Scaffold(containerColor = CamTransferColors.Background) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(CamTransferColors.Background),
        ) {
            DownloadHeader(
                totalCount = visibleItems.size,
                doneCount = doneCount,
                activeCount = activeCount,
                isTransferring = isTransferring,
                canReturnToGallery = canReturnToGallery,
                onBack = onBack,
                onClearDownloadCache = onClearDownloadCache,
                onPauseDownloads = onPauseDownloads,
            )
            if (visibleItems.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("下载中心为空", color = CamTransferColors.SecondaryInk)
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(start = 12.dp, top = 8.dp, end = 12.dp, bottom = 24.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(visibleItems, key = { it.file.info.handle }) { item ->
                        DownloadGridItem(item)
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadHeader(
    totalCount: Int,
    doneCount: Int,
    activeCount: Int,
    isTransferring: Boolean,
    canReturnToGallery: Boolean,
    onBack: () -> Unit,
    onClearDownloadCache: () -> Unit,
    onPauseDownloads: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 18.dp, top = 6.dp, end = 18.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            DownloadHeaderIconButton(
                icon = DownloadHeaderIcon.Back,
                contentDescription = "返回",
                enabled = canReturnToGallery,
                onClick = onBack,
            )
            Spacer(Modifier.weight(1f))
            Text(
                "DOWNLOADS",
                color = CamTransferColors.Ink,
                fontSize = 13.sp,
                fontWeight = FontWeight.Black,
            )
            Spacer(Modifier.weight(1f))
            DownloadHeaderTextButton(
                label = DownloadCenterActionPolicy.pauseDownloadsLabel,
                enabled = DownloadCenterActionPolicy.canPauseDownloads(activeCount),
                onClick = onPauseDownloads,
            )
            Spacer(Modifier.size(8.dp))
            DownloadHeaderTextButton(
                label = DownloadCenterActionPolicy.clearDownloadRecordsLabel,
                enabled = DownloadCenterActionPolicy.canClearRecords(totalCount, activeCount),
                onClick = onClearDownloadCache,
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (isTransferring) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = CamTransferColors.Accent,
                )
                Spacer(Modifier.size(8.dp))
            }
            Text(
                "$totalCount 张 · 已保存 $doneCount · 进行中 $activeCount",
                color = CamTransferColors.SecondaryInk,
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

private enum class DownloadHeaderIcon {
    Back,
}

@Composable
private fun DownloadHeaderTextButton(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .height(34.dp)
            .clip(RoundedCornerShape(17.dp))
            .semantics { this.contentDescription = label }
            .clickable(enabled = enabled, onClick = onClick),
        shape = RoundedCornerShape(17.dp),
        color = if (enabled) CamTransferColors.WarmFill else CamTransferColors.MutedFill.copy(alpha = 0.58f),
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
        shadowElevation = if (enabled) 1.dp else 0.dp,
    ) {
        Box(
            modifier = Modifier.padding(horizontal = 12.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                label,
                color = if (enabled) CamTransferColors.Ink else CamTransferColors.SecondaryInk.copy(alpha = 0.46f),
                fontSize = 12.sp,
                fontWeight = FontWeight.Black,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun DownloadHeaderIconButton(
    icon: DownloadHeaderIcon,
    contentDescription: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val iconColor = if (enabled) CamTransferColors.Ink else CamTransferColors.SecondaryInk.copy(alpha = 0.46f)
    Surface(
        modifier = Modifier
            .size(42.dp)
            .clip(CircleShape)
            .semantics { this.contentDescription = contentDescription }
            .clickable(enabled = enabled, onClick = onClick),
        shape = CircleShape,
        color = if (enabled) CamTransferColors.WarmFill else CamTransferColors.MutedFill.copy(alpha = 0.58f),
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
        shadowElevation = if (enabled) 2.dp else 0.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Canvas(modifier = Modifier.size(22.dp)) {
                val stroke = Stroke(width = 2.2.dp.toPx(), cap = StrokeCap.Round)
                when (icon) {
                    DownloadHeaderIcon.Back -> {
                        drawLine(
                            color = iconColor,
                            start = Offset(size.width * 0.58f, size.height * 0.20f),
                            end = Offset(size.width * 0.28f, size.height * 0.50f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = iconColor,
                            start = Offset(size.width * 0.28f, size.height * 0.50f),
                            end = Offset(size.width * 0.58f, size.height * 0.80f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadGridItem(item: TransferItem) {
    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0xFFEDEBE5)),
    ) {
        val thumb = item.file.thumbnail
        if (thumb != null) {
            val bitmap = remember(thumb, item.file.info) { decodeThumbnailBitmapForDisplay(item.file, thumb) }
            if (bitmap != null) {
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = item.file.info.filename,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            }
        }
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.45f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.42f),
                    )
                )
        )
        StatusChip(item.state, Modifier.align(Alignment.TopEnd))
        FormatChip(item.file.info.formatLabel, Modifier.align(Alignment.BottomEnd))
        Column(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .fillMaxWidth()
                .padding(8.dp),
        ) {
            if (item.state == TransferState.DOWNLOADING || item.state == TransferState.SAVING) {
                LinearProgressIndicator(
                    progress = { item.progress.coerceIn(0f, 1f) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(3.dp)
                        .clip(CircleShape),
                    color = Color.White,
                    trackColor = Color.White.copy(alpha = 0.25f),
                )
            }
        }
    }
}

@Composable
private fun FormatChip(label: String, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .padding(7.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(Color.White.copy(alpha = 0.84f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Text(label.uppercase(), color = CamTransferColors.Ink, fontSize = 8.sp, fontWeight = FontWeight.Black)
    }
}

@Composable
private fun StatusChip(state: TransferState, modifier: Modifier = Modifier) {
    val (label, background) = when (state) {
        TransferState.PENDING -> "排队" to CamTransferColors.Ink.copy(alpha = 0.82f)
        TransferState.DOWNLOADING -> "下载中" to CamTransferColors.Ink.copy(alpha = 0.82f)
        TransferState.SAVING -> "保存中" to CamTransferColors.Ink.copy(alpha = 0.82f)
        TransferState.DONE -> "已保存" to CamTransferColors.Ink.copy(alpha = 0.82f)
        TransferState.ERROR -> "失败" to MaterialTheme.colorScheme.error
    }
    Box(
        modifier = modifier
            .padding(7.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(background)
            .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Text(label, color = CamTransferColors.Card, fontSize = 8.sp, fontWeight = FontWeight.Black)
    }
}

private fun decodeThumbnailBitmapForDisplay(file: CameraFile, data: ByteArray): Bitmap? {
    val bitmap = decodeThumbnailBitmap(data) ?: return null
    val rotationDegrees = GalleryThumbnailDisplayPolicy.rotationDegrees(
        file = file,
        decodedWidth = bitmap.width,
        decodedHeight = bitmap.height,
        thumbnail = data,
    )
    return GalleryThumbnailLetterboxCropper.crop(rotateBitmapForDisplay(bitmap, rotationDegrees))
}

private fun decodeThumbnailBitmap(data: ByteArray) =
    decodeThumbnailBitmapLegacy(data)
        ?: if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        runCatching {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val sampleSize = GalleryThumbnailDecodePolicy.sampleSize(
                    width = info.size.width,
                    height = info.size.height,
                )
                if (sampleSize > 1) {
                    decoder.setTargetSampleSize(sampleSize)
                }
            }
        }.getOrNull()
    } else {
        null
    }

private fun decodeThumbnailBitmapLegacy(data: ByteArray): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
    val sampleSize = GalleryThumbnailDecodePolicy.sampleSize(
        width = bounds.outWidth,
        height = bounds.outHeight,
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
