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
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
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
import com.camtransfer.service.AppCacheLimitOption
import com.camtransfer.service.DownloadFolderPathPolicy
import com.camtransfer.service.DownloadFolderSaveMode
import com.camtransfer.service.DownloadFolderSettings
import com.camtransfer.viewmodel.BrowseViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import kotlin.math.hypot

@Composable
internal fun DownloadFolderSettingsDialog(
    settings: DownloadFolderSettings,
    cameraDisplayName: String?,
    sampleCaptureDate: String,
    onPickCustomFolder: () -> Unit,
    onDismiss: () -> Unit,
    onSave: (DownloadFolderSettings) -> Unit,
) {
    var saveMode by remember(settings) { mutableStateOf(settings.saveMode) }
    var rootFolderName by remember(settings) { mutableStateOf(settings.rootFolderName) }
    var includeCameraName by remember(settings) { mutableStateOf(settings.includeCameraName) }
    var includeDateFolder by remember(settings) { mutableStateOf(settings.includeDateFolder) }
    var customTreeUri by remember(settings) { mutableStateOf(settings.customTreeUri) }
    var customTreeLabel by remember(settings) { mutableStateOf(settings.customTreeLabel) }
    val composedSettings = DownloadFolderSettings(
        saveMode = saveMode,
        rootFolderName = rootFolderName,
        includeCameraName = includeCameraName,
        includeDateFolder = includeDateFolder,
        customTreeUri = customTreeUri,
        customTreeLabel = customTreeLabel,
    )
    val previewPath = DownloadFolderPathPolicy.previewRelativePath(
        settings = composedSettings,
        cameraDisplayName = cameraDisplayName,
        sampleCaptureDate = sampleCaptureDate,
    )
    val canSave = when (saveMode) {
        DownloadFolderSaveMode.RULE_MEDIASTORE -> true
        DownloadFolderSaveMode.CUSTOM_TREE -> !customTreeUri.isNullOrBlank()
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                enabled = canSave,
                onClick = {
                    onSave(composedSettings)
                },
            ) {
                Text("保存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
        title = { Text("下载文件夹") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                DownloadFolderModeOptionRow(
                    selected = saveMode == DownloadFolderSaveMode.RULE_MEDIASTORE,
                    title = "相册文件夹",
                    subtitle = "继续写入系统相册，可按相机名和日期自动分层",
                    onClick = { saveMode = DownloadFolderSaveMode.RULE_MEDIASTORE },
                )
                DownloadFolderModeOptionRow(
                    selected = saveMode == DownloadFolderSaveMode.CUSTOM_TREE,
                    title = "选择手机文件夹",
                    subtitle = DownloadFolderPathPolicy.customFolderSummary(
                        DownloadFolderSettings(
                            saveMode = DownloadFolderSaveMode.CUSTOM_TREE,
                            customTreeUri = customTreeUri,
                            customTreeLabel = customTreeLabel,
                        )
                    ),
                    onClick = { saveMode = DownloadFolderSaveMode.CUSTOM_TREE },
                )
                if (DownloadFolderPathPolicy.shouldShowRuleOptions(composedSettings)) {
                    OutlinedTextField(
                        value = rootFolderName,
                        onValueChange = { rootFolderName = it },
                        singleLine = true,
                        label = { Text("根文件夹名") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    DownloadFolderOptionRow(
                        checked = includeCameraName,
                        title = "包含相机名",
                        subtitle = cameraDisplayName?.takeIf { it.isNotBlank() } ?: "当前没有可用相机名时会省略这一层",
                        onCheckedChange = { includeCameraName = it },
                    )
                    DownloadFolderOptionRow(
                        checked = includeDateFolder,
                        title = "包含日期",
                        subtitle = "格式固定为 YYYY-MM-DD",
                        onCheckedChange = { includeDateFolder = it },
                    )
                } else {
                    Button(
                        onClick = onPickCustomFolder,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = CamTransferColors.Ink,
                            contentColor = CamTransferColors.Card,
                        ),
                    ) {
                        Text(if (customTreeUri.isNullOrBlank()) "选择手机文件夹" else "重新选择文件夹")
                    }
                    Text(
                        "自选模式会直接写入你选择的目录，不再自动追加相机名或日期子文件夹。",
                        color = CamTransferColors.SecondaryInk,
                        fontSize = 12.sp,
                    )
                }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        "保存位置预览",
                        color = CamTransferColors.SecondaryInk,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        previewPath,
                        color = CamTransferColors.Ink,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                    )
                }
            }
        },
    )
}

@Composable
internal fun CacheSettingsDialog(
    cacheUsageLabel: String,
    selectedLimit: AppCacheLimitOption,
    onDismiss: () -> Unit,
    onSaveLimit: (AppCacheLimitOption) -> Unit,
    onClearCache: () -> Unit,
) {
    var limitOption by remember(selectedLimit) { mutableStateOf(selectedLimit) }

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = { onSaveLimit(limitOption) }) {
                Text("保存")
            }
        },
        dismissButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(onClick = onClearCache) {
                    Text("清理缓存")
                }
                TextButton(onClick = onDismiss) {
                    Text("取消")
                }
            }
        },
        title = { Text("缓存设置") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    cacheUsageLabel,
                    color = CamTransferColors.SecondaryInk,
                    fontSize = 12.sp,
                )
                AppCacheLimitOption.entries.forEach { option ->
                    DownloadFolderModeOptionRow(
                        selected = limitOption == option,
                        title = option.label,
                        subtitle = "超过上限后自动清理最旧的缩略图缓存和诊断日志",
                        onClick = { limitOption = option },
                    )
                }
                Text(
                    "高清预览只保留在本次浏览会话，退出相册后清理；配对记录和已下载文件不属于缓存。",
                    color = CamTransferColors.SecondaryInk,
                    fontSize = 12.sp,
                )
            }
        },
    )
}

