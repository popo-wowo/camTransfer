package com.camtransfer.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.camtransfer.model.TransferItem
import com.camtransfer.model.TransferState
import com.camtransfer.viewmodel.TransferViewModel
import java.nio.ByteBuffer

@Composable
fun TransferScreen(
    viewModel: TransferViewModel,
    onBack: () -> Unit,
    onClearDownloadCache: () -> Unit,
) {
    val items by viewModel.items.collectAsState()
    val isTransferring by viewModel.isTransferring.collectAsState()
    val doneCount = items.count { it.state == TransferState.DONE }
    val activeCount = items.count {
        it.state == TransferState.PENDING ||
            it.state == TransferState.DOWNLOADING ||
            it.state == TransferState.SAVING
    }

    Scaffold(containerColor = CamTransferColors.Background) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(CamTransferColors.Background)
                .statusBarsPadding(),
        ) {
            DownloadHeader(
                totalCount = items.size,
                doneCount = doneCount,
                activeCount = activeCount,
                isTransferring = isTransferring,
                onBack = onBack,
                onClearCompleted = { viewModel.clearCompleted() },
                onClearDownloadCache = onClearDownloadCache,
            )
            if (items.isEmpty()) {
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
                    items(items, key = { it.file.info.handle }) { item ->
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
    onBack: () -> Unit,
    onClearCompleted: () -> Unit,
    onClearDownloadCache: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 22.dp, top = 12.dp, end = 18.dp, bottom = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("返回") }
            Spacer(Modifier.weight(1f))
            if (doneCount > 0 && !isTransferring) {
                TextButton(
                    onClick = onClearCompleted,
                    colors = ButtonDefaults.textButtonColors(contentColor = CamTransferColors.Ink),
                ) {
                    Text("清除已完成")
                }
            }
            if (!isTransferring) {
                TextButton(
                    onClick = onClearDownloadCache,
                    colors = ButtonDefaults.textButtonColors(contentColor = CamTransferColors.Ink),
                ) {
                    Text("清缓存")
                }
            }
        }
        Text(
            "DOWNLOADS",
            color = CamTransferColors.Accent,
            fontSize = 10.sp,
            fontWeight = FontWeight.Black,
            letterSpacing = 2.2.sp,
        )
        Spacer(Modifier.height(6.dp))
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
            val bitmap = remember(thumb) { decodeThumbnailBitmap(thumb) }
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

private fun decodeThumbnailBitmap(data: ByteArray) =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        runCatching {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) { decoder, info, _ ->
                val sampleSize = GalleryThumbnailDecodePolicy.sampleSize(
                    width = info.size.width,
                    height = info.size.height,
                )
                if (sampleSize > 1) {
                    decoder.setTargetSampleSize(sampleSize)
                }
            }
        }.getOrNull() ?: decodeThumbnailBitmapLegacy(data)
    } else {
        decodeThumbnailBitmapLegacy(data)
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
