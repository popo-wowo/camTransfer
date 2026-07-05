package com.camtransfer

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.camtransfer.ui.BrowseScreen
import com.camtransfer.ui.CamTransferTheme
import com.camtransfer.ui.ConnectScreen
import com.camtransfer.ui.GalleryTransferModeUiPolicy
import com.camtransfer.ui.TransferScreen
import com.camtransfer.model.TransferDownloadMode
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.DiagnosticLog
import com.camtransfer.service.WiredCameraService
import com.camtransfer.viewmodel.BrowseViewModel
import com.camtransfer.viewmodel.ConnectionState
import com.camtransfer.viewmodel.ConnectionViewModel
import com.camtransfer.viewmodel.TransferViewModel
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.lifecycleScope

class MainActivity : ComponentActivity() {

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        installCrashLogging()

        setContent {
            CamTransferTheme {
                Surface(Modifier.fillMaxSize()) {
                    val context = LocalContext.current
                    var hasAcceptedDisclaimer by remember {
                        mutableStateOf(context.hasAcceptedDisclaimer())
                    }
                    var trialAccess by remember { mutableStateOf(currentTrialAccess()) }
                    LaunchedEffect(Unit) {
                        while (true) {
                            trialAccess = currentTrialAccess()
                            delay(1_000)
                        }
                    }
                    LaunchedEffect(hasAcceptedDisclaimer) {
                        if (hasAcceptedDisclaimer) requestMissingPermissions()
                    }

                    if (!hasAcceptedDisclaimer) {
                        DisclaimerDialog(
                            trialDays = trialDays(),
                            confirmText = "我已知晓并同意",
                            dismissText = null,
                            onConfirm = {
                                context.markDisclaimerAccepted()
                                hasAcceptedDisclaimer = true
                            },
                            onDismiss = {},
                        )
                    } else if (trialAccess.canUse) {
                        CamTransferApp(trialDays = trialDays())
                    } else {
                        TrialExpiredScreen(trialAccess, trialDays = trialDays())
                    }
                }
            }
        }
    }

    private fun requestMissingPermissions() {
        val missing = AppPermissionPolicy.requiredRuntimePermissions().filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            permissionLauncher.launch(missing.toTypedArray())
        }
    }

    private fun currentTrialAccess(): TrialAccess {
        return TrialAccessPolicy.evaluateBuildStart(
            startEpochMillis = BuildConfig.TRIAL_START_EPOCH_MILLIS,
            durationMinutes = BuildConfig.TRIAL_DURATION_MINUTES,
        )
    }

    fun shareDiagnosticLog() {
        lifecycleScope.launch {
            val shareIntent = withContext(Dispatchers.IO) {
                DiagnosticLog.shareIntent(this@MainActivity)
            }
            startActivity(Intent.createChooser(shareIntent, "导出诊断日志"))
        }
    }

    private fun installCrashLogging() {
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            runCatching {
                DiagnosticLog.appendCrash(applicationContext, thread, throwable)
            }
            previousHandler?.uncaughtException(thread, throwable)
                ?: kotlin.system.exitProcess(2)
        }
    }
}

enum class Screen { CONNECT, BROWSE, TRANSFER }

