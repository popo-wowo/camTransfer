package com.camtransfer.service

import com.camtransfer.protocol.CameraVendorPtpConnectionStartupPolicy
import com.camtransfer.wifi.CameraVendorWifiNetworkConfiguration
import com.camtransfer.wifi.CameraVendorWifiNetworkConfigurationPolicy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException

enum class CameraConnectionPhase {
    PAIR_CAMERA,
    ENTER_GALLERY,
}

enum class CameraConnectionMode {
    AUTO,
    GUIDED,
}

enum class CameraConnectionStep(val phase: CameraConnectionPhase) {
    EnvironmentCheck(CameraConnectionPhase.PAIR_CAMERA),
    StaleBondCheck(CameraConnectionPhase.PAIR_CAMERA),
    CameraPairingMode(CameraConnectionPhase.PAIR_CAMERA),
    BleScan(CameraConnectionPhase.PAIR_CAMERA),
    BleHandshake(CameraConnectionPhase.PAIR_CAMERA),
    PairingConfirmation(CameraConnectionPhase.PAIR_CAMERA),
    SavePairing(CameraConnectionPhase.PAIR_CAMERA),
    ExistingPtpProbe(CameraConnectionPhase.ENTER_GALLERY),
    ReconnectPairedBle(CameraConnectionPhase.ENTER_GALLERY),
    TransferAuthorization(CameraConnectionPhase.ENTER_GALLERY),
    ActivateCameraWifi(CameraConnectionPhase.ENTER_GALLERY),
    WaitCameraWifiReady(CameraConnectionPhase.ENTER_GALLERY),
    JoinCameraWifi(CameraConnectionPhase.ENTER_GALLERY),
    ConnectPtp(CameraConnectionPhase.ENTER_GALLERY),
    ConfirmGalleryMode(CameraConnectionPhase.ENTER_GALLERY),
    LoadGallery(CameraConnectionPhase.ENTER_GALLERY),
}

enum class CameraConnectionAction {
    RetryStep,
    RestartPairing,
    EnterGallery,
    ConfirmCameraPairingMode,
    ConfirmCameraReady,
    ConfirmWifiJoined,
    OpenSystemBluetoothSettings,
    ExportDiagnosticLog,
}

enum class CameraConnectionFailure {
    MissingPermission,
    StaleSystemBond,
    CameraNotInPairingMode,
    BleScanTimeout,
    GattDisconnected,
    PairingAckPending,
    WifiJoinTimeout,
    PtpNotReady,
    GalleryLoadFailed,
    Unknown,
}

