package com.camtransfer.service.connection

import com.camtransfer.service.CameraConnectionStep
import com.camtransfer.service.CameraVendorOfficialGalleryConnectionAdapter

class CameraGalleryConnectionService(
    private val onStepStarted: (CameraConnectionStep) -> Unit = {},
    private val onStepConfirmed: (CameraConnectionStep, elapsedMs: Long) -> Unit = { _, _ -> },
) {
    suspend fun connect(
        reconnectPairedBle: ReconnectPairedBleStep,
        transferAuthorization: TransferAuthorizationStep,
        activateCameraWifi: ActivateCameraWifiStep,
        waitCameraWifiReady: WaitCameraWifiReadyStep,
        joinCameraWifi: JoinCameraWifiStep,
        connectPtp: ConnectPtpStep,
        confirmGalleryMode: ConfirmGalleryModeStep,
        loadGallery: LoadGalleryStep,
    ) {
        val adapter = CameraVendorOfficialGalleryConnectionAdapter(
            onStepStarted = onStepStarted,
            onStepConfirmed = onStepConfirmed,
        )
        val runners = listOf(
            reconnectPairedBle,
            transferAuthorization,
            activateCameraWifi,
            waitCameraWifiReady,
            joinCameraWifi,
            connectPtp,
            confirmGalleryMode,
            loadGallery,
        )
        for (runner in runners) {
            adapter.confirmStep(runner.step) {
                runner.run(Unit)
            }
        }
    }
}