@Composable
fun CamTransferApp(trialDays: Long) {
    val context = LocalContext.current
    val debugEnterGallery = (context as? MainActivity)?.shouldDebugEnterGallery() == true
    val connectionVM: ConnectionViewModel = viewModel()
    val browseVM: BrowseViewModel = viewModel()
    val transferVM: TransferViewModel = viewModel()
    val connectionState by connectionVM.state.collectAsState()
    val galleryConnectionEvent by connectionVM.galleryConnectionEvent.collectAsState()
    val scope = rememberCoroutineScope()
    val wiredCameraService = remember { WiredCameraService(context.applicationContext) }

    var currentScreen by remember { mutableStateOf(Screen.CONNECT) }
    var showsDisclaimer by remember { mutableStateOf(false) }
    var wiredError by remember { mutableStateOf<String?>(null) }
    var activeCameraSource by remember { mutableStateOf<CameraFileSource?>(null) }
    var isWiredImport by remember { mutableStateOf(false) }
    var isReturningToConnect by remember { mutableStateOf(false) }
    var lastHandledGalleryConnectionEvent by remember { mutableStateOf(0L) }
    var debugEnterGalleryHandled by remember { mutableStateOf(false) }

    fun openWirelessBrowse() {
        isReturningToConnect = false
        isWiredImport = false
        activeCameraSource = connectionVM.cameraService
        transferVM.switchSource(connectionVM.cameraService)
        browseVM.reset()
        currentScreen = Screen.BROWSE
    }

    fun returnFromTransferToBrowse() {
        val cameraSource = activeCameraSource ?: connectionVM.cameraService
        DiagnosticLog.append(context, "Navigation", "Return from transfer to browse; resume gallery loading")
        browseVM.resumeGalleryLoadingAfterTransfer(cameraSource)
        currentScreen = Screen.BROWSE
    }

    fun exitCameraAlbumToConnect(reason: String) {
        val cameraSource = activeCameraSource ?: connectionVM.cameraService
        DiagnosticLog.append(context, "Navigation", "Exit camera album reason=$reason; disconnect camera source")
        isReturningToConnect = true
        browseVM.clearHighDefinitionPreviewSessionCache(cameraSource, reason = reason)
        browseVM.reset()
        scope.launch {
            if (isWiredImport) {
                wiredCameraService.disconnect()
            } else {
                connectionVM.disconnect()
            }
        }
        isWiredImport = false
        activeCameraSource = null
        currentScreen = Screen.CONNECT
    }

    LaunchedEffect(debugEnterGallery, connectionState) {
        if (
            debugEnterGallery &&
            !debugEnterGalleryHandled &&
            BuildConfig.DEBUG &&
            connectionState == ConnectionState.PAIRED
        ) {
            debugEnterGalleryHandled = true
            DiagnosticLog.append(context, "Debug", "Auto entering gallery from debug intent after startup delay")
            delay(DEBUG_ENTER_GALLERY_STARTUP_DELAY_MS)
            connectionVM.enterCameraAlbum()
        }
    }

    LaunchedEffect(connectionState) {
        if (connectionState != ConnectionState.CONNECTED) {
            isReturningToConnect = false
        }
        if (
            CameraScreenRoutePolicy.shouldReturnToConnect(
                isWiredImport = isWiredImport,
                hasActiveCameraSource = activeCameraSource != null,
                connectionState = connectionState,
                currentScreen = currentScreen,
            )
        ) {
            DiagnosticLog.append(context, "Navigation", "Return to connect state=$connectionState screen=$currentScreen")
            activeCameraSource?.let { source ->
                browseVM.clearHighDefinitionPreviewSessionCache(source, reason = "return-connect")
            }
            currentScreen = Screen.CONNECT
        }
    }

    LaunchedEffect(galleryConnectionEvent, connectionState, currentScreen) {
        if (
            CameraScreenRoutePolicy.shouldOpenBrowseFromGalleryConnectionEvent(
                lastHandledGalleryConnectionEvent = lastHandledGalleryConnectionEvent,
                galleryConnectionEvent = galleryConnectionEvent,
                isReturningToConnect = isReturningToConnect,
                connectionState = connectionState,
                currentScreen = currentScreen,
            )
        ) {
            lastHandledGalleryConnectionEvent = galleryConnectionEvent
            DiagnosticLog.append(context, "Navigation", "Open browse event=$galleryConnectionEvent state=$connectionState")
            openWirelessBrowse()
        }
    }

    when (currentScreen) {
        Screen.CONNECT -> ConnectScreen(
            viewModel = connectionVM,
            onOpenWiredImport = {
                scope.launch {
                    wiredError = null
                    runCatching {
                        wiredCameraService.connectFirstAvailableDevice()
                    }.onSuccess {
                        isWiredImport = true
                        activeCameraSource = wiredCameraService
                        transferVM.switchSource(wiredCameraService)
                        browseVM.reset()
                        currentScreen = Screen.BROWSE
                    }.onFailure { error ->
                        wiredError = error.message ?: "有线相机连接失败"
                    }
                }
            },
            onShareDiagnosticLog = { (context as? MainActivity)?.shareDiagnosticLog() },
            onShowDisclaimer = { showsDisclaimer = true },
        )
        Screen.BROWSE -> {
            val cameraSource = activeCameraSource ?: connectionVM.cameraService
            transferVM.init(cameraSource)
            val transferItems by transferVM.items.collectAsState()
            val downloadedItems by transferVM.downloadedItems.collectAsState()
            val isTransferring by transferVM.isTransferring.collectAsState()
            val preferCompressedDownloads by connectionVM.preferCompressedDownloads.collectAsState()
            BrowseScreen(
                viewModel = browseVM,
                cameraSource = cameraSource,
                transferItems = transferItems,
                downloadedItems = downloadedItems,
                isTransferring = isTransferring,
                preferCompressedDownloads = preferCompressedDownloads,
                canChangeTransferMode = GalleryTransferModeUiPolicy.canChangeTransferMode(isTransferring),
                onFilesLoaded = { files -> transferVM.syncDownloadedFiles(files) },
                onPreferenceChanged = connectionVM::setPreferCompressedDownloads,
                onQueueDownloadSelected = { files ->
                    transferVM.init(cameraSource)
                    transferVM.enqueue(
                        files = files,
                        downloadMode = if (preferCompressedDownloads) {
                            TransferDownloadMode.COMPRESSED
                        } else {
                            TransferDownloadMode.ORIGINAL
                        },
                    )
                },
                onCancelQueuedDownloads = { files ->
                    transferVM.init(cameraSource)
                    transferVM.removePending(files)
                },
                onDownloadSelected = { files ->
                    transferVM.init(cameraSource)
                    transferVM.startTransfer(
                        files = files,
                        downloadMode = if (preferCompressedDownloads) {
                            TransferDownloadMode.COMPRESSED
                        } else {
                            TransferDownloadMode.ORIGINAL
                        },
                        beforeStart = {
                            browseVM.prepareGalleryLoadingForTransfer(cameraSource)
                        },
                    )
                    currentScreen = CameraScreenRoutePolicy.screenAfterDownloadStarted(currentScreen)
                },
                onStartQueuedDownloads = {
                    transferVM.init(cameraSource)
                    transferVM.startQueuedTransfer(
                        downloadMode = if (preferCompressedDownloads) {
                            TransferDownloadMode.COMPRESSED
                        } else {
                            TransferDownloadMode.ORIGINAL
                        },
                        beforeStart = {
                            browseVM.prepareGalleryLoadingForTransfer(cameraSource)
                        },
                    )
                    currentScreen = Screen.TRANSFER
                },
                onOpenDownloads = { currentScreen = Screen.TRANSFER },
                onDisconnect = { exitCameraAlbumToConnect(reason = "album-exit") },
            )
        }
        Screen.TRANSFER -> TransferScreen(
            viewModel = transferVM,
            onBack = { returnFromTransferToBrowse() },
            onClearDownloadCache = { transferVM.clearDownloadedCache() },
            onPauseDownloads = {
                transferVM.pauseTransfers {
                    returnFromTransferToBrowse()
                }
            },
        )
    }

    if (showsDisclaimer) {
        DisclaimerDialog(
            trialDays = trialDays,
            confirmText = "知道了",
            dismissText = "关闭",
            onConfirm = { showsDisclaimer = false },
            onDismiss = { showsDisclaimer = false },
        )
    }
    wiredError?.let { message ->
        AlertDialog(
            onDismissRequest = { wiredError = null },
            confirmButton = {
                Button(onClick = { wiredError = null }) {
                    Text("知道了")
                }
            },
            title = { Text("有线导入不可用") },
            text = { Text(message) },
        )
    }
}