data class CameraConnectionIssue(
    val phase: CameraConnectionPhase,
    val step: CameraConnectionStep,
    val failure: CameraConnectionFailure,
    val title: String,
    val detail: String,
    val primaryAction: CameraConnectionAction,
    val secondaryAction: CameraConnectionAction? = CameraConnectionAction.ExportDiagnosticLog,
    val wifiSsid: String? = null,
    val wifiPassphrase: String? = null,
    val allowedActions: Set<CameraConnectionAction> = setOf(primaryAction) +
        setOfNotNull(secondaryAction),
) {
    companion object {
        fun cameraPairingModeRequired(): CameraConnectionIssue =
            CameraConnectionIssue(
                phase = CameraConnectionPhase.PAIR_CAMERA,
                step = CameraConnectionStep.CameraPairingMode,
                failure = CameraConnectionFailure.CameraNotInPairingMode,
                title = "配对前先确认两件事",
                detail = "1. 相机已经停在“配对注册 / PAIRING REGISTRATION”界面。\n" +
                    "2. 如果这台相机以前配过，请先到手机系统蓝牙里删除旧蓝牙记录，再回到 App。",
                primaryAction = CameraConnectionAction.ConfirmCameraPairingMode,
                secondaryAction = CameraConnectionAction.ExportDiagnosticLog,
            )

        fun staleSystemBond(cameraName: String? = null): CameraConnectionIssue =
            CameraConnectionIssue(
                phase = CameraConnectionPhase.PAIR_CAMERA,
                step = CameraConnectionStep.StaleBondCheck,
                failure = CameraConnectionFailure.StaleSystemBond,
                title = "需要清理旧蓝牙配对",
                detail = "手机系统里还保留${cameraName?.let { " $it " } ?: "这台相机"}的旧蓝牙配对记录。\n" +
                    "请到 系统设置 > 蓝牙，找到这台相机，点“取消配对/忽略此设备”。删完后回到 App 继续。",
                primaryAction = CameraConnectionAction.OpenSystemBluetoothSettings,
                secondaryAction = CameraConnectionAction.RetryStep,
            )

        fun pairingAckPending(): CameraConnectionIssue =
            CameraConnectionIssue(
                phase = CameraConnectionPhase.PAIR_CAMERA,
                step = CameraConnectionStep.PairingConfirmation,
                failure = CameraConnectionFailure.PairingAckPending,
                title = "等待相机完成配对确认",
                detail = "App 已把配对信息发给相机。\n" +
                    "请看相机屏幕：如果出现确认、OK 或配对完成提示，请在相机上按 OK/确定。看到相机显示配对成功后，再点下面按钮继续。",
                primaryAction = CameraConnectionAction.ConfirmCameraReady,
                secondaryAction = CameraConnectionAction.RetryStep,
            )

        fun wifiJoinTimeout(
            ssid: String? = null,
            passphrase: String? = null,
        ): CameraConnectionIssue {
            val credentialDetail = if (!ssid.isNullOrBlank() || !passphrase.isNullOrBlank()) {
                "\n\n手动连接信息：\n" +
                    "Wi-Fi 名称：${ssid.orEmpty()}\n" +
                    "密码：${passphrase.orEmpty()}"
            } else {
                ""
            }
            return CameraConnectionIssue(
                phase = CameraConnectionPhase.ENTER_GALLERY,
                step = CameraConnectionStep.JoinCameraWifi,
                failure = CameraConnectionFailure.WifiJoinTimeout,
                title = "没有自动加入相机 WiFi",
                detail = "手机系统没有在预期时间内切到相机 Wi-Fi。\n" +
                    "如果系统弹出“是否连接这个 Wi-Fi”，请点连接；这个 Wi-Fi 不能上网是正常的。也可以先到系统 Wi-Fi 里手动连接相机网络，再回到这里继续。" +
                    credentialDetail,
                primaryAction = CameraConnectionAction.ConfirmWifiJoined,
                secondaryAction = CameraConnectionAction.RetryStep,
                wifiSsid = ssid?.takeIf { it.isNotBlank() },
                wifiPassphrase = passphrase?.takeIf { it.isNotBlank() },
            )
        }

        fun ptpNotReady(): CameraConnectionIssue =
            CameraConnectionIssue(
                phase = CameraConnectionPhase.ENTER_GALLERY,
                step = CameraConnectionStep.ConnectPtp,
                failure = CameraConnectionFailure.PtpNotReady,
                title = "相册服务还没准备好",
                detail = "手机已经完成蓝牙授权并连到相机 Wi-Fi，但相机的 PTP 相册通道没有接受连接。\n" +
                    "这不是重新配对能解决的问题。请让相机退出并重新进入传图/相册模式；如果仍失败，重启相机后再重试。",
                primaryAction = CameraConnectionAction.RetryStep,
                secondaryAction = CameraConnectionAction.ExportDiagnosticLog,
            )

        fun galleryLoadFailed(): CameraConnectionIssue =
            CameraConnectionIssue(
                phase = CameraConnectionPhase.ENTER_GALLERY,
                step = CameraConnectionStep.LoadGallery,
                failure = CameraConnectionFailure.GalleryLoadFailed,
                title = "相册列表读取失败",
                detail = "已经进入相册通道，但照片列表没有成功返回。\n" +
                    "请确认相机没有退出传图/相册界面，然后重试。",
                primaryAction = CameraConnectionAction.RetryStep,
                secondaryAction = CameraConnectionAction.ExportDiagnosticLog,
            )

        fun unknown(step: CameraConnectionStep, message: String): CameraConnectionIssue =
            CameraConnectionIssue(
                phase = step.phase,
                step = step,
                failure = CameraConnectionFailure.Unknown,
                title = "连接步骤没有完成",
                detail = message,
                primaryAction = CameraConnectionAction.RetryStep,
                secondaryAction = CameraConnectionAction.ExportDiagnosticLog,
            )
    }
}

data class CameraConnectionTransition(
    val mode: CameraConnectionMode,
    val step: CameraConnectionStep,
    val issue: CameraConnectionIssue,
)

object CameraConnectionFlowPolicy {
    fun onFailure(
        mode: CameraConnectionMode,
        step: CameraConnectionStep,
        failure: CameraConnectionFailure,
        attempt: Int,
    ): CameraConnectionTransition {
        val nextMode = if (shouldSwitchToGuided(mode, failure, attempt)) {
            CameraConnectionMode.GUIDED
        } else {
            mode
        }
        return CameraConnectionTransition(
            mode = nextMode,
            step = step,
            issue = issueFor(step, failure),
        )
    }

