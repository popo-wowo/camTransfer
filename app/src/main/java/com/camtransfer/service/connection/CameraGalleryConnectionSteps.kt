package com.camtransfer.service.connection

import com.camtransfer.service.CameraConnectionStep

class ReconnectPairedBleStep(
    private val action: suspend () -> Unit,
) : CameraGalleryConnectionStepRunner<Unit, Unit> {
    override val step: CameraConnectionStep = CameraConnectionStep.ReconnectPairedBle

    override suspend fun run(input: Unit) {
        action()
    }
}

class TransferAuthorizationStep(
    private val action: suspend () -> Unit,
) : CameraGalleryConnectionStepRunner<Unit, Unit> {
    override val step: CameraConnectionStep = CameraConnectionStep.TransferAuthorization

    override suspend fun run(input: Unit) {
        action()
    }
}

class ActivateCameraWifiStep(
    private val action: suspend () -> Unit,
) : CameraGalleryConnectionStepRunner<Unit, Unit> {
    override val step: CameraConnectionStep = CameraConnectionStep.ActivateCameraWifi

    override suspend fun run(input: Unit) {
        action()
    }
}

class WaitCameraWifiReadyStep(
    private val action: suspend () -> Unit,
) : CameraGalleryConnectionStepRunner<Unit, Unit> {
    override val step: CameraConnectionStep = CameraConnectionStep.WaitCameraWifiReady

    override suspend fun run(input: Unit) {
        action()
    }
}

class JoinCameraWifiStep(
    private val action: suspend () -> Unit,
) : CameraGalleryConnectionStepRunner<Unit, Unit> {
    override val step: CameraConnectionStep = CameraConnectionStep.JoinCameraWifi

    override suspend fun run(input: Unit) {
        action()
    }
}

class ConnectPtpStep(
    private val action: suspend () -> Unit,
) : CameraGalleryConnectionStepRunner<Unit, Unit> {
    override val step: CameraConnectionStep = CameraConnectionStep.ConnectPtp

    override suspend fun run(input: Unit) {
        action()
    }
}

class ConfirmGalleryModeStep(
    private val action: suspend () -> Unit,
) : CameraGalleryConnectionStepRunner<Unit, Unit> {
    override val step: CameraConnectionStep = CameraConnectionStep.ConfirmGalleryMode

    override suspend fun run(input: Unit) {
        action()
    }
}

class LoadGalleryStep(
    private val action: suspend () -> Unit,
) : CameraGalleryConnectionStepRunner<Unit, Unit> {
    override val step: CameraConnectionStep = CameraConnectionStep.LoadGallery

    override suspend fun run(input: Unit) {
        action()
    }
}
