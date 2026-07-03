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

private val GalleryActionColor = Color(0xFF177C6D)

@Composable
internal fun GalleryHeader(
    activeDownloadCount: Int,
    isLoading: Boolean,
    isTransferring: Boolean,
    onBack: () -> Unit,
    onOpenLocalProofing: () -> Unit,
    onOpenDownloadFolderSettings: () -> Unit,
    onOpenDownloads: () -> Unit,
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
            GalleryIconButton(
                icon = GalleryHeaderIcon.Back,
                contentDescription = "返回",
                onClick = onBack,
            )
            Spacer(Modifier.weight(1f))
            Text(
                "CAMERA GALLERY",
                color = CamTransferColors.Ink,
                fontSize = 13.sp,
                fontWeight = FontWeight.Black,
            )
            Spacer(Modifier.weight(1f))
            GalleryIconButton(
                icon = GalleryHeaderIcon.Share,
                contentDescription = "现场分享",
                onClick = onOpenLocalProofing,
            )
            Spacer(Modifier.width(8.dp))
            GalleryIconButton(
                icon = GalleryHeaderIcon.Folder,
                contentDescription = "下载文件夹",
                onClick = onOpenDownloadFolderSettings,
            )
            Spacer(Modifier.width(8.dp))
            GalleryIconButton(
                icon = GalleryHeaderIcon.Downloads,
                contentDescription = "下载中心",
                onClick = onOpenDownloads,
            )
        }
        if (isLoading || isTransferring || activeDownloadCount > 0) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = CamTransferColors.Accent,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    when {
                        activeDownloadCount > 0 -> "下载中 $activeDownloadCount"
                        isTransferring -> "正在下载"
                        else -> "正在读取相机照片"
                    },
                    color = CamTransferColors.SecondaryInk,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}

private enum class GalleryHeaderIcon {
    Back,
    Share,
    Folder,
    Downloads,
}

@Composable
private fun GalleryIconButton(
    icon: GalleryHeaderIcon,
    contentDescription: String,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .size(42.dp)
            .clip(CircleShape)
            .semantics { this.contentDescription = contentDescription }
            .clickable(onClick = onClick),
        shape = CircleShape,
        color = CamTransferColors.WarmFill,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
        shadowElevation = 2.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            androidx.compose.foundation.Canvas(
                modifier = Modifier.size(22.dp),
            ) {
                val stroke = Stroke(width = 2.2.dp.toPx(), cap = StrokeCap.Round)
                when (icon) {
                    GalleryHeaderIcon.Back -> {
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.58f, size.height * 0.20f),
                            end = Offset(size.width * 0.28f, size.height * 0.50f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.28f, size.height * 0.50f),
                            end = Offset(size.width * 0.58f, size.height * 0.80f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                    }
                    GalleryHeaderIcon.Share -> {
                        drawCircle(
                            color = CamTransferColors.Ink,
                            radius = size.width * 0.12f,
                            center = Offset(size.width * 0.33f, size.height * 0.62f),
                        )
                        drawCircle(
                            color = CamTransferColors.Ink,
                            radius = size.width * 0.12f,
                            center = Offset(size.width * 0.66f, size.height * 0.32f),
                        )
                        drawCircle(
                            color = CamTransferColors.Ink,
                            radius = size.width * 0.12f,
                            center = Offset(size.width * 0.68f, size.height * 0.72f),
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.42f, size.height * 0.55f),
                            end = Offset(size.width * 0.57f, size.height * 0.40f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.44f, size.height * 0.66f),
                            end = Offset(size.width * 0.57f, size.height * 0.70f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                    }
                    GalleryHeaderIcon.Folder -> {
                        val left = size.width * 0.18f
                        val right = size.width * 0.82f
                        val top = size.height * 0.32f
                        val bottom = size.height * 0.74f
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(left, bottom),
                            end = Offset(right, bottom),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(left, bottom),
                            end = Offset(left, top),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(left, top),
                            end = Offset(size.width * 0.34f, top),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.34f, top),
                            end = Offset(size.width * 0.42f, size.height * 0.22f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.42f, size.height * 0.22f),
                            end = Offset(size.width * 0.54f, size.height * 0.22f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.54f, size.height * 0.22f),
                            end = Offset(size.width * 0.62f, top + size.height * 0.08f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.62f, top + size.height * 0.08f),
                            end = Offset(right, top + size.height * 0.08f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(right, top + size.height * 0.08f),
                            end = Offset(right, bottom),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                    }
                    GalleryHeaderIcon.Downloads -> {
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.50f, size.height * 0.12f),
                            end = Offset(size.width * 0.50f, size.height * 0.54f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.32f, size.height * 0.38f),
                            end = Offset(size.width * 0.50f, size.height * 0.56f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.68f, size.height * 0.38f),
                            end = Offset(size.width * 0.50f, size.height * 0.56f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                        drawArc(
                            color = CamTransferColors.Ink,
                            startAngle = 0f,
                            sweepAngle = 180f,
                            useCenter = false,
                            topLeft = Offset(size.width * 0.20f, size.height * 0.52f),
                            size = Size(size.width * 0.60f, size.height * 0.42f),
                            style = stroke,
                        )
                    }
                }
            }
        }
    }
}
