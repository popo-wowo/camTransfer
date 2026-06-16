package com.camtransfer.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import com.camtransfer.protocol.CameraVendorPtpConnectionStartupPolicy
import kotlinx.coroutines.runBlocking
import org.junit.Test

class CameraConnectionFlowTest {
    @Test
    fun officialGalleryConnectionStepsFollowConfirmedProtocolOrder() {
        assertEquals(
            listOf(
                CameraConnectionStep.ReconnectPairedBle,
                CameraConnectionStep.TransferAuthorization,
                CameraConnectionStep.ActivateCameraWifi,
                CameraConnectionStep.WaitCameraWifiReady,
                CameraConnectionStep.JoinCameraWifi,
                CameraConnectionStep.ConnectPtp,
                CameraConnectionStep.ConfirmGalleryMode,
                CameraConnectionStep.LoadGallery,
            ),
            CameraVendorOfficialGalleryConnectionPolicy.RequiredSteps,
        )
    }

    @Test
    fun officialGalleryConnectionCannotSkipRequiredConfirmedSteps() {
        val completed = listOf(CameraConnectionStep.ReconnectPairedBle)

        assertTrue(
            CameraVendorOfficialGalleryConnectionPolicy.canRunStep(
                CameraConnectionStep.TransferAuthorization,
                completed,
            )
        )
        assertFalse(
            CameraVendorOfficialGalleryConnectionPolicy.canRunStep(
                CameraConnectionStep.JoinCameraWifi,
                completed,
            )
        )
    }

    @Test
    fun officialGalleryConnectionWaitsForPtpServiceBeforeOpeningAlbumChannel() {
        assertEquals(
            CameraVendorPtpConnectionStartupPolicy.STARTUP_DELAY_MS,
            CameraVendorOfficialGalleryConnectionPolicy.delayBeforeStepMs(CameraConnectionStep.ConnectPtp),
        )
        assertEquals(0L, CameraVendorOfficialGalleryConnectionPolicy.delayBeforeStepMs(CameraConnectionStep.JoinCameraWifi))
    }

    @Test
    fun officialGalleryConnectionAdapterRecordsOnlySuccessfulSteps() = runBlocking {
        val adapter = CameraVendorOfficialGalleryConnectionAdapter()
        adapter.confirmStep(CameraConnectionStep.ReconnectPairedBle) { "ble" }

        runCatching {
            adapter.confirmStep(CameraConnectionStep.ActivateCameraWifi) { "wifi" }
        }

        assertEquals(listOf(CameraConnectionStep.ReconnectPairedBle), adapter.confirmedSteps())
    }

    @Test
    fun pairingAckIssueBlocksGalleryEntry() {
        val issue = CameraConnectionIssue.pairingAckPending()

        assertEquals(CameraConnectionPhase.PAIR_CAMERA, issue.phase)
        assertEquals(CameraConnectionStep.PairingConfirmation, issue.step)
        assertFalse(issue.allowedActions.contains(CameraConnectionAction.EnterGallery))
        assertTrue(issue.allowedActions.contains(CameraConnectionAction.ConfirmCameraReady))
    }

    @Test
    fun cameraPairingModeIssueRequiresUserConfirmationBeforeScanning() {
        val issue = CameraConnectionIssue.cameraPairingModeRequired()

        assertEquals(CameraConnectionPhase.PAIR_CAMERA, issue.phase)
        assertEquals(CameraConnectionStep.CameraPairingMode, issue.step)
        assertEquals(CameraConnectionFailure.CameraNotInPairingMode, issue.failure)
        assertTrue(issue.title.contains("两件事"))
        assertTrue(issue.detail.contains("1."))
        assertTrue(issue.detail.contains("2."))
        assertTrue(issue.detail.contains("删除旧蓝牙"))
        assertTrue(issue.allowedActions.contains(CameraConnectionAction.ConfirmCameraPairingMode))
        assertFalse(issue.allowedActions.contains(CameraConnectionAction.EnterGallery))
    }

    @Test
    fun pairingAckIssueTellsUserToConfirmOnCameraScreen() {
        val issue = CameraConnectionIssue.pairingAckPending()

        assertTrue(issue.detail.contains("相机屏幕"))
        assertTrue(issue.detail.contains("OK"))
        assertTrue(issue.detail.contains("确定"))
    }