@Composable
private fun DownloadFolderModeOptionRow(
    selected: Boolean,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(12.dp),
        color = if (selected) CamTransferColors.MutedFill else CamTransferColors.Card,
        border = BorderStroke(
            width = 1.dp,
            color = if (selected) CamTransferColors.Ink else CamTransferColors.Hairline,
        ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(18.dp)
                    .clip(CircleShape)
                    .background(if (selected) CamTransferColors.Ink else Color.Transparent)
                    .border(1.5.dp, CamTransferColors.Ink, CircleShape),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    title,
                    color = CamTransferColors.Ink,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    subtitle,
                    color = CamTransferColors.SecondaryInk,
                    fontSize = 12.sp,
                )
            }
        }
    }
}

@Composable
private fun DownloadFolderOptionRow(
    checked: Boolean,
    title: String,
    subtitle: String,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable { onCheckedChange(!checked) }
            .padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(
            checked = checked,
            onCheckedChange = onCheckedChange,
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                title,
                color = CamTransferColors.Ink,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                subtitle,
                color = CamTransferColors.SecondaryInk,
                fontSize = 12.sp,
            )
        }
    }
}

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
    var activeEndpoint by remember(initialRange) { mutableStateOf(GalleryDateRangeEndpoint.Start) }
    val normalizedStart = GalleryDateRangePickerPolicy.normalizedStart(startDay, endDay)
    val normalizedEnd = GalleryDateRangePickerPolicy.normalizedEnd(startDay, endDay)

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
                        activeEndpoint = GalleryDateRangeEndpoint.Start
                    },
                ) { Text("清除") }
                TextButton(onClick = onDismiss) { Text("取消") }
            }
        },
        title = { Text("选择时间范围") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    DateRangeField(
                        label = "开始时间",
                        value = GalleryDateRangePickerPolicy.fieldValue(startDay),
                        selected = activeEndpoint == GalleryDateRangeEndpoint.Start,
                        onClick = { activeEndpoint = GalleryDateRangeEndpoint.Start },
                        modifier = Modifier.weight(1f),
                    )
                    DateRangeField(
                        label = "结束时间",
                        value = GalleryDateRangePickerPolicy.fieldValue(endDay),
                        selected = activeEndpoint == GalleryDateRangeEndpoint.End,
                        onClick = { activeEndpoint = GalleryDateRangeEndpoint.End },
                        modifier = Modifier.weight(1f),
                    )
                }
                LazyColumn(modifier = Modifier.height(280.dp)) {
                    items(days) { day ->
                        val selected = normalizedStart != null &&
                            normalizedEnd != null &&
                            day in normalizedStart..normalizedEnd
                        val isStart = day == startDay
                        val isEnd = day == endDay
                        Text(
                            day.format(DateTimeFormatter.ofPattern("yyyy-MM-dd")),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(8.dp))
                                .background(
                                    when {
                                        isStart || isEnd -> CamTransferColors.Ink.copy(alpha = 0.12f)
                                        selected -> CamTransferColors.MutedFill
                                        else -> Color.Transparent
                                    }
                                )
                                .clickable {
                                    when (activeEndpoint) {
                                        GalleryDateRangeEndpoint.Start -> startDay = day
                                        GalleryDateRangeEndpoint.End -> endDay = day
                                    }
                                    activeEndpoint = GalleryDateRangePickerPolicy.nextEndpointAfterDate(activeEndpoint)
                                }
                                .padding(horizontal = 10.dp, vertical = 14.dp),
                            color = CamTransferColors.Ink,
                            fontWeight = if (isStart || isEnd) FontWeight.Black else FontWeight.SemiBold,
                        )
                    }
                }
            }
        },
    )
}

@Composable
private fun DateRangeField(
    label: String,
    value: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(10.dp),
        color = if (selected) CamTransferColors.MutedFill else CamTransferColors.Card,
        border = BorderStroke(
            width = 1.dp,
            color = if (selected) CamTransferColors.Ink else CamTransferColors.Hairline,
        ),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                label,
                color = CamTransferColors.SecondaryInk,
                style = MaterialTheme.typography.labelSmall,
                maxLines = 1,
            )
            Text(
                value,
                color = CamTransferColors.Ink,
                fontWeight = FontWeight.Black,
                fontSize = 14.sp,
                maxLines = 1,
            )
        }
    }
}

internal object GalleryDatePickerPolicy {
    fun selectableDays(today: LocalDate): List<LocalDate> =
        generateSequence(today) { it.minusDays(1) }
            .take(365 * 5 + 2)
            .toList()
}
