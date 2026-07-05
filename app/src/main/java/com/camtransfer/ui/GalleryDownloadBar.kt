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
internal fun GalleryDownloadBar(
    selectedCount: Int,
    totalCount: Int,
    allFilteredSelected: Boolean,
    canToggleSelectAll: Boolean,
    preferCompressedDownloads: Boolean,
    canDownload: Boolean,
    canChangeTransferMode: Boolean = true,
    onToggleSelectAll: () -> Unit,
    onPreferenceChanged: (Boolean) -> Unit,
    onDownload: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 18.dp, vertical = 12.dp),
        shape = RoundedCornerShape(22.dp),
        color = CamTransferColors.WarmFill.copy(alpha = 0.86f),
        border = BorderStroke(0.dp, Color.Transparent),
        shadowElevation = 10.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(56.dp)
                .padding(start = 10.dp, end = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Row(
                modifier = Modifier.weight(1f),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(9.dp),
            ) {
                SelectAllBox(
                    checked = allFilteredSelected,
                    enabled = canToggleSelectAll,
                    onClick = onToggleSelectAll,
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(
                        if (selectedCount > 0) "已选 $selectedCount 张" else "未选择照片",
                        color = CamTransferColors.Ink,
                        fontWeight = FontWeight.Black,
                        fontSize = GalleryTypeScale.Level2,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        if (selectedCount > 0) "共 $totalCount 张可选" else "选择照片后可下载",
                        color = CamTransferColors.SecondaryInk,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = GalleryTypeScale.Micro,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            TransferModeCapsule(
                preferCompressedDownloads = preferCompressedDownloads,
                enabled = canChangeTransferMode,
                onPreferenceChanged = onPreferenceChanged,
            )
            Box(
                modifier = Modifier
                    .height(40.dp)
                    .requiredWidth(90.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(if (canDownload) CamTransferColors.Ink else CamTransferColors.MutedFill)
                    .clickable(enabled = canDownload, onClick = onDownload),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "下载",
                    fontSize = GalleryTypeScale.Level1,
                    fontWeight = FontWeight.Black,
                    color = if (canDownload) CamTransferColors.Card else CamTransferColors.SecondaryInk,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
internal fun TransferModeCapsule(
    preferCompressedDownloads: Boolean,
    enabled: Boolean,
    onPreferenceChanged: (Boolean) -> Unit,
) {
    Surface(
        modifier = Modifier
            .height(40.dp)
            .clip(RoundedCornerShape(18.dp))
            .clickable(enabled = enabled) { onPreferenceChanged(!preferCompressedDownloads) },
        shape = RoundedCornerShape(18.dp),
        color = CamTransferColors.Ink.copy(alpha = 0.065f),
        border = BorderStroke(0.dp, Color.Transparent),
    ) {
        Row(
            modifier = Modifier.padding(2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(0.dp),
        ) {
            TransferModeSegment(
                label = "原图",
                selected = !preferCompressedDownloads,
                enabled = enabled,
                onClick = { if (preferCompressedDownloads) onPreferenceChanged(false) },
            )
            TransferModeSegment(
                label = "压缩",
                selected = preferCompressedDownloads,
                enabled = enabled,
                onClick = { if (!preferCompressedDownloads) onPreferenceChanged(true) },
            )
        }
    }
}

@Composable
private fun TransferModeSegment(
    label: String,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .height(34.dp)
            .requiredWidth(52.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(enabled = enabled, onClick = onClick),
        shape = RoundedCornerShape(16.dp),
        color = if (selected && enabled) CamTransferColors.Card.copy(alpha = 0.98f) else Color.Transparent,
        border = BorderStroke(
            width = if (selected && enabled) 1.dp else 0.dp,
            color = if (selected && enabled) CamTransferColors.Hairline.copy(alpha = 0.70f) else Color.Transparent,
        ),
        shadowElevation = if (selected && enabled) 3.dp else 0.dp,
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(
                label,
                color = when {
                    selected && enabled -> CamTransferColors.Ink
                    enabled -> CamTransferColors.SecondaryInk
                    else -> CamTransferColors.SecondaryInk.copy(alpha = 0.48f)
                },
                fontSize = GalleryTypeScale.Level2,
                fontWeight = FontWeight.Black,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun SelectAllBox(
    checked: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(
                when {
                    checked -> CamTransferColors.Accent
                    enabled -> CamTransferColors.Accent.copy(alpha = 0.14f)
                    else -> CamTransferColors.MutedFill.copy(alpha = 0.55f)
                }
            )
            .border(
                width = if (enabled) 1.8.dp else 1.5.dp,
                color = when {
                    checked -> CamTransferColors.Accent
                    enabled -> CamTransferColors.Accent.copy(alpha = 0.78f)
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
                fontSize = GalleryTypeScale.Level1,
                fontWeight = FontWeight.Black,
            )
        }
    }
}