    @Test
    fun wifiTimeoutSwitchesAutoFlowToGuidedModeAtWifiStep() {
        val transition = CameraConnectionFlowPolicy.onFailure(
            mode = CameraConnectionMode.AUTO,
            step = CameraConnectionStep.JoinCameraWifi,
            failure = CameraConnectionFailure.WifiJoinTimeout,
            attempt = 2,
        )

        assertEquals(CameraConnectionMode.GUIDED, transition.mode)
        assertEquals(CameraConnectionStep.JoinCameraWifi, transition.step)
        assertEquals(CameraConnectionFailure.WifiJoinTimeout, transition.issue.failure)
        assertTrue(transition.issue.detail.contains("手机系统"))
        assertTrue(transition.issue.detail.contains("不能上网"))
    }

    @Test
    fun wifiJoinStatusShowsTargetSsid() {
        val status = CameraWifiJoinStatusPolicy.waitingForWifiJoin(
            ssid = "FUJIFILM-X-T5-003B",
            attempt = 1,
            total = 1,
        )

        assertTrue(status.contains("FUJIFILM-X-T5-003B"))
        assertTrue(status.contains("手机系统"))
    }

    @Test
    fun wifiTimeoutIssueKeepsManualWifiCredentials() {
        val issue = CameraConnectionIssueClassifier.fromThrowable(
            step = CameraConnectionStep.JoinCameraWifi,
            throwable = IllegalStateException(
                "手机没有自动加入相机 Wi-Fi，请手动加入后重试。\n" +
                    "SSID: FUJIFILM-X-T5-003B\n" +
                    "密码: abcdefgh1234567890\n" +
                    "这是隐藏网络，请在 Wi-Fi 的“其他网络”里手动输入。",
            ),
        )

        assertEquals(CameraConnectionFailure.WifiJoinTimeout, issue.failure)
        assertEquals("FUJIFILM-X-T5-003B", issue.wifiSsid)
        assertEquals("abcdefgh1234567890", issue.wifiPassphrase)
        assertTrue(issue.detail.contains("FUJIFILM-X-T5-003B"))
        assertTrue(issue.detail.contains("abcdefgh1234567890"))
    }

    @Test
    fun ptpTimeoutStaysInGalleryPhaseAndDoesNotRestartPairing() {
        val issue = CameraConnectionIssue.ptpNotReady()

        assertEquals(CameraConnectionPhase.ENTER_GALLERY, issue.phase)
        assertEquals(CameraConnectionStep.ConnectPtp, issue.step)
        assertFalse(issue.allowedActions.contains(CameraConnectionAction.RestartPairing))
        assertTrue(issue.allowedActions.contains(CameraConnectionAction.RetryStep))
    }

    @Test
    fun staleSystemBondErrorClassifiesAsPairingGate() {
        val issue = CameraConnectionIssueClassifier.fromThrowable(
            step = CameraConnectionStep.StaleBondCheck,
            throwable = IllegalStateException("手机系统里还保留着 X-H2 的蓝牙配对记录。"),
        )

        assertEquals(CameraConnectionFailure.StaleSystemBond, issue.failure)
        assertEquals(CameraConnectionStep.StaleBondCheck, issue.step)
    }

    @Test
    fun wifiTimeoutClassifiesAsJoinWifiIssue() {
        val issue = CameraConnectionIssueClassifier.fromThrowable(
            step = CameraConnectionStep.JoinCameraWifi,
            throwable = IllegalStateException("自动连接相机 WiFi 失败，请手动加入后重试。"),
        )

        assertEquals(CameraConnectionFailure.WifiJoinTimeout, issue.failure)
        assertEquals(CameraConnectionStep.JoinCameraWifi, issue.step)
    }

    @Test
    fun notConnectedToCameraWhileLoadingGalleryClassifiesAsGalleryLoadFailure() {
        val issue = CameraConnectionIssueClassifier.fromThrowable(
            step = CameraConnectionStep.LoadGallery,
            throwable = IllegalStateException("Not connected to camera"),
        )

        assertEquals(CameraConnectionFailure.GalleryLoadFailed, issue.failure)
        assertEquals(CameraConnectionStep.LoadGallery, issue.step)
    }
}
