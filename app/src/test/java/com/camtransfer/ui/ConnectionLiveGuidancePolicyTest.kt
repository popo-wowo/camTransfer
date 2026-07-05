package com.camtransfer.ui

import com.camtransfer.service.CameraConnectionAction
import com.camtransfer.service.CameraConnectionIssue
import com.camtransfer.service.CameraConnectionStep
import com.camtransfer.service.CameraVendorPairedCameraRecord
import com.camtransfer.wifi.CameraVendorWifiNetworkConfiguration
import com.camtransfer.viewmodel.ConnectionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectionLiveGuidancePolicyTest {
    @Test
    fun issueBecomesPrimaryLiveGuidance() {
        val issue = CameraConnectionIssue.cameraPairingModeRequired()

        val content = ConnectionLiveGuidancePolicy.content(
            state = ConnectionState.IDLE,
            statusText = "",
            error = null,
            issue = issue,
        )

        assertEquals(issue.title, content.title)
        assertEquals(issue.detail, content.message)
        assertEquals("请先确认", content.stepLabel)
        assertTrue(content.isProminent)
        assertFalse(content.isError)
    }

    @Test
    fun runningStatusUsesLargeLiveGuidance() {
        val content = ConnectionLiveGuidancePolicy.content(
            state = ConnectionState.CONNECTING_WIFI,
            statusText = "正在等待手机加入相机 Wi-Fi",
            error = null,
            issue = null,
        )

        assertEquals("正在处理", content.title)
        assertEquals("正在等待手机加入相机 Wi-Fi", content.message)
        assertEquals("实时提醒", content.stepLabel)
        assertTrue(content.isProminent)
    }

    @Test
    fun errorMessageBecomesPrimaryLiveGuidance() {
        val content = ConnectionLiveGuidancePolicy.content(
            state = ConnectionState.ERROR,
            statusText = "",
            error = "手机没有自动加入相机 Wi-Fi",
            issue = null,
        )

        assertEquals("需要处理", content.title)
        assertEquals("手机没有自动加入相机 Wi-Fi", content.message)
        assertTrue(content.isError)
    }

    @Test
    fun pairedStateDoesNotClaimFreshPairingSuccess() {
        val content = ConnectionLiveGuidancePolicy.content(
            state = ConnectionState.PAIRED,
            statusText = "已配对 X-T5",
            error = null,
            issue = null,
        )

        assertEquals("已保存配对", content.title)
        assertEquals("已配对 X-T5", content.message)
        assertEquals("下一步", content.stepLabel)
    }

    @Test
    fun pairedStateWithoutOnlineHandshakeStaysSavedNotConnected() {
        val content = ConnectionLiveGuidancePolicy.content(
            state = ConnectionState.PAIRED,
            statusText = "已保存配对，未连接相机: X-T5",
            error = null,
            issue = null,
        )

        assertEquals("已保存配对", content.title)
        assertEquals("已保存配对，未连接相机: X-T5", content.message)
        assertFalse(content.isBleOnline)
    }

    @Test
    fun pairedStateWithOnlineHandshakeShowsBluetoothConnected() {
        val content = ConnectionLiveGuidancePolicy.content(
            state = ConnectionState.PAIRED,
            statusText = "相机在线: X-T5",
            error = null,
            issue = null,
        )

        assertEquals("蓝牙已连接", content.title)
        assertEquals("蓝牙在线", content.stepLabel)
        assertTrue(content.isBleOnline)
    }

    @Test
    fun failureActionUsesResetForStaleSystemBond() {
        val issue = CameraConnectionIssue.staleSystemBond("X-T5")

        assertEquals(CameraConnectionAction.ResetConnection, ConnectionFailureActionPolicy.primaryAction(issue))
        assertEquals("重置连接", ConnectionFailureActionPolicy.primaryLabel(issue))
    }

    @Test
    fun failureActionUsesRestartPairingForNormalPairingGate() {
        val issue = CameraConnectionIssue.cameraPairingModeRequired()

        assertEquals(CameraConnectionAction.RestartPairing, ConnectionFailureActionPolicy.primaryAction(issue))
        assertEquals("重新配对", ConnectionFailureActionPolicy.primaryLabel(issue))
    }

    @Test
    fun failureActionUsesConnectionResetForPtpConflict() {
        val issue = CameraConnectionIssue.ptpNotReady()

        assertEquals(CameraConnectionAction.ResetConnection, ConnectionFailureActionPolicy.primaryAction(issue))
        assertEquals("重置连接", ConnectionFailureActionPolicy.primaryLabel(issue))
    }

    @Test
    fun pairedPtpIssueUsesConnectionResetAsPrimaryAction() {
        val issue = CameraConnectionIssue.ptpNotReady()

        assertEquals(CameraConnectionAction.ResetConnection, ConnectionPairedPrimaryActionPolicy.primaryAction(issue))
        assertEquals("重置连接", ConnectionPairedPrimaryActionPolicy.primaryLabel(issue))
    }

    @Test
    fun pairedGalleryIssueKeepsRetryAsPrimaryAction() {
        val issue = CameraConnectionIssue.wifiJoinTimeout(
            ssid = "FUJIFILM-X-T5-003B",
            passphrase = "12345678",
        )

        assertEquals(CameraConnectionAction.RetryStep, ConnectionPairedPrimaryActionPolicy.primaryAction(issue))
        assertEquals("重试", ConnectionPairedPrimaryActionPolicy.primaryLabel(issue))
    }

    @Test
    fun idlePairingScreenPutsActionsAndPreparationFirst() {
        assertFalse(ConnectionUiLayoutPolicy.actionsBeforeGuidance(ConnectionState.IDLE))
        assertTrue(ConnectionUiLayoutPolicy.shouldShowPairingPreparation(ConnectionState.IDLE))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(null))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowLiveGuidance(ConnectionState.IDLE, null, null))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowTransferSizeSelector(ConnectionState.IDLE))
    }

    @Test
    fun cameraConfirmationRemindersShowWhilePairingCamera() {
        assertFalse(ConnectionUiLayoutPolicy.shouldShowPairingPreparation(ConnectionState.ERROR))
        assertTrue(ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(CameraConnectionStep.BleScan))
        assertTrue(ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(CameraConnectionStep.BleHandshake))
        assertTrue(ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(CameraConnectionStep.PairingConfirmation))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(CameraConnectionStep.ReconnectPairedBle))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(CameraConnectionStep.TransferAuthorization))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(CameraConnectionStep.ActivateCameraWifi))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowBluetoothPairingSteps(CameraConnectionStep.JoinCameraWifi))
    }

    @Test
    fun transferSizeSelectorStaysHiddenOnHome() {
        assertFalse(ConnectionUiLayoutPolicy.shouldShowTransferSizeSelector(ConnectionState.SCANNING))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowTransferSizeSelector(ConnectionState.WAITING_CAMERA_CONFIRMATION))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowTransferSizeSelector(ConnectionState.PAIRED))
    }

    @Test
    fun galleryEntryModeSelectorShowsOnlyWhenPaired() {
        assertFalse(ConnectionUiLayoutPolicy.shouldShowGalleryEntryModeSelector(ConnectionState.IDLE))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowGalleryEntryModeSelector(ConnectionState.CONNECTING_WIFI))
        assertTrue(ConnectionUiLayoutPolicy.shouldShowGalleryEntryModeSelector(ConnectionState.PAIRED))
    }

    @Test
    fun pairedSupplementalActionsAreGroupedByIntentAndKeepDisclaimer() {
        assertEquals("接入方式", ConnectionSupplementalActionsPolicy.utilitySectionTitle())
        assertEquals("有线接入", ConnectionSupplementalActionsPolicy.wiredAccessLabel())
        assertEquals("辅助工具", ConnectionSupplementalActionsPolicy.auxiliarySectionTitle())
        assertEquals("诊断日志", ConnectionSupplementalActionsPolicy.diagnosticActionLabel())
        assertEquals("使用须知", ConnectionSupplementalActionsPolicy.disclaimerLabel())
        assertEquals(
            "免责声明：相机连接、Wi-Fi 切换和照片导入会根据设备状态执行。",
            ConnectionSupplementalActionsPolicy.disclaimerText(),
        )
        assertEquals(14, ConnectionSupplementalActionsPolicy.pairedActionsTopSpacingDp())
        assertTrue(ConnectionSupplementalActionsPolicy.shouldShowStableUtilitySection(ConnectionState.IDLE))
        assertTrue(ConnectionSupplementalActionsPolicy.shouldShowStableUtilitySection(ConnectionState.WAITING_CAMERA_CONFIRMATION))
        assertTrue(ConnectionSupplementalActionsPolicy.shouldShowStableUtilitySection(ConnectionState.CONNECTING_WIFI))
        assertTrue(ConnectionSupplementalActionsPolicy.shouldShowStableUtilitySection(ConnectionState.PAIRED))
    }

    @Test
    fun cameraIdentityUsesLocalDisplayNameWithoutChangingModelInitials() {
        val content = ConnectionCameraIdentityPolicy.content(
            camera = pairedCamera().copy(localDisplayName = "旅行机"),
            state = ConnectionState.PAIRED,
            statusText = "已配对 X-T5",
            error = null,
            issue = null,
            activeStep = CameraConnectionStep.SavePairing,
        )

        assertEquals("旅行机", content.displayName)
        assertEquals("X-T5", content.modelName)
        assertEquals("FUJIFILM X SERIES", content.seriesLabel)
        assertEquals("X-T5", content.avatarText)
        assertEquals("已配对", content.statusLabel)
        assertNull(content.statusDetail)
        assertEquals(CameraIdentityRingState.Neutral, content.ringState)
    }

    @Test
    fun cameraIdentityRingTracksBleConnectionState() {
        assertEquals(
            CameraIdentityRingState.Connecting,
            ConnectionCameraIdentityPolicy.content(
                camera = pairedCamera(),
                state = ConnectionState.CONNECTING_BLE,
                statusText = "正在直连已配对相机",
                error = null,
                issue = null,
                activeStep = CameraConnectionStep.ReconnectPairedBle,
            ).let { content ->
                assertEquals("连接中", content.statusLabel)
                assertEquals("正在直连已配对相机", content.statusDetail)
                content.ringState
            },
        )
        assertEquals(
            CameraIdentityRingState.BleOnline,
            ConnectionCameraIdentityPolicy.content(
                camera = pairedCamera(),
                state = ConnectionState.PAIRED,
                statusText = "相机在线: X-T5",
                error = null,
                issue = null,
                activeStep = CameraConnectionStep.SavePairing,
            ).let { content ->
                assertEquals("蓝牙在线", content.statusLabel)
                assertNull(content.statusDetail)
                content.ringState
            },
        )
        assertEquals(
            CameraIdentityRingState.Connecting,
            ConnectionCameraIdentityPolicy.content(
                camera = pairedCamera(),
                state = ConnectionState.CONNECTING_PTP,
                statusText = "正在连接相机相册",
                error = null,
                issue = null,
                activeStep = CameraConnectionStep.ConnectPtp,
            ).let { content ->
                assertEquals("连接中", content.statusLabel)
                assertEquals("正在连接相机相册", content.statusDetail)
                content.ringState
            },
        )
    }

    @Test
    fun cameraIdentityKeepsDetailedWifiAndFailureGuidanceInsideSingleCard() {
        assertEquals(
            "正在等待手机加入相机 Wi-Fi",
            ConnectionCameraIdentityPolicy.content(
                camera = pairedCamera(),
                state = ConnectionState.CONNECTING_WIFI,
                statusText = "正在等待手机加入相机 Wi-Fi",
                error = null,
                issue = null,
                activeStep = CameraConnectionStep.JoinCameraWifi,
            ).statusDetail,
        )

        val issue = CameraConnectionIssue.wifiJoinTimeout(
            ssid = "FUJIFILM-X-T5-0001",
            passphrase = "12345678",
        )
        val content = ConnectionCameraIdentityPolicy.content(
            camera = pairedCamera(),
            state = ConnectionState.ERROR,
            statusText = "",
            error = null,
            issue = issue,
            activeStep = issue.step,
        )

        assertEquals(issue.title, content.statusLabel)
        assertEquals(issue.detail, content.statusDetail)
    }

    private fun pairedCamera(): CameraVendorPairedCameraRecord =
        CameraVendorPairedCameraRecord(
            deviceName = "X-T5",
            serialNumber = "123456",
            wifiConfigurations = listOf(CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-0001", "12345678", false)),
            bluetoothAddress = "AA:BB:CC:DD:EE:FF",
            cameraId = "123456_X-T5",
        )
}