internal object CameraScreenRoutePolicy {
    fun shouldOpenBrowseFromGalleryConnectionEvent(
        lastHandledGalleryConnectionEvent: Long,
        galleryConnectionEvent: Long,
        isReturningToConnect: Boolean,
        connectionState: ConnectionState,
        currentScreen: Screen,
    ): Boolean =
        galleryConnectionEvent > 0 &&
            galleryConnectionEvent != lastHandledGalleryConnectionEvent &&
            !isReturningToConnect &&
            connectionState == ConnectionState.CONNECTED &&
            currentScreen == Screen.CONNECT

    fun shouldReturnToConnect(
        isWiredImport: Boolean,
        hasActiveCameraSource: Boolean,
        connectionState: ConnectionState,
        currentScreen: Screen,
    ): Boolean {
        if (currentScreen == Screen.CONNECT) return false
        if (isWiredImport) return false
        if (hasActiveCameraSource && connectionState == ConnectionState.CONNECTED) return false
        return connectionState != ConnectionState.CONNECTED
    }

    fun screenAfterDownloadStarted(currentScreen: Screen): Screen =
        if (currentScreen == Screen.BROWSE) Screen.TRANSFER else currentScreen
}

@Composable
private fun TrialExpiredScreen(trialAccess: TrialAccess, trialDays: Long) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("内测版本已过期")
        Text("本内测包已于 ${trialAccess.expiresAt.asLocalTimeText()} 过期，请联系开发者获取新版本。")
        Text("本 App 为个人开发者独立内测版本，有效期 $trialDays 天，并非 FUJIFILM / 富士胶片官方应用。")
        Text("App 不需要联网服务器，不会上传、收集、分析或出售用户照片、视频等个人信息。")
        Image(
            painter = painterResource(id = R.drawable.contact_xiaohongshu),
            contentDescription = "开发者小红书联系方式",
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 420.dp),
            contentScale = ContentScale.FillWidth,
        )
    }
}

