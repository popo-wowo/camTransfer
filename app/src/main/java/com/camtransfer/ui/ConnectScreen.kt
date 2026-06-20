package com.camtransfer.ui

import android.content.Intent
import android.provider.Settings
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.camtransfer.service.CameraConnectionAction
import com.camtransfer.service.CameraConnectionIssue
import com.camtransfer.service.CameraConnectionPhase
import com.camtransfer.service.CameraConnectionStep
import com.camtransfer.service.CameraPairingGuidance
import com.camtransfer.service.CameraVendorPairedCameraRecord
import com.camtransfer.viewmodel.ConnectionState
import com.camtransfer.viewmodel.ConnectionViewModel

@Composable
fun ConnectScreen(
    viewModel: ConnectionViewModel,
    onOpenWiredImport: () -> Unit,
    onShareDiagnosticLog: () -> Unit,
    onShowDisclaimer: () -> Unit,
) {
    val state by viewModel.state.collectAsState()
    val statusText by viewModel.statusText.collectAsState()
    val error by viewModel.error.collectAsState()
    val connectionIssue by viewModel.connectionIssue.collectAsState()
    val activeStep by viewModel.activeStep.collectAsState()
    val preferCompressedDownloads by viewModel.preferCompressedDownloads.collectAsState()
    val pairedCameras by viewModel.pairedCameras.collectAsState()
    val selectedCameraId by viewModel.selectedCameraId.collectAsState()
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(CamTransferColors.Background),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 520.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 22.dp, vertical = 28.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            val actionsBeforeGuidance = ConnectionUiLayoutPolicy.actionsBeforeGuidance(state)
            val selectedCamera = pairedCameras.firstOrNull { it.cameraId == selectedCameraId }
                ?: pairedCameras.firstOrNull()
            ConnectHeader(state)
            val showLiveGuidance = ConnectionUiLayoutPolicy.shouldShowLiveGuidance(state, error, connectionIssue)
            if (selectedCamera != null) {
                CameraConnectionOverviewPanel(
                    camera = selectedCamera,
                    state = state,
                    statusText = statusText,
                    error = error,
                    issue = connectionIssue,
                    activeStep = activeStep,
                    showLiveGuidance = showLiveGuidance,
                    onRename = viewModel::renamePairedCamera,
                )
            }
            if (actionsBeforeGuidance) {
                ConnectionActions(
                    state = state,
                    viewModel = viewModel,
                    issue = connectionIssue,
                    onOpenWiredImport = onOpenWiredImport,
                    onShareDiagnosticLog = onShareDiagnosticLog,
                    onShowDisclaimer = onShowDisclaimer,
                )
            }
            if (ConnectionUiLayoutPolicy.shouldShowPairingPreparation(state)) {
                PairingPreparationCards(
                    onOpenBluetoothSettings = {
                        context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    },
                )
            }
            if (ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(activeStep)) {
                BluetoothPairingStepCards()
            }
            if (showLiveGuidance && selectedCamera == null) {
                ConnectionLiveGuidancePanel(
                    state = state,
                    statusText = statusText,
                    error = error,
                    issue = connectionIssue,
                )
            }
            if (ConnectionUiLayoutPolicy.shouldShowPairedCameraSelector(state, pairedCameras)) {
                PairedCameraSelector(
                    cameras = pairedCameras,
                    selectedCameraId = selectedCameraId,
                    onSelectCamera = viewModel::selectPairedCamera,
                )
            }
            connectionIssue?.let { issue ->
                if (ConnectionUiLayoutPolicy.shouldShowManualWifiCredentials(issue)) {
                    ManualWifiCredentialPanel(
                        issue = issue,
                        onCopyPassphrase = { passphrase ->
                            clipboardManager.setText(AnnotatedString(passphrase))
                        },
                    )
                }
            }
            if (ConnectionUiLayoutPolicy.shouldShowTransferSizeSelector(state)) {
                TransferSizeSelector(
                    preferCompressedDownloads = preferCompressedDownloads,
                    enabled = true,
                    onPreferenceChanged = viewModel::setPreferCompressedDownloads,
                )
            }
            if (!actionsBeforeGuidance) {
                ConnectionActions(
                    state = state,
                    viewModel = viewModel,
                    issue = connectionIssue,
                    onOpenWiredImport = onOpenWiredImport,
                    onShareDiagnosticLog = onShareDiagnosticLog,
                    onShowDisclaimer = onShowDisclaimer,
                )
            }
        }
    }
}

