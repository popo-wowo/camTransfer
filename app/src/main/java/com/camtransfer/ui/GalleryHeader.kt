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
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
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

@Composable
internal fun GalleryHeader(
    activeDownloadCount: Int,
    cacheUsageLabel: String?,
    isLoading: Boolean,
    isTransferring: Boolean,
    totalCount: Int,
    filteredCount: Int,
    filterExpanded: Boolean,
    activeMode: GalleryBrowseMode,
    onBack: () -> Unit,
    onToggleFilters: () -> Unit,
    onModeChange: (GalleryBrowseMode) -> Unit,
    onOpenLocalProofing: () -> Unit,
    onOpenDownloadFolderSettings: () -> Unit,
    onOpenDownloads: () -> Unit,
    onClearCacheClick: () -> Unit,
) {
    var toolsExpanded by remember { mutableStateOf(false) }
    val statusText = when {
        activeDownloadCount > 0 -> "下载中 $activeDownloadCount"
        isTransferring -> "正在下载"
        isLoading -> "正在读取相机照片"
        activeMode == GalleryBrowseMode.HD_PREVIEW -> "高清预览"
        filteredCount != totalCount -> "$filteredCount / $totalCount"
        else -> "$totalCount 张"
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, top = 6.dp, end = 16.dp, bottom = 3.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(36.dp),
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
                fontSize = GalleryTypeScale.Level2,
                fontWeight = FontWeight.Black,
                maxLines = 1,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                statusText,
                color = CamTransferColors.SecondaryInk,
                fontSize = GalleryTypeScale.Meta,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.width(34.dp))
        }

        Box(modifier = Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(42.dp)
                    .padding(horizontal = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                GalleryFilterHeaderButton(
                    expanded = filterExpanded,
                    enabled = activeMode == GalleryBrowseMode.THUMBNAIL,
                    onClick = onToggleFilters,
                )
                Spacer(Modifier.weight(1f))
                GalleryBrowseModeSegmentedControl(
                    activeMode = activeMode,
                    onModeChange = onModeChange,
                    compact = true,
                )
                Spacer(Modifier.weight(1f))
                Box {
                    GalleryToolHeaderButton(
                        icon = GalleryHeaderIcon.Menu,
                        label = "工具",
                        onClick = { toolsExpanded = true },
                    )
                    DropdownMenu(
                        expanded = toolsExpanded,
                        onDismissRequest = { toolsExpanded = false },
                        modifier = Modifier
                            .width(184.dp),
                        shape = RoundedCornerShape(22.dp),
                        containerColor = CamTransferColors.WarmFill.copy(alpha = 0.98f),
                        tonalElevation = 0.dp,
                        shadowElevation = 10.dp,
                        border = BorderStroke(0.dp, Color.Transparent),
                    ) {
                        GalleryToolMenuItem(
                            icon = GalleryHeaderIcon.Downloads,
                            label = "下载中心",
                            trailingText = activeDownloadCount.takeIf { it > 0 }?.coerceAtMost(99)?.toString(),
                            onClick = {
                                toolsExpanded = false
                                onOpenDownloads()
                            },
                        )
                        GalleryToolMenuItem(
                            icon = GalleryHeaderIcon.Share,
                            label = "现场分享",
                            onClick = {
                                toolsExpanded = false
                                onOpenLocalProofing()
                            },
                        )
                        GalleryToolMenuItem(
                            icon = GalleryHeaderIcon.Folder,
                            label = "下载文件夹",
                            onClick = {
                                toolsExpanded = false
                                onOpenDownloadFolderSettings()
                            },
                        )
                        GalleryToolMenuItem(
                            icon = GalleryHeaderIcon.Cache,
                            label = cacheUsageLabel ?: "缓存",
                            onClick = {
                                toolsExpanded = false
                                onClearCacheClick()
                            },
                        )
                    }
                }
            }
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(10.dp)
                    .background(
                        Brush.verticalGradient(
                            0f to Color.Transparent,
                            1f to CamTransferColors.Ink.copy(alpha = 0.035f),
                        ),
                    ),
            )
        }

        if (isLoading || isTransferring || activeDownloadCount > 0) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(start = 3.dp),
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(12.dp),
                    strokeWidth = 1.6.dp,
                    color = CamTransferColors.Accent,
                )
                Spacer(Modifier.width(7.dp))
                Text(statusText, color = CamTransferColors.SecondaryInk, fontSize = GalleryTypeScale.Meta)
            }
        }
    }
}

