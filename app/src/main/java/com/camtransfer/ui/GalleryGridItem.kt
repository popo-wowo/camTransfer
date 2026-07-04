package com.camtransfer.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.graphics.Shadow
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
internal fun GalleryGridItem(
    file: CameraFile,
    thumbnail: ByteArray?,
    decodedThumbnailCache: GalleryDecodedThumbnailCache<Bitmap>,
    modifier: Modifier = Modifier,
    isSelected: Boolean,
    downloadState: TransferState?,
    onOpen: () -> Unit,
    onToggleSelection: () -> Unit,
) {
    Box(
        modifier = modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(18.dp))
            .background(Color(0xFFEDEBE5))
            .clickable { onOpen() }
    ) {
        val thumb = thumbnail
        if (thumb != null) {
            val cacheKey = GalleryDecodedThumbnailCache.key(
                file = file,
                thumbnailSize = thumb.size,
                maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
            )
            val bitmap by produceState<Bitmap?>(
                initialValue = decodedThumbnailCache.get(cacheKey),
                cacheKey,
                thumb,
                decodedThumbnailCache,
            ) {
                if (value == null) {
                    value = withContext(Dispatchers.Default) {
                        decodeThumbnailBitmapForDisplay(
                            file = file,
                            data = thumb,
                            maxDecodedSide = GalleryThumbnailDecodePolicy.GRID_MAX_DECODED_SIDE,
                        )?.also { decoded ->
                            decodedThumbnailCache.put(cacheKey, decoded)
                        }
                    }
                }
            }
            val currentBitmap = bitmap
            if (currentBitmap != null) {
                Image(
                    bitmap = currentBitmap.asImageBitmap(),
                    contentDescription = file.info.filename,
                    modifier = Modifier.fillMaxSize(),
                    contentScale = ContentScale.Crop,
                )
            } else {
                PlaceholderBox(file)
            }
        } else {
            PlaceholderBox(file)
        }

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.55f to Color.Transparent,
                        1f to Color.Black.copy(alpha = if (isSelected) 0.22f else 0.16f),
                    )
                )
        )

        if (GalleryDownloadUiPolicy.canSelect(downloadState)) {
            SelectionDot(
                isSelected = isSelected,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .clickable { onToggleSelection() },
            )
        }

        GalleryTileBadgePolicy.formatLabel(file)?.let { label ->
            FormatLetters(
                label = label,
                modifier = Modifier.align(Alignment.BottomEnd),
            )
        }

        DownloadStateBadge(downloadState, modifier = Modifier.align(Alignment.TopEnd))
    }
}

@Composable
private fun SelectionDot(isSelected: Boolean, modifier: Modifier = Modifier) {
    val selectionScale by animateFloatAsState(
        targetValue = if (isSelected) 1f else 0.92f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMediumLow,
        ),
        label = "gallerySelectionScale",
    )
    Box(
        modifier = modifier
            .padding(7.dp)
            .size(26.dp)
            .graphicsLayer {
                scaleX = selectionScale
                scaleY = selectionScale
            }
            .clip(CircleShape)
            .background(
                if (isSelected) {
                    GalleryActionColor
                } else {
                    Color.White.copy(alpha = 0.82f)
                }
            )
            .border(
                width = 1.5.dp,
                color = Color.White.copy(alpha = 0.78f),
                shape = CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (isSelected) {
            Text("✓", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Black)
        }
    }
}

@Composable
private fun DownloadStateBadge(state: TransferState?, modifier: Modifier = Modifier) {
    when (GalleryTileBadgePolicy.downloadBadge(state)) {
        GalleryTileDownloadBadge.PendingText -> SmallBadge("排队", modifier)
        GalleryTileDownloadBadge.Progress -> {
            Box(
                modifier = modifier
                    .padding(7.dp)
                    .size(22.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.42f)),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(12.dp),
                    strokeWidth = 1.7.dp,
                    color = Color.White,
                )
            }
        }
        GalleryTileDownloadBadge.DownloadedIcon -> DownloadedIconBadge(modifier)
        GalleryTileDownloadBadge.ErrorText -> SmallBadge("失败", modifier, background = MaterialTheme.colorScheme.error)
        null -> Unit
    }
}

@Composable
private fun FormatLetters(label: String, modifier: Modifier = Modifier) {
    Text(
        text = label,
        modifier = modifier.padding(end = 5.dp, bottom = 4.dp),
        color = Color.White.copy(alpha = 0.9f),
        fontSize = 7.sp,
        fontWeight = FontWeight.Black,
        maxLines = 1,
        style = TextStyle(
            shadow = Shadow(
                color = Color.Black.copy(alpha = 0.72f),
                offset = Offset(0f, 1f),
                blurRadius = 2f,
            )
        ),
    )
}

@Composable
private fun DownloadedIconBadge(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .padding(7.dp)
            .size(18.dp)
            .semantics { contentDescription = "已下载" }
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.42f)),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.size(10.dp)) {
            val stroke = 1.4.dp.toPx()
            drawLine(
                color = Color.White,
                start = Offset(size.width * 0.5f, size.height * 0.12f),
                end = Offset(size.width * 0.5f, size.height * 0.64f),
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
            drawLine(
                color = Color.White,
                start = Offset(size.width * 0.22f, size.height * 0.42f),
                end = Offset(size.width * 0.5f, size.height * 0.7f),
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
            drawLine(
                color = Color.White,
                start = Offset(size.width * 0.78f, size.height * 0.42f),
                end = Offset(size.width * 0.5f, size.height * 0.7f),
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
            drawLine(
                color = Color.White,
                start = Offset(size.width * 0.22f, size.height * 0.88f),
                end = Offset(size.width * 0.78f, size.height * 0.88f),
                strokeWidth = stroke,
                cap = StrokeCap.Round,
            )
        }
    }
}

@Composable
private fun SmallBadge(
    label: String,
    modifier: Modifier = Modifier,
    background: Color = CamTransferColors.Ink.copy(alpha = 0.82f),
    foreground: Color = CamTransferColors.Card,
    fontSize: androidx.compose.ui.unit.TextUnit = 8.sp,
) {
    Box(
        modifier = modifier
            .padding(6.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(background)
            .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Text(label, color = foreground, fontSize = fontSize, fontWeight = FontWeight.Black)
    }
}


@Composable
private fun PlaceholderBox(file: CameraFile) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xFFEDEBE5))
    )
}