@Composable
private fun ManualWifiCredentialPanel(
    issue: CameraConnectionIssue,
    onCopyPassphrase: (String) -> Unit,
) {
    val ssid = issue.wifiSsid?.takeIf { it.isNotBlank() }
    val passphrase = issue.wifiPassphrase?.takeIf { it.isNotBlank() }
    if (ssid == null && passphrase == null) return

    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        color = CamTransferColors.Card,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Column(
            modifier = Modifier.padding(13.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(
                "手动连接相机 Wi-Fi",
                color = CamTransferColors.Ink,
                fontSize = 14.sp,
                fontWeight = FontWeight.Black,
            )
            ssid?.let {
                ManualWifiCredentialRow(label = "Wi-Fi 名称", value = it)
            }
            passphrase?.let {
                ManualWifiCredentialRow(label = "密码", value = it)
                OutlinedButton(
                    onClick = { onCopyPassphrase(it) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 42.dp),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = CamTransferColors.Ink),
                    border = BorderStroke(1.dp, CamTransferColors.Hairline),
                ) {
                    Text("复制密码", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
private fun ManualWifiCredentialRow(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            label,
            color = CamTransferColors.SecondaryInk,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(
            value,
            color = CamTransferColors.Ink,
            fontSize = 15.sp,
            lineHeight = 20.sp,
            fontWeight = FontWeight.Black,
        )
    }
}

internal object ConnectionStartActionPolicy {
    fun primaryConnectLabel(): String = "开始配对"
}

internal object ConnectionFailureActionPolicy {
    fun primaryAction(issue: CameraConnectionIssue?): CameraConnectionAction =
        when {
            issue?.primaryAction == CameraConnectionAction.ResetConnection -> CameraConnectionAction.ResetConnection
            issue?.phase == CameraConnectionPhase.PAIR_CAMERA -> CameraConnectionAction.RestartPairing
            else -> CameraConnectionAction.RetryStep
        }

    fun primaryLabel(issue: CameraConnectionIssue?): String =
        when (primaryAction(issue)) {
            CameraConnectionAction.RestartPairing -> "重新配对"
            CameraConnectionAction.ResetConnection -> "重置连接"
            else -> "重试"
        }
}

internal object ConnectionPairedPrimaryActionPolicy {
    fun primaryAction(issue: CameraConnectionIssue?): CameraConnectionAction =
        when {
            issue?.primaryAction == CameraConnectionAction.ResetConnection -> CameraConnectionAction.ResetConnection
            issue?.phase == CameraConnectionPhase.ENTER_GALLERY -> CameraConnectionAction.RetryStep
            else -> CameraConnectionAction.EnterGallery
        }

    fun primaryLabel(issue: CameraConnectionIssue?): String =
        when (primaryAction(issue)) {
            CameraConnectionAction.ResetConnection -> "重置连接"
            CameraConnectionAction.RetryStep -> "重试"
            else -> "进入相机相册"
        }
}

internal object ConnectionUiLayoutPolicy {
    fun actionsBeforeGuidance(state: ConnectionState): Boolean =
        false

    fun shouldShowPairingPreparation(state: ConnectionState): Boolean =
        state == ConnectionState.IDLE

    fun shouldShowBluetoothPairingSteps(step: CameraConnectionStep?): Boolean =
        step == CameraConnectionStep.BleScan ||
            step == CameraConnectionStep.BleHandshake ||
            step == CameraConnectionStep.PairingConfirmation

    fun shouldShowLiveGuidance(
        state: ConnectionState,
        error: String?,
        issue: CameraConnectionIssue?,
    ): Boolean =
        state != ConnectionState.IDLE || error != null || issue != null

    fun shouldShowTransferSizeSelector(state: ConnectionState): Boolean =
        state == ConnectionState.PAIRED

    fun shouldShowPairedCameraSelector(
        state: ConnectionState,
        pairedCameras: List<CameraVendorPairedCameraRecord>,
    ): Boolean =
        state == ConnectionState.PAIRED && pairedCameras.size > 1

    fun shouldShowManualWifiCredentials(issue: CameraConnectionIssue): Boolean =
        !issue.wifiSsid.isNullOrBlank() || !issue.wifiPassphrase.isNullOrBlank()
}

enum class CameraIdentityRingState {
    Neutral,
    Connecting,
    BleOnline,
}

internal data class ConnectionCameraIdentityContent(
    val displayName: String,
    val modelName: String,
    val avatarText: String,
    val detail: String,
    val ringState: CameraIdentityRingState,
)

internal object ConnectionCameraIdentityPolicy {
    fun content(
        camera: CameraVendorPairedCameraRecord,
        state: ConnectionState,
        statusText: String,
        activeStep: CameraConnectionStep?,
    ): ConnectionCameraIdentityContent {
        val modelName = camera.deviceName.ifBlank { "CAMERA" }
        return ConnectionCameraIdentityContent(
            displayName = camera.localDisplayName?.takeIf { it.isNotBlank() } ?: modelName,
            modelName = modelName,
            avatarText = avatarText(modelName),
            detail = camera.serialNumber.takeIf { it.isNotBlank() }
                ?: camera.wifiConfigurations.firstOrNull()?.ssid
                ?: camera.bluetoothAddress.orEmpty(),
            ringState = ringState(state, statusText, activeStep),
        )
    }

    private fun avatarText(modelName: String): String {
        val normalized = modelName.trim().ifBlank { "CAM" }
        if (normalized.length <= 6) return normalized
        val cameraModel = Regex("""[A-Za-z]+[- ]?[A-Za-z0-9]+""")
            .find(normalized)
            ?.value
            ?.replace(" ", "-")
            .orEmpty()
        return cameraModel.takeIf { it.length in 2..6 } ?: normalized.take(6)
    }

    private fun ringState(
        state: ConnectionState,
        statusText: String,
        activeStep: CameraConnectionStep?,
    ): CameraIdentityRingState =
        when {
            state == ConnectionState.SCANNING ||
                state == ConnectionState.CONNECTING_BLE ||
                activeStep == CameraConnectionStep.BleScan ||
                activeStep == CameraConnectionStep.BleHandshake ||
                activeStep == CameraConnectionStep.ReconnectPairedBle ||
                activeStep == CameraConnectionStep.TransferAuthorization -> CameraIdentityRingState.Connecting
            statusText.startsWith("相机在线") ||
                state == ConnectionState.CONNECTING_WIFI ||
                state == ConnectionState.CONNECTING_PTP ||
                state == ConnectionState.CONNECTED -> CameraIdentityRingState.BleOnline
            else -> CameraIdentityRingState.Neutral
        }
}

@Composable
private fun CameraConnectionOverviewPanel(
    camera: CameraVendorPairedCameraRecord,
    state: ConnectionState,
    statusText: String,
    error: String?,
    issue: CameraConnectionIssue?,
    activeStep: CameraConnectionStep?,
    showLiveGuidance: Boolean,
    onRename: (String, String) -> Unit,
) {
    val content = ConnectionCameraIdentityPolicy.content(
        camera = camera,
        state = state,
        statusText = statusText,
        activeStep = activeStep,
    )
    var editing by remember(camera.cameraId) { mutableStateOf(false) }
    var draftName by remember(camera.cameraId, content.displayName) { mutableStateOf(content.displayName) }
    val guidance = if (showLiveGuidance) {
        ConnectionLiveGuidancePolicy.content(
            state = state,
            statusText = statusText,
            error = error,
            issue = issue,
        )
    } else {
        null
    }
    val accentColor = guidance?.let(::liveGuidanceAccentColor) ?: identityRingColor(content.ringState)

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = if (guidance == null) 94.dp else 154.dp),
        shape = RoundedCornerShape(18.dp),
        color = CamTransferColors.Card,
        border = BorderStroke(1.dp, accentColor.copy(alpha = 0.22f)),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CameraIdentityAvatar(content)
                Spacer(Modifier.width(14.dp))
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            content.displayName,
                            color = CamTransferColors.Ink,
                            fontSize = 20.sp,
                            lineHeight = 24.sp,
                            fontWeight = FontWeight.Black,
                            maxLines = 1,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        Spacer(Modifier.width(6.dp))
                        PencilEditButton(onClick = { editing = true })
                    }
                    Text(
                        content.modelName,
                        color = CamTransferColors.SecondaryInk,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                    )
                    if (content.detail.isNotBlank()) {
                        Text(
                            content.detail,
                            color = CamTransferColors.SecondaryInk.copy(alpha = 0.78f),
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                        )
                    }
                }
            }
            guidance?.let { content ->
                CameraOverviewGuidanceRow(
                    state = state,
                    content = content,
                    accentColor = accentColor,
                )
            }
        }
    }

    if (editing) {
        AlertDialog(
            onDismissRequest = { editing = false },
            title = { Text("相机昵称") },
            text = {
                OutlinedTextField(
                    value = draftName,
                    onValueChange = { draftName = it.take(24) },
                    singleLine = true,
                    label = { Text("本地显示名称") },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onRename(camera.cameraId, draftName)
                        editing = false
                    },
                ) {
                    Text("保存")
                }
            },
            dismissButton = {
                TextButton(onClick = { editing = false }) {
                    Text("取消")
                }
            },
        )
    }
}

