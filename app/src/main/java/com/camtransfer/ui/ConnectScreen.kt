package com.camtransfer.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.camtransfer.service.CameraPairingGuidance
import com.camtransfer.viewmodel.ConnectionState
import com.camtransfer.viewmodel.ConnectionViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectScreen(
    viewModel: ConnectionViewModel,
    onConnected: () -> Unit,
    onOpenWiredImport: () -> Unit,
    onShareDiagnosticLog: () -> Unit,
    onShowDisclaimer: () -> Unit,
) {
    val state by viewModel.state.collectAsState()
    val statusText by viewModel.statusText.collectAsState()
    val error by viewModel.error.collectAsState()
    val preferCompressedDownloads by viewModel.preferCompressedDownloads.collectAsState()
    var showTutorial by remember { mutableStateOf(false) }

    LaunchedEffect(state) {
        if (state == ConnectionState.CONNECTED) onConnected()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(CamTransferColors.Background),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 520.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 22.dp, vertical = 28.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            ConnectHeader(state)
            StatusPanel(state, statusText, error)
            TutorialPrompt(onOpenTutorial = { showTutorial = true })
            TransferSizeSelector(
                preferCompressedDownloads = preferCompressedDownloads,
                enabled = state == ConnectionState.IDLE ||
                    state == ConnectionState.ERROR ||
                    state == ConnectionState.PAIRED,
                onPreferenceChanged = viewModel::setPreferCompressedDownloads,
            )
            ConnectionActions(
                state = state,
                viewModel = viewModel,
                hasError = error != null,
                onOpenWiredImport = onOpenWiredImport,
                onShareDiagnosticLog = onShareDiagnosticLog,
                onShowDisclaimer = onShowDisclaimer,
            )
        }
    }

    if (showTutorial) {
        ConnectionTutorialSheet(onDismiss = { showTutorial = false })
    }
}

@Composable
private fun ConnectHeader(state: ConnectionState) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "CAMTRANSFER",
                color = CamTransferColors.Accent,
                fontSize = 10.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 2.2.sp,
            )
            Text(
                connectionModeLabel(state),
                color = CamTransferColors.SecondaryInk,
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Text(
            "连接相机",
            color = CamTransferColors.Ink,
            fontSize = 32.sp,
            lineHeight = 36.sp,
            fontWeight = FontWeight.Black,
        )
        Text(
            "保持页面简单：先看教程，再连接相机。连接过程会在状态里显示。",
            color = CamTransferColors.SecondaryInk,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

private fun connectionModeLabel(state: ConnectionState): String =
    when (state) {
        ConnectionState.PAIRED -> "已配对"
        ConnectionState.CONNECTED -> "已连接"
        ConnectionState.ERROR -> "需要处理"
        ConnectionState.IDLE -> "蓝牙配对"
        else -> "连接中"
    }

@Composable
private fun StatusPanel(
    state: ConnectionState,
    statusText: String,
    error: String?,
) {
    val title = when (state) {
        ConnectionState.IDLE -> "准备连接"
        ConnectionState.ERROR -> "连接失败"
        ConnectionState.WAITING_CAMERA_CONFIRMATION -> "等待相机确认"
        ConnectionState.PAIRED -> "配对成功"
        ConnectionState.CONNECTED -> "已连接"
        else -> "连接中"
    }
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = animateColorAsState(
            targetValue = statusPanelColor(state, error),
            label = "connection-status-color",
        ).value,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.Top,
        ) {
            StatusIndicator(state, hasError = error != null)
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, color = CamTransferColors.Ink, fontWeight = FontWeight.Bold)
                Text(
                    connectionMessage(state, statusText, error),
                    color = if (error != null) MaterialTheme.colorScheme.error else CamTransferColors.SecondaryInk,
                    style = MaterialTheme.typography.bodySmall,
                    lineHeight = 18.sp,
                )
            }
        }
    }
}

@Composable
private fun StatusIndicator(state: ConnectionState, hasError: Boolean) {
    if (state != ConnectionState.IDLE &&
        state != ConnectionState.ERROR &&
        state != ConnectionState.PAIRED &&
        state != ConnectionState.CONNECTED
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(20.dp),
            strokeWidth = 2.dp,
            color = CamTransferColors.Accent,
        )
    } else {
        Box(
            modifier = Modifier
                .size(20.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(
                    when {
                        hasError -> MaterialTheme.colorScheme.error
                        state == ConnectionState.PAIRED || state == ConnectionState.CONNECTED -> Color(0xFF2D7D46)
                        else -> CamTransferColors.Accent
                    }
                ),
        )
    }
}

private fun statusPanelColor(state: ConnectionState, error: String?): Color =
    when {
        error != null -> Color(0xFFFFF7F5)
        state == ConnectionState.PAIRED || state == ConnectionState.CONNECTED -> Color(0xFFF3FAF1)
        else -> CamTransferColors.WarmFill
    }