    fun issueFor(step: CameraConnectionStep, failure: CameraConnectionFailure): CameraConnectionIssue =
        when (failure) {
            CameraConnectionFailure.StaleSystemBond -> CameraConnectionIssue.staleSystemBond()
            CameraConnectionFailure.PairingAckPending -> CameraConnectionIssue.pairingAckPending()
            CameraConnectionFailure.WifiJoinTimeout -> CameraConnectionIssue.wifiJoinTimeout()
            CameraConnectionFailure.PtpNotReady -> CameraConnectionIssue.ptpNotReady()
            CameraConnectionFailure.GalleryLoadFailed -> CameraConnectionIssue.galleryLoadFailed()
            else -> CameraConnectionIssue.unknown(step, defaultDetail(failure))
        }

    private fun shouldSwitchToGuided(
        mode: CameraConnectionMode,
        failure: CameraConnectionFailure,
        attempt: Int,
    ): Boolean {
        if (mode == CameraConnectionMode.GUIDED) return true
        if (failure in userActionRequiredFailures) return true
        return attempt >= 2
    }

    private fun defaultDetail(failure: CameraConnectionFailure): String =
        when (failure) {
            CameraConnectionFailure.MissingPermission -> "缺少连接相机需要的系统权限。"
            CameraConnectionFailure.CameraNotInPairingMode -> "没有扫描到相机。请确认相机停留在配对注册界面；如果以前配过，也请先删除手机系统里的旧蓝牙记录。"
            CameraConnectionFailure.BleScanTimeout -> "搜索相机超时。请让相机继续停在配对注册界面，并把手机靠近相机后重试。"
            CameraConnectionFailure.GattDisconnected -> "蓝牙连接中断。请保持相机在当前确认界面，如果相机提示 OK/确定，也请先在相机上确认。"
            else -> "当前步骤失败，请重试或导出诊断日志。"
        }

    private val userActionRequiredFailures = setOf(
        CameraConnectionFailure.MissingPermission,
        CameraConnectionFailure.StaleSystemBond,
        CameraConnectionFailure.CameraNotInPairingMode,
        CameraConnectionFailure.PairingAckPending,
        CameraConnectionFailure.WifiJoinTimeout,
    )
}

object CameraConnectionCancellationPolicy {
    fun shouldPropagate(error: Throwable): Boolean =
        error is CancellationException && error !is TimeoutCancellationException
}

object CameraConnectionIssueClassifier {
    fun fromThrowable(
        step: CameraConnectionStep,
        throwable: Throwable,
    ): CameraConnectionIssue {
        val message = throwable.message.orEmpty()
        val fullMessage = throwable.fullMessage()
        val failure = when {
            fullMessage.contains("还保留着") && fullMessage.contains("蓝牙配对记录") ->
                CameraConnectionFailure.StaleSystemBond
            fullMessage.contains("相机端还没有完成识别号 ACK") ||
                fullMessage.contains("请先完成蓝牙配对") ->
                CameraConnectionFailure.PairingAckPending
            fullMessage.contains("自动连接相机 WiFi 失败") ||
                fullMessage.contains("手机没有自动加入相机 Wi-Fi") ||
                (step == CameraConnectionStep.JoinCameraWifi && fullMessage.contains("Timed out waiting")) ->
                CameraConnectionFailure.WifiJoinTimeout
            step == CameraConnectionStep.ConnectPtp ||
                fullMessage.contains("PTP 连接失败") ||
                fullMessage.contains("failed to connect to /192.168.0.1") ->
                CameraConnectionFailure.PtpNotReady
            step == CameraConnectionStep.LoadGallery ||
                message.contains("Not connected to camera") ->
                CameraConnectionFailure.GalleryLoadFailed
            fullMessage.contains("GATT disconnected") || fullMessage.contains("蓝牙断开") ->
                CameraConnectionFailure.GattDisconnected
            else -> CameraConnectionFailure.Unknown
        }
        return when (failure) {
            CameraConnectionFailure.StaleSystemBond -> CameraConnectionIssue.staleSystemBond()
            CameraConnectionFailure.PairingAckPending -> CameraConnectionIssue.pairingAckPending()
            CameraConnectionFailure.WifiJoinTimeout -> {
                val credentials = ManualWifiCredentialParser.parse(fullMessage)
                CameraConnectionIssue.wifiJoinTimeout(
                    ssid = credentials?.ssid,
                    passphrase = credentials?.passphrase,
                )
            }
            CameraConnectionFailure.PtpNotReady -> CameraConnectionIssue.ptpNotReady()
            CameraConnectionFailure.GalleryLoadFailed -> CameraConnectionIssue.galleryLoadFailed()
            else -> CameraConnectionFlowPolicy.issueFor(step, failure)
        }
    }