@Composable
private fun CameraOverviewGuidanceRow(
    state: ConnectionState,
    content: ConnectionLiveGuidanceContent,
    accentColor: Color,
) {
    Row(
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(17.dp))
                .background(accentColor.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            StatusIndicator(
                state = state,
                hasError = content.isError,
                hasBleOnline = content.isBleOnline,
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                content.stepLabel,
                color = accentColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.Black,
            )
            Text(
                content.title,
                color = CamTransferColors.Ink,
                fontSize = 18.sp,
                lineHeight = 22.sp,
                fontWeight = FontWeight.Black,
            )
            Text(
                content.message,
                color = CamTransferColors.SecondaryInk,
                fontSize = 13.sp,
                lineHeight = 18.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@Composable
private fun CameraIdentityAvatar(content: ConnectionCameraIdentityContent) {
    val ringColor = identityRingColor(content.ringState)
    val ringWidth by animateDpAsState(
        targetValue = if (content.ringState == CameraIdentityRingState.Neutral) 1.dp else 2.dp,
        label = "camera-avatar-ring-width",
    )
    val infiniteTransition = rememberInfiniteTransition(label = "camera-avatar-ring")
    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 0.86f,
        targetValue = 1.0f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "camera-avatar-ring-pulse-scale",
    )
    val pulseAlpha by infiniteTransition.animateFloat(
        initialValue = 0.18f,
        targetValue = 0.42f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "camera-avatar-ring-pulse-alpha",
    )
    Box(
        modifier = Modifier.size(70.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (content.ringState == CameraIdentityRingState.Connecting) {
            Canvas(modifier = Modifier.size(70.dp)) {
                drawCircle(
                    color = ringColor.copy(alpha = pulseAlpha),
                    radius = size.minDimension * 0.5f * pulseScale,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx()),
                )
            }
        }
        Surface(
            modifier = Modifier.size(62.dp),
            shape = CircleShape,
            color = CamTransferColors.WarmFill,
            border = BorderStroke(ringWidth, ringColor),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    content.avatarText,
                    color = CamTransferColors.Ink,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Black,
                    maxLines = 1,
                )
            }
        }
        if (content.ringState == CameraIdentityRingState.Connecting) {
            CircularProgressIndicator(
                modifier = Modifier.size(70.dp),
                strokeWidth = 2.dp,
                color = ringColor,
            )
        }
    }
}