@Composable
private fun DisclaimerDialog(
    trialDays: Long,
    confirmText: String,
    dismissText: String?,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            Button(onClick = onConfirm) {
                Text(confirmText)
            }
        },
        dismissButton = dismissText?.let { text ->
            {
                TextButton(onClick = onDismiss) {
                    Text(text)
                }
            }
        },
        title = { Text("使用须知与免责声明") },
        text = {
            Column(
                modifier = Modifier
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                AppDisclaimerText.sections(trialDays).forEach { section ->
                    DisclaimerSectionView(section)
                }
            }
        },
    )
}

@Composable
private fun DisclaimerSectionView(section: AppDisclaimerSection) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            section.title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Black,
        )
        Text(
            highlightedDisclaimerBody(section),
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

private fun highlightedDisclaimerBody(section: AppDisclaimerSection) = buildAnnotatedString {
    val body = section.body
    var cursor = 0
    val matches = section.highlights
        .mapNotNull { phrase ->
            val index = body.indexOf(phrase)
            if (index >= 0) index to phrase else null
        }
        .sortedBy { it.first }

    for ((index, phrase) in matches) {
        if (index < cursor) continue
        append(body.substring(cursor, index))
        withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
            append(phrase)
        }
        cursor = index + phrase.length
    }
    if (cursor < body.length) append(body.substring(cursor))
}

private fun android.content.Context.hasAcceptedDisclaimer(): Boolean =
    getSharedPreferences(AppDisclaimerText.ACCEPTANCE_PREFS, android.content.Context.MODE_PRIVATE)
        .getBoolean(AppDisclaimerText.ACCEPTED_KEY, false)

private fun android.content.Context.markDisclaimerAccepted() {
    getSharedPreferences(AppDisclaimerText.ACCEPTANCE_PREFS, android.content.Context.MODE_PRIVATE)
        .edit()
        .putBoolean(AppDisclaimerText.ACCEPTED_KEY, true)
        .apply()
}

private fun trialDays(): Long = (BuildConfig.TRIAL_DURATION_MINUTES / 1_440L).coerceAtLeast(1L)

private fun java.time.Instant.asLocalTimeText(): String =
    DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
        .format(atZone(ZoneId.systemDefault()))

private const val EXTRA_DEBUG_ENTER_GALLERY = "camtransfer.debug.enter_gallery"
private const val DEBUG_ENTER_GALLERY_STARTUP_DELAY_MS = 9_000L

private fun MainActivity.shouldDebugEnterGallery(): Boolean =
    BuildConfig.DEBUG && intent.getBooleanExtra(EXTRA_DEBUG_ENTER_GALLERY, false)