private fun connectionMessage(
    state: ConnectionState,
    statusText: String,
    error: String?,
): String {
    if (error != null) return error
    return when (state) {
        ConnectionState.IDLE -> CameraPairingGuidance.IDLE_HINT
        ConnectionState.WAITING_CAMERA_CONFIRMATION -> CameraPairingGuidance.WAITING_CAMERA_CONFIRMATION_STATUS
        else -> statusText.ifBlank { CameraPairingGuidance.IDLE_HINT }
    }
}

@Composable
private fun TutorialPrompt(onOpenTutorial: () -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onOpenTutorial() },
        shape = RoundedCornerShape(18.dp),
        color = Color(0xFFFFF4DE),
        border = BorderStroke(1.dp, Color(0x339E8257)),
    ) {
        Row(
            modifier = Modifier.padding(15.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    "查看连接教程",
                    color = CamTransferColors.Ink,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Black,
                )
                Text(
                    "配对、连接、照片下载步骤都在这里。",
                    color = CamTransferColors.SecondaryInk,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Text(
                "打开",
                color = CamTransferColors.Accent,
                fontSize = 13.sp,
                fontWeight = FontWeight.Black,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ConnectionTutorialSheet(onDismiss: () -> Unit) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = CamTransferColors.Background,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 22.dp)
                .padding(bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "连接教程",
                color = CamTransferColors.Ink,
                fontSize = 28.sp,
                lineHeight = 32.sp,
                fontWeight = FontWeight.Black,
            )
            TutorialSection(
                title = "配对",
                steps = listOf(
                    CameraPairingGuidance.CAMERA_MENU_PATH,
                    "让相机停留在配对注册 / PAIRING REGISTRATION 画面。",
                    "回到 App 点连接相机；手机弹出蓝牙配对请求时点配对或允许。",
                    "看到相机显示配对成功后，再在 App 点确认。",
                ),
            )
            TutorialSection(
                title = "连接",
                steps = listOf(
                    "已配对后点进入相机相册。",
                    "App 会先用蓝牙触发相机进入 Wi-Fi 传图模式。",
                    "手机会连接相机 Wi-Fi，期间短暂不能上网是正常现象。",
                ),
            )
            TutorialSection(
                title = "照片",
                steps = listOf(
                    "进入相册后可以筛选、预览并下载照片。",
                    "下载模式可以选择原图或压缩。",
                    "下载失败时保持相机在传图/相册界面，再重试或导出诊断日志。",
                ),
            )
            PrimarySheetAction("知道了") { onDismiss() }
        }
    }
}

@Composable
private fun TutorialSection(title: String, steps: List<String>) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = CamTransferColors.Card,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                title,
                color = CamTransferColors.Accent,
                fontSize = 13.sp,
                fontWeight = FontWeight.Black,
            )
            steps.forEachIndexed { index, step ->
                GuideStep(number = "${index + 1}", label = step)
            }
        }
    }
}

@Composable
private fun GuideStep(number: String, label: String) {
    Row(verticalAlignment = Alignment.Top) {
        Box(
            modifier = Modifier
                .size(24.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(CamTransferColors.MutedFill),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                number,
                color = CamTransferColors.Ink,
                fontSize = 12.sp,
                fontWeight = FontWeight.Black,
            )
        }
        Spacer(Modifier.width(10.dp))
        Text(
            label,
            modifier = Modifier.weight(1f),
            color = CamTransferColors.SecondaryInk,
            style = MaterialTheme.typography.bodySmall,
            lineHeight = 18.sp,
        )
    }
}

@Composable
private fun PrimarySheetAction(label: String, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = CamTransferColors.Ink,
            contentColor = CamTransferColors.Card,
        ),
    ) {
        Text(label, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun TransferSizeSelector(
    preferCompressedDownloads: Boolean,
    enabled: Boolean,
    onPreferenceChanged: (Boolean) -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = CamTransferColors.WarmFill,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "下载模式",
                    color = CamTransferColors.Ink,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    if (preferCompressedDownloads) "当前：压缩" else "当前：原图",
                    color = CamTransferColors.SecondaryInk,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            TransferModeToggle(
                preferCompressedDownloads = preferCompressedDownloads,
                enabled = enabled,
                onPreferenceChanged = onPreferenceChanged,
            )
        }
    }
}

@Composable
private fun TransferModeToggle(
    preferCompressedDownloads: Boolean,
    enabled: Boolean,
    onPreferenceChanged: (Boolean) -> Unit,
) {
    Surface(
        modifier = Modifier
            .width(132.dp)
            .height(34.dp),
        shape = RoundedCornerShape(17.dp),
        color = CamTransferColors.MutedFill,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Row(
            modifier = Modifier.padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            TransferModeOption(
                label = "原图",
                selected = !preferCompressedDownloads,
                enabled = enabled,
                modifier = Modifier.weight(1f),
                onClick = { onPreferenceChanged(false) },
            )
            TransferModeOption(
                label = "压缩",
                selected = preferCompressedDownloads,
                enabled = enabled,
                modifier = Modifier.weight(1f),
                onClick = { onPreferenceChanged(true) },
            )
        }
    }
}