@Composable
private fun PencilEditButton(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(24.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.size(14.dp)) {
            val strokeWidth = 1.7.dp.toPx()
            val color = CamTransferColors.SecondaryInk
            drawLine(
                color = color,
                start = Offset(size.width * 0.26f, size.height * 0.74f),
                end = Offset(size.width * 0.74f, size.height * 0.26f),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round,
            )
            drawLine(
                color = color,
                start = Offset(size.width * 0.62f, size.height * 0.18f),
                end = Offset(size.width * 0.82f, size.height * 0.38f),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round,
            )
            drawLine(
                color = color,
                start = Offset(size.width * 0.22f, size.height * 0.82f),
                end = Offset(size.width * 0.42f, size.height * 0.76f),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round,
            )
        }
    }
}

private fun identityRingColor(state: CameraIdentityRingState): Color =
    when (state) {
        CameraIdentityRingState.Neutral -> CamTransferColors.Hairline
        CameraIdentityRingState.Connecting -> CamTransferColors.Accent
        CameraIdentityRingState.BleOnline -> Color(0xFF2E6FBA)
    }

@Composable
private fun PairedCameraSelector(
    cameras: List<CameraVendorPairedCameraRecord>,
    selectedCameraId: String?,
    onSelectCamera: (String) -> Unit,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        color = CamTransferColors.Card,
        border = BorderStroke(1.dp, CamTransferColors.Hairline),
    ) {
        Column(
            modifier = Modifier.padding(13.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                "已配对相机",
                color = CamTransferColors.Ink,
                fontSize = 14.sp,
                fontWeight = FontWeight.Black,
            )
            cameras.forEach { camera ->
                val selected = camera.cameraId == selectedCameraId
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelectCamera(camera.cameraId) },
                    shape = RoundedCornerShape(10.dp),
                    color = if (selected) CamTransferColors.Accent.copy(alpha = 0.10f) else CamTransferColors.Background,
                    border = BorderStroke(
                        1.dp,
                        if (selected) CamTransferColors.Accent.copy(alpha = 0.35f) else CamTransferColors.Hairline,
                    ),
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                camera.localDisplayName?.takeIf { it.isNotBlank() } ?: camera.deviceName,
                                color = CamTransferColors.Ink,
                                fontSize = 15.sp,
                                fontWeight = FontWeight.Black,
                            )
                            val detail = camera.serialNumber.takeIf { it.isNotBlank() }
                                ?: camera.wifiConfigurations.firstOrNull()?.ssid
                                ?: camera.bluetoothAddress.orEmpty()
                            if (detail.isNotBlank()) {
                                Text(
                                    detail,
                                    color = CamTransferColors.SecondaryInk,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.SemiBold,
                                )
                            }
                        }
                        Text(
                            if (selected) "当前" else "选择",
                            color = if (selected) CamTransferColors.Accent else CamTransferColors.SecondaryInk,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Black,
                        )
                    }
                }
            }
        }
    }
}

