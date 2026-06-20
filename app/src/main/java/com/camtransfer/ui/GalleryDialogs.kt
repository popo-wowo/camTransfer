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
internal fun DisconnectConfirmDialog(
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(GalleryDisconnectPolicy.confirmTitle) },
        text = { Text(GalleryDisconnectPolicy.confirmMessage) },
        confirmButton = {
            Button(
                onClick = onConfirm,
                colors = ButtonDefaults.buttonColors(
                    containerColor = CamTransferColors.Ink,
                    contentColor = CamTransferColors.Card,
                ),
            ) {
                Text("确认断开")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("继续停留")
            }
        },
    )
}


@Composable
internal fun DatePickerDialog(
    days: List<LocalDate>,
    onDismiss: () -> Unit,
    onSelect: (LocalDate) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
        title = { Text("选择日期") },
        text = {
            LazyColumn(modifier = Modifier.height(280.dp)) {
                items(days) { day ->
                    Text(
                        day.format(DateTimeFormatter.ofPattern("yyyy-MM-dd")),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onSelect(day) }
                            .padding(vertical = 14.dp),
                        color = CamTransferColors.Ink,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        },
    )
}

@Composable
internal fun DateRangePickerDialog(
    days: List<LocalDate>,
    initialRange: GalleryDateFilter.Range?,
    onDismiss: () -> Unit,
    onSelect: (LocalDate, LocalDate) -> Unit,
) {
    var startDay by remember(initialRange) { mutableStateOf(initialRange?.start) }
    var endDay by remember(initialRange) { mutableStateOf(initialRange?.end) }
    val normalizedStart = startDay?.let { start -> endDay?.let { minOf(start, it) } ?: start }
    val normalizedEnd = startDay?.let { start -> endDay?.let { maxOf(start, it) } ?: start }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                enabled = startDay != null,
                onClick = {
                    val start = startDay ?: return@TextButton
                    onSelect(start, endDay ?: start)
                },
            ) {
                Text("确定")
            }
        },
        dismissButton = {
            Row {
                TextButton(
                    onClick = {
                        startDay = null
                        endDay = null
                    },
                ) { Text("清除") }
                TextButton(onClick = onDismiss) { Text("取消") }
            }
        },
        title = { Text("选择时间范围") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    when {
                        startDay == null -> "先选开始日期"
                        endDay == null -> "再选结束日期；只选一天也可以确定"
                        else -> "已选 ${rangeLabel(startDay!!, endDay!!)}"
                    },
                    color = CamTransferColors.SecondaryInk,
                    style = MaterialTheme.typography.bodySmall,
                )
                LazyColumn(modifier = Modifier.height(280.dp)) {
                    items(days) { day ->
                        val selected = normalizedStart != null &&
                            normalizedEnd != null &&
                            day in normalizedStart..normalizedEnd
                        Text(
                            day.format(DateTimeFormatter.ofPattern("yyyy-MM-dd")),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .background(if (selected) CamTransferColors.MutedFill else Color.Transparent)
                                .clickable {
                                    if (startDay == null || endDay != null) {
                                        startDay = day
                                        endDay = null
                                    } else {
                                        endDay = day
                                    }
                                }
                                .padding(horizontal = 10.dp, vertical = 14.dp),
                            color = CamTransferColors.Ink,
                            fontWeight = if (selected) FontWeight.Black else FontWeight.SemiBold,
                        )
                    }
                }
            }
        },
    )
}

internal object GalleryDatePickerPolicy {
    fun selectableDays(today: LocalDate): List<LocalDate> =
        generateSequence(today) { it.minusDays(1) }
            .take(365 * 5 + 2)
            .toList()
}