@Composable
private fun TransferModeOption(
    label: String,
    selected: Boolean,
    enabled: Boolean,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier = modifier
            .height(28.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(if (selected) CamTransferColors.Ink else androidx.compose.ui.graphics.Color.Transparent)
            .clickable(enabled = enabled && !selected) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = when {
                selected -> CamTransferColors.Card
                enabled -> CamTransferColors.Ink
                else -> CamTransferColors.SecondaryInk
            },
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun ConnectionActions(
    state: ConnectionState,
    viewModel: ConnectionViewModel,
    hasError: Boolean,
    onOpenWiredImport: () -> Unit,
    onShareDiagnosticLog: () -> Unit,
    onShowDisclaimer: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when (state) {
            ConnectionState.IDLE, ConnectionState.ERROR -> {
                PrimaryAction(
                    label = if (hasError) "重新搜索相机" else "连接相机",
                    containerColor = CamTransferColors.Ink,
                    contentColor = CamTransferColors.Card,
                    onClick = { viewModel.connect() },
                )
                UtilityActionRow(
                    leftLabel = "有线导入",
                    onLeftClick = onOpenWiredImport,
                    leftOutlined = true,
                    rightLabel = "诊断日志",
                    onRightClick = onShareDiagnosticLog,
                )
                SecondaryDarkAction(label = "使用须知与免责声明", onClick = onShowDisclaimer)
            }
            ConnectionState.WAITING_CAMERA_CONFIRMATION -> {
                PrimaryAction(
                    label = "相机已显示配对成功，确认",
                    containerColor = Color(0xFF2D7D46),
                    contentColor = CamTransferColors.Card,
                    onClick = { viewModel.confirmCameraPairingSucceeded() },
                )
                UtilityActionRow(
                    leftLabel = "取消连接",
                    onLeftClick = { viewModel.disconnect() },
                    rightLabel = "诊断日志",
                    onRightClick = onShareDiagnosticLog,
                )
                SecondaryOutlinedAction(label = "有线导入", onClick = onOpenWiredImport)
            }
            ConnectionState.PAIRED -> {
                PrimaryAction(
                    label = "进入相机相册",
                    containerColor = CamTransferColors.Accent,
                    contentColor = CamTransferColors.Card,
                    onClick = { viewModel.enterCameraAlbum() },
                )
                UtilityActionRow(
                    leftLabel = "重新配对",
                    onLeftClick = { viewModel.forgetPairing() },
                    leftOutlined = true,
                    rightLabel = "诊断日志",
                    onRightClick = onShareDiagnosticLog,
                )
                UtilityActionRow(
                    leftLabel = "断开",
                    onLeftClick = { viewModel.disconnect() },
                    leftOutlined = true,
                    rightLabel = "有线导入",
                    onRightClick = onOpenWiredImport,
                )
            }
            else -> {
                PrimaryAction(
                    label = "取消连接",
                    containerColor = CamTransferColors.Accent,
                    contentColor = CamTransferColors.Card,
                    onClick = { viewModel.disconnect() },
                )
                UtilityActionRow(
                    leftLabel = "有线导入",
                    onLeftClick = onOpenWiredImport,
                    leftOutlined = true,
                    rightLabel = "诊断日志",
                    onRightClick = onShareDiagnosticLog,
                )
                SecondaryDarkAction(label = "使用须知与免责声明", onClick = onShowDisclaimer)
            }
        }
    }
}

@Composable
private fun PrimaryAction(
    label: String,
    containerColor: Color,
    contentColor: Color,
    onClick: () -> Unit,
) {
    val animatedContainerColor by animateColorAsState(
        targetValue = containerColor,
        label = "primary-action-container",
    )
    val animatedContentColor by animateColorAsState(
        targetValue = contentColor,
        label = "primary-action-content",
    )
    Button(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 54.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = animatedContainerColor,
            contentColor = animatedContentColor,
        ),
    ) {
        Text(label, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun UtilityActionRow(
    leftLabel: String,
    onLeftClick: () -> Unit,
    leftOutlined: Boolean = false,
    rightLabel: String,
    onRightClick: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (leftOutlined) {
            SecondaryOutlinedAction(
                label = leftLabel,
                onClick = onLeftClick,
                modifier = Modifier.weight(1f),
            )
        } else {
            SecondaryDarkAction(
                label = leftLabel,
                onClick = onLeftClick,
                modifier = Modifier.weight(1f),
            )
        }
        SecondaryDarkAction(
            label = rightLabel,
            onClick = onRightClick,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun SecondaryOutlinedAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier.fillMaxWidth(),
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.heightIn(min = 46.dp),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = CamTransferColors.Ink),
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Text(label, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun SecondaryDarkAction(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier.fillMaxWidth(),
) {
    TextButton(
        onClick = onClick,
        modifier = modifier.heightIn(min = 44.dp),
        colors = ButtonDefaults.textButtonColors(contentColor = CamTransferColors.Ink),
    ) {
        Text(label, fontWeight = FontWeight.SemiBold)
    }
}