private fun connectionActionLabel(action: CameraConnectionAction): String =
    when (action) {
        CameraConnectionAction.RetryStep -> "重试当前步骤"
        CameraConnectionAction.RestartPairing -> "重新配对"
        CameraConnectionAction.ResetConnection -> "重置连接"
        CameraConnectionAction.EnterGallery -> "进入相册"
        CameraConnectionAction.ConfirmCameraPairingMode -> "我已准备好，开始搜索"
        CameraConnectionAction.ConfirmCameraReady -> "我已在相机上确认，继续"
        CameraConnectionAction.ConfirmWifiJoined -> "手机已连上相机 Wi-Fi"
        CameraConnectionAction.OpenSystemBluetoothSettings -> "打开系统蓝牙"
        CameraConnectionAction.ExportDiagnosticLog -> "诊断日志"
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

internal data class ConnectionLiveGuidanceContent(
    val step: CameraConnectionStep,
    val stepLabel: String,
    val title: String,
    val message: String,
    val isProminent: Boolean,
    val isError: Boolean,
    val isBleOnline: Boolean = false,
)

internal object ConnectionLiveGuidancePolicy {
    fun content(
        state: ConnectionState,
        statusText: String,
        error: String?,
        issue: CameraConnectionIssue?,
    ): ConnectionLiveGuidanceContent {
        if (issue != null) {
            return ConnectionLiveGuidanceContent(
                step = issue.step,
                stepLabel = issueLabel(issue.step),
                title = issue.title,
                message = issue.detail,
                isProminent = true,
                isError = false,
            )
        }
        if (error != null) {
            return ConnectionLiveGuidanceContent(
                step = stepForState(state),
                stepLabel = "需要处理",
                title = "需要处理",
                message = error,
                isProminent = true,
                isError = true,
            )
        }
        val bleOnline = state == ConnectionState.PAIRED && statusText.isBleOnlineText()
        return ConnectionLiveGuidanceContent(
            step = stepForState(state),
            stepLabel = if (bleOnline) "蓝牙在线" else stepLabelForState(state),
            title = if (bleOnline) "蓝牙已连接" else titleForState(state),
            message = messageForState(state, statusText),
            isProminent = true,
            isError = false,
            isBleOnline = bleOnline,
        )
    }

    private fun titleForState(state: ConnectionState): String =
        when (state) {
            ConnectionState.IDLE -> "准备连接"
            ConnectionState.WAITING_CAMERA_CONFIRMATION -> "请看相机屏幕"
            ConnectionState.PAIRED -> "已保存配对"
            ConnectionState.CONNECTED -> "已连接"
            ConnectionState.ERROR -> "需要处理"
            else -> "正在处理"
        }

    private fun messageForState(state: ConnectionState, statusText: String): String =
        when (state) {
            ConnectionState.IDLE -> statusText.ifBlank { CameraPairingGuidance.IDLE_HINT }
            ConnectionState.WAITING_CAMERA_CONFIRMATION -> CameraPairingGuidance.WAITING_CAMERA_CONFIRMATION_STATUS
            else -> statusText.ifBlank { CameraPairingGuidance.IDLE_HINT }
        }

    private fun stepLabelForState(state: ConnectionState): String =
        when (state) {
            ConnectionState.IDLE -> "准备连接"
            ConnectionState.WAITING_CAMERA_CONFIRMATION -> "看相机屏幕"
            ConnectionState.PAIRED -> "下一步"
            ConnectionState.CONNECTED -> "已完成"
            ConnectionState.ERROR -> "需要处理"
            else -> "实时提醒"
        }

    private fun issueLabel(step: CameraConnectionStep): String =
        when (step) {
            CameraConnectionStep.CameraPairingMode,
            CameraConnectionStep.StaleBondCheck -> "请先确认"
            CameraConnectionStep.JoinCameraWifi,
            CameraConnectionStep.ConnectPtp,
            CameraConnectionStep.LoadGallery -> "需要你处理"
            else -> "实时提醒"
        }

    private fun stepForState(state: ConnectionState): CameraConnectionStep =
        when (state) {
            ConnectionState.IDLE -> CameraConnectionStep.CameraPairingMode
            ConnectionState.SCANNING -> CameraConnectionStep.BleScan
            ConnectionState.CONNECTING_BLE -> CameraConnectionStep.BleHandshake
            ConnectionState.WAITING_CAMERA_CONFIRMATION -> CameraConnectionStep.PairingConfirmation
            ConnectionState.PAIRED -> CameraConnectionStep.SavePairing
            ConnectionState.CONNECTING_WIFI -> CameraConnectionStep.JoinCameraWifi
            ConnectionState.CONNECTING_PTP -> CameraConnectionStep.ConnectPtp
            ConnectionState.CONNECTED -> CameraConnectionStep.LoadGallery
            ConnectionState.ERROR -> CameraConnectionStep.EnvironmentCheck
        }

    private fun String.isBleOnlineText(): Boolean =
        startsWith("相机在线")
}

@Composable
private fun ConnectionLiveGuidancePanel(
    state: ConnectionState,
    statusText: String,
    error: String?,
    issue: CameraConnectionIssue?,
) {
    val content = ConnectionLiveGuidancePolicy.content(
        state = state,
        statusText = statusText,
        error = error,
        issue = issue,
    )
    val accentColor = liveGuidanceAccentColor(content)
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 132.dp),
        shape = RoundedCornerShape(18.dp),
        color = animateColorAsState(
            targetValue = CamTransferColors.Card,
            label = "connection-live-guidance-color",
        ).value,
        border = BorderStroke(1.dp, accentColor.copy(alpha = 0.22f)),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(RoundedCornerShape(17.dp))
                    .background(accentColor.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                StatusIndicator(
                    state = state,
                    hasError = content.isError,
                    hasBleOnline = content.isBleOnline,
                )
            }
            Spacer(Modifier.width(13.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Text(
                    content.stepLabel,
                    color = accentColor,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Black,
                )
                Text(
                    content.title,
                    color = CamTransferColors.Ink,
                    fontSize = 18.sp,
                    lineHeight = 22.sp,
                    fontWeight = FontWeight.Black,
                )
                Text(
                    content.message,
                    color = if (content.isError) MaterialTheme.colorScheme.error else CamTransferColors.SecondaryInk,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun StatusIndicator(
    state: ConnectionState,
    hasError: Boolean,
    hasBleOnline: Boolean,
) {
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
                        hasBleOnline -> Color(0xFF2E6FBA)
                        state == ConnectionState.CONNECTED -> Color(0xFF2D7D46)
                        else -> CamTransferColors.Accent
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (hasBleOnline) {
                Text(
                    "BT",
                    color = CamTransferColors.Card,
                    fontSize = 7.sp,
                    fontWeight = FontWeight.Black,
                )
            }
        }
    }
}

private val ConnectionLiveGuidanceContent.isSuccess: Boolean
    get() = step == CameraConnectionStep.LoadGallery && title == "已连接"

private fun liveGuidanceAccentColor(content: ConnectionLiveGuidanceContent): Color =
    when {
        content.isError -> Color(0xFFB6472D)
        content.isBleOnline -> Color(0xFF2E6FBA)
        content.isSuccess -> Color(0xFF2D7D46)
        else -> CamTransferColors.Accent
    }

@Composable
private fun PairingPreparationCards(
    onOpenBluetoothSettings: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        PairingPreparationCard(
            number = "1",
            label = "相机准备",
            title = "进入配对注册界面",
            body = "在相机上打开下面这个菜单，停在配对注册界面后，再回到 App 开始配对。",
            footnote = CameraPairingGuidance.CAMERA_MENU_PATH,
            accentColor = CamTransferColors.Accent,
        )
        PairingPreparationCard(
            number = "2",
            label = "手机准备",
            title = "取消旧的蓝牙配对",
            body = "如果这台相机以前配过，请到手机系统蓝牙里找到 X-T / FUJIFILM 相机记录，先取消配对，再回到这里。",
            footnote = "系统设置 -> 蓝牙 -> 相机名称 -> 取消配对/忽略此设备",
            accentColor = Color(0xFF2D7D46),
            actionLabel = "打开系统蓝牙",
            onAction = onOpenBluetoothSettings,
        )
    }
}

@Composable
private fun BluetoothPairingStepCards() {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        PairingPreparationCard(
            number = "!",
            label = "相机操作",
            title = "需要相机确认",
            body = "请看相机屏幕。如果出现 OK、确定、配对或允许连接提示，先在相机上按 OK/确定。",
            accentColor = Color(0xFFB6472D),
        )
        PairingPreparationCard(
            number = "2",
            label = "手机操作",
            title = "在手机上点配对/允许",
            body = "如果手机弹出蓝牙配对请求，请点“配对”或“允许”。点完留在当前页面，App 会继续连接。",
            accentColor = Color(0xFF2D7D46),
        )
    }
}

