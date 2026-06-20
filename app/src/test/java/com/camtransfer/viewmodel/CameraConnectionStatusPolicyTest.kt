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
    fun staleRegistrationGatesDoNotShowScanningState() {
        assertEquals(ConnectionState.IDLE, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.StaleBondCheck))
        assertEquals(ConnectionState.IDLE, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.RegistrationConsistencyCheck))
    }

    @Test
    fun ptpStepMapsToPtpState() {
        val state = CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.ConnectPtp)

        assertEquals(ConnectionState.CONNECTING_PTP, state)
    }

    @Test
    fun officialGalleryStepsMapToExpectedUiStates() {
        assertEquals(ConnectionState.CONNECTING_BLE, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.ReconnectPairedBle))
        assertEquals(ConnectionState.CONNECTING_BLE, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.TransferAuthorization))
        assertEquals(ConnectionState.CONNECTING_BLE, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.ActivateCameraWifi))
        assertEquals(ConnectionState.CONNECTING_BLE, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.WaitCameraWifiReady))
        assertEquals(ConnectionState.CONNECTING_WIFI, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.JoinCameraWifi))
        assertEquals(ConnectionState.CONNECTING_PTP, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.ConnectPtp))
        assertEquals(ConnectionState.CONNECTING_PTP, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.ConfirmGalleryMode))
        assertEquals(ConnectionState.CONNECTING_PTP, CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.LoadGallery))
    }

    @Test
    fun wifiJoinFailureRetriesWifiHandoffWithoutBleReset() {
        val target = CameraConnectionRetryPolicy.targetForStep(CameraConnectionStep.JoinCameraWifi)

        assertEquals(CameraConnectionRetryTarget.WifiHandoffWithoutBle, target)
    }

    @Test
    fun ptpFailureRequiresFreshRegistrationReset() {
        val target = CameraConnectionRetryPolicy.targetForStep(CameraConnectionStep.ConnectPtp)

        assertEquals(CameraConnectionRetryTarget.ResetConnection, target)
    }
}
