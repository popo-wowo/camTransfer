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
            .padding(horizontal = 16.dp, vertical = 12.dp),
        shape = RoundedCornerShape(30.dp),
        color = CamTransferColors.WarmFill,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
        shadowElevation = 14.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(60.dp)
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SelectAllBox(
                checked = allFilteredSelected,
                enabled = canToggleSelectAll,
                onClick = onToggleSelectAll,
            )
            Spacer(Modifier.width(9.dp))
            Text(
                "已选 $selectedCount / 共 $totalCount 张",
                modifier = Modifier.weight(1f),
                color = CamTransferColors.Ink,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            TransferModeCapsule(
                preferCompressedDownloads = preferCompressedDownloads,
                enabled = canChangeTransferMode,
                onPreferenceChanged = onPreferenceChanged,
            )
            Spacer(Modifier.width(9.dp))
            Button(
                onClick = onDownload,
                enabled = canDownload,
                modifier = Modifier
                    .height(38.dp)
                    .requiredWidth(76.dp),
                shape = RoundedCornerShape(21.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = GalleryActionColor,
                    contentColor = CamTransferColors.Card,
                    disabledContainerColor = CamTransferColors.MutedFill,
                    disabledContentColor = CamTransferColors.SecondaryInk,
                ),
                contentPadding = PaddingValues(horizontal = 0.dp),
                elevation = ButtonDefaults.buttonElevation(defaultElevation = 0.dp, pressedElevation = 0.dp),
            ) {
                Text(
                    "下载",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Bold,
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
    val label = if (preferCompressedDownloads) "压缩" else "原图"
    val backgroundColor = if (preferCompressedDownloads) {
        GalleryActionColor.copy(alpha = 0.10f)
    } else {
        Color(0xFF1A6B5C).copy(alpha = 0.08f)
    }
    val borderColor = if (preferCompressedDownloads) {
        GalleryActionColor.copy(alpha = 0.54f)
    } else {
        Color(0xFF1A6B5C).copy(alpha = 0.32f)
    }
    val textColor = if (preferCompressedDownloads) {
        GalleryActionColor
    } else {
        Color(0xFF1A6B5C)
    }
    Surface(
        modifier = Modifier
            .height(32.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(enabled = enabled) { onPreferenceChanged(!preferCompressedDownloads) },
        shape = RoundedCornerShape(16.dp),
        color = if (enabled) backgroundColor else CamTransferColors.MutedFill,
        border = BorderStroke(1.dp, borderColor),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .background(textColor, CircleShape),
            )
            Text(
                label,
                color = if (enabled) textColor else CamTransferColors.SecondaryInk,
                fontSize = 11.sp,
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
            .size(30.dp)
            .clip(CircleShape)
            .background(
                when {
                    checked -> GalleryActionColor
                    enabled -> GalleryActionColor.copy(alpha = 0.12f)
                    else -> CamTransferColors.MutedFill.copy(alpha = 0.55f)
                }
            )
            .border(
                width = if (enabled) 1.8.dp else 1.5.dp,
                color = when {
                    checked -> GalleryActionColor
                    enabled -> GalleryActionColor.copy(alpha = 0.48f)
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
