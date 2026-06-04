package com.camtransfer.viewmodel

import com.camtransfer.service.CameraConnectionStep

internal object CameraConnectionUiPolicy {
    fun stateForStep(step: CameraConnectionStep): ConnectionState =
        when (step) {
            CameraConnectionStep.EnvironmentCheck,
            CameraConnectionStep.StaleBondCheck,
            CameraConnectionStep.BleScan -> ConnectionState.SCANNING
            CameraConnectionStep.CameraPairingMode -> ConnectionState.IDLE
            CameraConnectionStep.BleHandshake,
            CameraConnectionStep.ReconnectPairedBle,
            CameraConnectionStep.TransferAuthorization,
            CameraConnectionStep.ActivateCameraWifi,
            CameraConnectionStep.WaitCameraWifiReady -> ConnectionState.CONNECTING_BLE
            CameraConnectionStep.PairingConfirmation -> ConnectionState.WAITING_CAMERA_CONFIRMATION
            CameraConnectionStep.SavePairing -> ConnectionState.PAIRED
            CameraConnectionStep.ExistingPtpProbe,
            CameraConnectionStep.ConnectPtp,
            CameraConnectionStep.LoadGallery -> ConnectionState.CONNECTING_PTP
            CameraConnectionStep.JoinCameraWifi -> ConnectionState.CONNECTING_WIFI
        }
}