private enum class GalleryHeaderIcon {
    Back,
    Share,
    Folder,
    Downloads,
    Cache,
    Menu,
}

@Composable
private fun GalleryIconButton(
    icon: GalleryHeaderIcon,
    contentDescription: String,
    onClick: () -> Unit,
    badge: String? = null,
) {
    Surface(
        modifier = Modifier
            .size(34.dp)
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
                modifier = Modifier.size(18.dp),
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
                    GalleryHeaderIcon.Cache -> {
                        drawArc(
                            color = CamTransferColors.Ink,
                            startAngle = 30f,
                            sweepAngle = 280f,
                            useCenter = false,
                            topLeft = Offset(size.width * 0.18f, size.height * 0.18f),
                            size = Size(size.width * 0.64f, size.height * 0.64f),
                            style = stroke,
                        )
                        drawLine(
                            color = CamTransferColors.Ink,
                            start = Offset(size.width * 0.72f, size.height * 0.23f),
                            end = Offset(size.width * 0.82f, size.height * 0.12f),
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                    }
                    GalleryHeaderIcon.Menu -> {
                        listOf(0.28f, 0.50f, 0.72f).forEach { y ->
                            drawCircle(
                                color = CamTransferColors.Ink,
                                radius = size.width * 0.07f,
                                center = Offset(size.width * 0.5f, size.height * y),
                            )
                        }
                    }
                }
            }
            if (badge != null) {
                Box(
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .size(15.dp)
                        .clip(CircleShape)
                        .background(GalleryActionColor),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        badge,
                        color = CamTransferColors.Card,
                        fontSize = GalleryTypeScale.Micro,
                        fontWeight = FontWeight.Black,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

@Composable
private fun GalleryFilterHeaderButton(
    expanded: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .height(38.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(enabled = enabled, onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        color = Color.Transparent,
        border = BorderStroke(
            1.dp,
            if (expanded && enabled) CamTransferColors.Accent else Color.Transparent,
        ),
        shadowElevation = 0.dp,
    ) {
        Row(
            modifier = Modifier.padding(start = 11.dp, end = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            androidx.compose.foundation.Canvas(modifier = Modifier.size(15.dp)) {
                val color = if (expanded && enabled) CamTransferColors.Accent else CamTransferColors.Ink.copy(alpha = 0.78f)
                val strokeWidth = 1.45.dp.toPx()
                listOf(0.28f, 0.50f, 0.72f).forEachIndexed { index, y ->
                    val knobX = when (index) {
                        0 -> 0.68f
                        1 -> 0.34f
                        else -> 0.56f
                    }
                    drawLine(
                        color = color,
                        start = Offset(size.width * 0.12f, size.height * y),
                        end = Offset(size.width * 0.88f, size.height * y),
                        strokeWidth = strokeWidth,
                        cap = StrokeCap.Round,
                    )
                    drawCircle(
                        color = color,
                        radius = 1.9.dp.toPx(),
                        center = Offset(size.width * knobX, size.height * y),
                    )
                }
            }
            Text(
                "筛选",
                color = if (expanded && enabled) CamTransferColors.Accent else CamTransferColors.Ink.copy(alpha = 0.78f),
                fontSize = GalleryTypeScale.Level1,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun GalleryToolHeaderButton(
    icon: GalleryHeaderIcon,
    label: String,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .height(38.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        color = Color.Transparent,
        border = BorderStroke(1.dp, Color.Transparent),
        shadowElevation = 0.dp,
    ) {
        Row(
            modifier = Modifier.padding(start = 10.dp, end = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            GalleryHeaderGlyph(icon = icon, color = CamTransferColors.Ink.copy(alpha = 0.78f), glyphSize = 16.dp)
            Text(
                label,
                color = CamTransferColors.Ink.copy(alpha = 0.78f),
                fontSize = GalleryTypeScale.Level1,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun GalleryToolMenuItem(
    icon: GalleryHeaderIcon,
    label: String,
    trailingText: String? = null,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 6.dp, vertical = 2.dp)
            .height(40.dp)
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.30f))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        GalleryMenuGlyph(icon = icon)
        Text(
            label,
            modifier = Modifier.weight(1f),
            color = CamTransferColors.Ink,
            fontSize = GalleryTypeScale.Level2,
            fontWeight = FontWeight.Black,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (trailingText != null) {
            Text(
                trailingText,
                color = CamTransferColors.SecondaryInk,
                fontSize = GalleryTypeScale.Meta,
                fontWeight = FontWeight.Black,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun GalleryHeaderGlyph(
    icon: GalleryHeaderIcon,
    color: Color,
    glyphSize: androidx.compose.ui.unit.Dp,
) {
    androidx.compose.foundation.Canvas(modifier = Modifier.size(glyphSize)) {
        val stroke = Stroke(width = 1.65.dp.toPx(), cap = StrokeCap.Round)
        when (icon) {
            GalleryHeaderIcon.Menu -> {
                val top = listOf(
                    Offset(size.width * 0.50f, size.height * 0.18f),
                    Offset(size.width * 0.22f, size.height * 0.34f),
                    Offset(size.width * 0.50f, size.height * 0.50f),
                    Offset(size.width * 0.78f, size.height * 0.34f),
                )
                fun layer(points: List<Offset>) {
                    for (index in points.indices) {
                        drawLine(
                            color = color,
                            start = points[index],
                            end = points[(index + 1) % points.size],
                            strokeWidth = stroke.width,
                            cap = StrokeCap.Round,
                        )
                    }
                }
                layer(top)
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.25f, size.height * 0.58f),
                    end = Offset(size.width * 0.50f, size.height * 0.72f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.75f, size.height * 0.58f),
                    end = Offset(size.width * 0.50f, size.height * 0.72f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.25f, size.height * 0.76f),
                    end = Offset(size.width * 0.50f, size.height * 0.90f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.75f, size.height * 0.76f),
                    end = Offset(size.width * 0.50f, size.height * 0.90f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
            }
            else -> Unit
        }
    }
}

@Composable
private fun GalleryMenuGlyph(icon: GalleryHeaderIcon) {
    androidx.compose.foundation.Canvas(modifier = Modifier.size(18.dp)) {
        val stroke = Stroke(width = 1.8.dp.toPx(), cap = StrokeCap.Round)
        val color = CamTransferColors.SecondaryInk
        when (icon) {
            GalleryHeaderIcon.Downloads -> {
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.50f, size.height * 0.16f),
                    end = Offset(size.width * 0.50f, size.height * 0.56f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.32f, size.height * 0.40f),
                    end = Offset(size.width * 0.50f, size.height * 0.58f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.68f, size.height * 0.40f),
                    end = Offset(size.width * 0.50f, size.height * 0.58f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                drawArc(
                    color = color,
                    startAngle = 0f,
                    sweepAngle = 180f,
                    useCenter = false,
                    topLeft = Offset(size.width * 0.22f, size.height * 0.54f),
                    size = Size(size.width * 0.56f, size.height * 0.36f),
                    style = stroke,
                )
            }
            GalleryHeaderIcon.Share -> {
                drawCircle(color = color, radius = size.width * 0.10f, center = Offset(size.width * 0.32f, size.height * 0.62f))
                drawCircle(color = color, radius = size.width * 0.10f, center = Offset(size.width * 0.66f, size.height * 0.32f))
                drawCircle(color = color, radius = size.width * 0.10f, center = Offset(size.width * 0.68f, size.height * 0.72f))
                drawLine(color, Offset(size.width * 0.42f, size.height * 0.55f), Offset(size.width * 0.57f, size.height * 0.40f), stroke.width, cap = StrokeCap.Round)
                drawLine(color, Offset(size.width * 0.44f, size.height * 0.66f), Offset(size.width * 0.57f, size.height * 0.70f), stroke.width, cap = StrokeCap.Round)
            }
            GalleryHeaderIcon.Folder -> {
                drawRoundRect(
                    color = color,
                    topLeft = Offset(size.width * 0.16f, size.height * 0.34f),
                    size = Size(size.width * 0.68f, size.height * 0.44f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.8.dp.toPx()),
                    style = stroke,
                )
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.23f, size.height * 0.34f),
                    end = Offset(size.width * 0.38f, size.height * 0.22f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.38f, size.height * 0.22f),
                    end = Offset(size.width * 0.56f, size.height * 0.22f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
            }
            GalleryHeaderIcon.Cache -> {
                drawArc(
                    color = color,
                    startAngle = 35f,
                    sweepAngle = 280f,
                    useCenter = false,
                    topLeft = Offset(size.width * 0.18f, size.height * 0.18f),
                    size = Size(size.width * 0.64f, size.height * 0.64f),
                    style = stroke,
                )
                drawLine(
                    color = color,
                    start = Offset(size.width * 0.72f, size.height * 0.24f),
                    end = Offset(size.width * 0.82f, size.height * 0.13f),
                    strokeWidth = stroke.width,
                    cap = StrokeCap.Round,
                )
            }
            else -> Unit
        }
    }
}