@Composable
private fun PairingPreparationCard(
    number: String,
    label: String,
    title: String,
    body: String,
    accentColor: Color,
    footnote: String? = null,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(18.dp),
        color = CamTransferColors.Card,
        border = BorderStroke(1.dp, accentColor.copy(alpha = 0.22f)),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(RoundedCornerShape(17.dp))
                    .background(accentColor.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    number,
                    color = accentColor,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Black,
                )
            }
            Spacer(Modifier.width(13.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Text(
                    label,
                    color = accentColor,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Black,
                )
                Text(
                    title,
                    color = CamTransferColors.Ink,
                    fontSize = 18.sp,
                    lineHeight = 22.sp,
                    fontWeight = FontWeight.Black,
                )
                Text(
                    body,
                    color = CamTransferColors.SecondaryInk,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                footnote?.let {
                    Surface(
                        shape = RoundedCornerShape(9.dp),
                        color = accentColor.copy(alpha = 0.08f),
                    ) {
                        Text(
                            it,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 7.dp),
                            color = CamTransferColors.Ink,
                            fontSize = 12.sp,
                            lineHeight = 16.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
                if (actionLabel != null && onAction != null) {
                    OutlinedButton(
                        onClick = onAction,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 42.dp),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = CamTransferColors.Ink),
                        border = BorderStroke(1.dp, accentColor.copy(alpha = 0.34f)),
                    ) {
                        Text(actionLabel, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
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
    issue: CameraConnectionIssue?,
    onOpenWiredImport: () -> Unit,
    onShareDiagnosticLog: () -> Unit,
    onShowDisclaimer: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when (state) {
            ConnectionState.IDLE -> {
                PrimaryAction(
                    label = ConnectionStartActionPolicy.primaryConnectLabel(),
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
            ConnectionState.ERROR -> {
                PrimaryAction(
                    label = ConnectionFailureActionPolicy.primaryLabel(issue),
                    containerColor = CamTransferColors.Ink,
                    contentColor = CamTransferColors.Card,
                    onClick = {
                        when (ConnectionFailureActionPolicy.primaryAction(issue)) {
                            CameraConnectionAction.RestartPairing -> viewModel.forgetPairing()
                            CameraConnectionAction.ResetConnection -> viewModel.resetConnectionForFreshPairing()
                            else -> viewModel.retryCurrentIssue()
                        }
                    },
                )
            }
            ConnectionState.WAITING_CAMERA_CONFIRMATION -> {
                PrimaryAction(
                    label = "我已在相机上确认，继续",
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
                if (issue?.phase == CameraConnectionPhase.PAIR_CAMERA) {
                    PrimaryAction(
                        label = "继续处理配对问题",
                        containerColor = CamTransferColors.Ink,
                        contentColor = CamTransferColors.Card,
                        onClick = { viewModel.retryCurrentIssue() },
                    )
                } else {
                    val action = ConnectionPairedPrimaryActionPolicy.primaryAction(issue)
                    PrimaryAction(
                        label = ConnectionPairedPrimaryActionPolicy.primaryLabel(issue),
                        containerColor = CamTransferColors.Accent,
                        contentColor = CamTransferColors.Card,
                        onClick = {
                            when (action) {
                                CameraConnectionAction.ResetConnection -> viewModel.resetConnectionForFreshPairing()
                                CameraConnectionAction.RetryStep -> viewModel.retryCurrentIssue()
                                else -> viewModel.enterCameraAlbum()
                            }
                        },
                    )
                }
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