    private fun Throwable.fullMessage(): String =
        generateSequence(this) { it.cause }
            .joinToString(separator = "\n") { cause ->
                listOfNotNull(cause::class.qualifiedName, cause.message)
                    .joinToString(separator = ": ")
            }
}

data class ManualWifiCredential(
    val ssid: String,
    val passphrase: String,
)

object ManualWifiCredentialParser {
    private val ssidRegex = Regex("""(?im)^\s*SSID\s*[:：]\s*(.+?)\s*$""")
    private val passphraseRegex = Regex("""(?im)^\s*(密码|passphrase|password)\s*[:：]\s*(.+?)\s*$""")

    fun parse(text: String): ManualWifiCredential? {
        val ssid = ssidRegex.find(text)?.groupValues?.getOrNull(1)?.trim().orEmpty()
        val passphrase = passphraseRegex.find(text)?.groupValues?.getOrNull(2)?.trim().orEmpty()
        if (ssid.isBlank() || passphrase.isBlank()) return null
        return ManualWifiCredential(ssid = ssid, passphrase = passphrase)
    }
}

object CameraWifiJoinStatusPolicy {
    fun waitingForWifiJoin(
        ssid: String,
        attempt: Int,
        total: Int,
    ): String =
        "正在等待手机加入相机 Wi-Fi：$ssid ($attempt/$total)\n" +
            "慢的时候通常是手机系统在切换网络；如果弹出连接确认，请点连接。"
}

object CameraVendorOfficialGalleryConnectionPolicy {
    val RequiredSteps = listOf(
        CameraConnectionStep.ReconnectPairedBle,
        CameraConnectionStep.TransferAuthorization,
        CameraConnectionStep.ActivateCameraWifi,
        CameraConnectionStep.WaitCameraWifiReady,
        CameraConnectionStep.JoinCameraWifi,
        CameraConnectionStep.ConnectPtp,
        CameraConnectionStep.ConfirmGalleryMode,
        CameraConnectionStep.LoadGallery,
    )

    fun nextStep(completedSteps: List<CameraConnectionStep>): CameraConnectionStep? {
        require(isConfirmedPrefix(completedSteps)) {
            "Official gallery connection steps are out of order: $completedSteps"
        }
        return RequiredSteps.getOrNull(completedSteps.size)
    }

    fun canRunStep(
        step: CameraConnectionStep,
        completedSteps: List<CameraConnectionStep>,
    ): Boolean = nextStep(completedSteps) == step

    fun isComplete(completedSteps: List<CameraConnectionStep>): Boolean =
        completedSteps == RequiredSteps

    fun delayBeforeStepMs(step: CameraConnectionStep): Long =
        when (step) {
            CameraConnectionStep.ConnectPtp -> CameraVendorPtpConnectionStartupPolicy.STARTUP_DELAY_MS
            else -> 0L
        }

    fun officialWifiConfigurations(
        officialWifiConfiguration: CameraVendorWifiNetworkConfiguration?,
    ): List<CameraVendorWifiNetworkConfiguration> =
        CameraVendorWifiNetworkConfigurationPolicy.configurations(
            deviceName = null,
            serialNumber = null,
            preferredWifiNetwork = officialWifiConfiguration,
        ).ifEmpty {
            throw IllegalStateException("相机没有返回本次官方 Wi-Fi 名称和密码，已停止进入相册")
        }

    private fun isConfirmedPrefix(completedSteps: List<CameraConnectionStep>): Boolean =
        completedSteps == RequiredSteps.take(completedSteps.size)
}

class CameraVendorOfficialGalleryConnectionAdapter(
    private val onStepStarted: (CameraConnectionStep) -> Unit = {},
    private val onStepConfirmed: (CameraConnectionStep) -> Unit = {},
) {
    private val completedSteps = mutableListOf<CameraConnectionStep>()

    suspend fun <T> confirmStep(
        step: CameraConnectionStep,
        action: suspend () -> T,
    ): T {
        check(CameraVendorOfficialGalleryConnectionPolicy.canRunStep(step, completedSteps)) {
            "Cannot run $step before ${CameraVendorOfficialGalleryConnectionPolicy.nextStep(completedSteps)}"
        }
        onStepStarted(step)
        val result = action()
        completedSteps += step
        onStepConfirmed(step)
        return result
    }

    fun confirmedSteps(): List<CameraConnectionStep> = completedSteps.toList()
}
