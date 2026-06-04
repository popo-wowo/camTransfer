package com.camtransfer.ui

import com.camtransfer.service.CameraConnectionAction
import com.camtransfer.service.CameraConnectionIssue
import com.camtransfer.service.CameraConnectionStep
import com.camtransfer.viewmodel.ConnectionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun failureActionUsesRestartPairingForPairingPhase() {
        val issue = CameraConnectionIssue.staleSystemBond("X-T5")

        assertEquals(CameraConnectionAction.RestartPairing, ConnectionFailureActionPolicy.primaryAction(issue))
        assertEquals("重新配对", ConnectionFailureActionPolicy.primaryLabel(issue))
    }

    @Test
    fun failureActionUsesRetryForGalleryPhase() {
        val issue = CameraConnectionIssue.ptpNotReady()

        assertEquals(CameraConnectionAction.RetryStep, ConnectionFailureActionPolicy.primaryAction(issue))
        assertEquals("重试", ConnectionFailureActionPolicy.primaryLabel(issue))
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
    fun transferSizeOnlyShowsAfterPairing() {
        assertFalse(ConnectionUiLayoutPolicy.shouldShowTransferSizeSelector(ConnectionState.SCANNING))
        assertFalse(ConnectionUiLayoutPolicy.shouldShowTransferSizeSelector(ConnectionState.WAITING_CAMERA_CONFIRMATION))
        assertTrue(ConnectionUiLayoutPolicy.shouldShowTransferSizeSelector(ConnectionState.PAIRED))
    }
}
