package com.camtransfer.viewmodel

import com.camtransfer.service.CameraConnectionStep
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraConnectionStatusPolicyTest {
    @Test
    fun guidedWifiIssueMapsToWifiState() {
        val state = CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.JoinCameraWifi)

        assertEquals(ConnectionState.CONNECTING_WIFI, state)
    }

    @Test
    fun pairingConfirmationStepMapsToWaitingConfirmation() {
        val state = CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.PairingConfirmation)

        assertEquals(ConnectionState.WAITING_CAMERA_CONFIRMATION, state)
    }

    @Test
    fun cameraPairingModeGateDoesNotShowScanningState() {
        val state = CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.CameraPairingMode)

        assertEquals(ConnectionState.IDLE, state)
    }

    @Test
    fun ptpStepMapsToPtpState() {
        val state = CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.ConnectPtp)

        assertEquals(ConnectionState.CONNECTING_PTP, state)
    }

    @Test
    fun galleryStatusRecognizesHumanWifiCopy() {
        val step = CameraConnectionStatusPolicy.galleryStep(
            status = "正在等待手机加入相机 Wi-Fi\n慢的时候通常是手机系统在切换网络",
            currentStep = CameraConnectionStep.ActivateCameraWifi,
        )

        assertEquals(CameraConnectionStep.JoinCameraWifi, step)
    }

    @Test
    fun rememberedBleReconnectStatusLeavesPairedIdleStateImmediately() {
        val state = CameraConnectionStatusPolicy.galleryState(
            status = "正在直连已配对相机: X-T5",
            currentState = ConnectionState.PAIRED,
        )

        assertEquals(ConnectionState.CONNECTING_BLE, state)
    }

    @Test
    fun rememberedBleReconnectStatusMapsToReconnectStep() {
        val step = CameraConnectionStatusPolicy.galleryStep(
            status = "正在用蓝牙查找已配对相机: X-T5",
            currentStep = CameraConnectionStep.ReconnectPairedBle,
        )

        assertEquals(CameraConnectionStep.ReconnectPairedBle, step)
    }

    @Test
    fun galleryStatusRecognizesAlbumChannelCopyAsPtpStep() {
        val step = CameraConnectionStatusPolicy.galleryStep(
            status = "正在打开相机相册通道 (1/5)",
            currentStep = CameraConnectionStep.JoinCameraWifi,
        )

        assertEquals(CameraConnectionStep.ConnectPtp, step)
    }

    @Test
    fun wifiJoinFailureRetriesWifiWithoutBleActivation() {
        val target = CameraConnectionRetryPolicy.targetForStep(CameraConnectionStep.JoinCameraWifi)

        assertEquals(CameraConnectionRetryTarget.WifiHandoffWithoutBle, target)
    }

    @Test
    fun ptpFailureRetriesPtpWithoutBleActivation() {
        val target = CameraConnectionRetryPolicy.targetForStep(CameraConnectionStep.ConnectPtp)

        assertEquals(CameraConnectionRetryTarget.ExistingPtpProbe, target)
    }
}
