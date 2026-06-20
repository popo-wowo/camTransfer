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
internal fun Modifier.galleryColumnPinchResize(
    columnCount: Int,
    onColumnCountChange: (Int) -> Unit,
): Modifier = pointerInput(columnCount) {
    fun distance(first: Offset, second: Offset): Float =
        hypot((first.x - second.x).toDouble(), (first.y - second.y).toDouble()).toFloat()

    awaitEachGesture {
        var startDistance: Float? = null
        while (true) {
            val event = awaitPointerEvent()
            val pressed = event.changes.filter { it.pressed }
            if (pressed.isEmpty()) return@awaitEachGesture
            if (pressed.size < 2) continue

            val currentDistance = distance(pressed[0].position, pressed[1].position)
            val baseDistance = startDistance ?: currentDistance.also { startDistance = it }
            if (baseDistance <= 0f) continue

            val target = GalleryColumnLayoutPolicy.targetColumns(
                currentColumns = columnCount,
                pinchScale = currentDistance / baseDistance,
            )
            if (target != columnCount) {
                pressed.forEach { it.consume() }
                onColumnCountChange(target)
                startDistance = currentDistance
                return@awaitEachGesture
            }
            pressed.forEach { it.consume() }
        }
    }
}

@Composable
internal fun Modifier.galleryDragSelection(
    gridState: LazyGridState,
    files: List<CameraFile>,
    selectedHandles: Set<Int>,
    downloadStates: Map<Int, TransferState?>,
    onSelectionChange: (Set<Int>) -> Unit,
): Modifier {
    val currentFiles by rememberUpdatedState(files)
    val currentSelectedHandles by rememberUpdatedState(selectedHandles)
    val currentDownloadStates by rememberUpdatedState(downloadStates)
    val currentOnSelectionChange by rememberUpdatedState(onSelectionChange)

    return pointerInput(gridState) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val startHit = gridState.hitAt(down.position, currentFiles) ?: return@awaitEachGesture
            val startHandle = startHit.handle
            if (!GalleryDownloadUiPolicy.canSelect(currentDownloadStates[startHandle])) return@awaitEachGesture

            val orderedHandles = currentFiles.map { file -> file.info.handle }
            var shouldSelect: Boolean? = null
            var nextSelection = currentSelectedHandles
            var lastEndHandle: Int? = null

            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) break
                if (event.changes.count { it.pressed } > 1) break

                val activeShouldSelect = shouldSelect
                val resolvedShouldSelect = if (activeShouldSelect == null) {
                    val delta = change.position - down.position
                    if (GalleryDragSelectionPolicy.shouldStartDragSelection(
                            deltaX = delta.x,
                            deltaY = delta.y,
                            touchSlop = viewConfiguration.touchSlop,
                            selectionActive = currentSelectedHandles.isNotEmpty(),
                        )
                    ) {
                        GalleryDragSelectionPolicy.shouldSelectForDrag(
                            startHandleSelected = startHandle in currentSelectedHandles,
                        ).also {
                            shouldSelect = it
                            nextSelection = GalleryDragSelectionPolicy.updatedRangeSelection(
                                currentSelection = nextSelection,
                                orderedHandles = orderedHandles,
                                startHandle = startHandle,
                                endHandle = startHandle,
                                downloadStates = currentDownloadStates,
                                shouldSelect = it,
                            )
                            lastEndHandle = startHandle
                            currentOnSelectionChange(nextSelection)
                        }
                    } else {
                        null
                    }
                } else {
                    activeShouldSelect
                }
                if (resolvedShouldSelect != null) {
                    val scrollDelta = GalleryDragSelectionPolicy.autoScrollDelta(
                        pointerY = change.position.y,
                        viewportStart = gridState.layoutInfo.viewportStartOffset.toFloat(),
                        viewportEnd = gridState.layoutInfo.viewportEndOffset.toFloat(),
                        edgeSize = 72.dp.toPx(),
                        maxDelta = 34.dp.toPx(),
                    )
                    if (scrollDelta != 0f) {
                        gridState.dispatchRawDelta(scrollDelta)
                    }
                    val hit = gridState.hitAt(change.position, currentFiles)
                    val handle = hit?.handle
                    if (handle != null && handle != lastEndHandle) {
                        val updatedSelection = GalleryDragSelectionPolicy.updatedRangeSelection(
                            currentSelection = nextSelection,
                            orderedHandles = orderedHandles,
                            startHandle = startHandle,
                            endHandle = handle,
                            downloadStates = currentDownloadStates,
                            shouldSelect = resolvedShouldSelect,
                        )
                        if (updatedSelection != nextSelection) {
                            nextSelection = updatedSelection
                            currentOnSelectionChange(nextSelection)
                        }
                        lastEndHandle = handle
                    }
                    change.consume()
                }
            }
        }
    }
}

private data class GalleryGridHit(
    val handle: Int,
)

private fun LazyGridState.hitAt(position: Offset, files: List<CameraFile>): GalleryGridHit? {
    val item = layoutInfo.visibleItemsInfo.firstOrNull { item ->
        position.x >= item.offset.x &&
            position.x < item.offset.x + item.size.width &&
            position.y >= item.offset.y &&
            position.y < item.offset.y + item.size.height
    } ?: return null
    val handle = files.getOrNull(item.index)?.info?.handle ?: return null
    return GalleryGridHit(handle = handle)
}

