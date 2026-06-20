package com.camtransfer.service

import com.camtransfer.service.connection.ActivateCameraWifiStep
import com.camtransfer.service.connection.CameraGalleryConnectionService
import com.camtransfer.service.connection.ConfirmGalleryModeStep
import com.camtransfer.service.connection.ConnectPtpStep
import com.camtransfer.service.connection.JoinCameraWifiStep
import com.camtransfer.service.connection.LoadGalleryStep
import com.camtransfer.service.connection.ReconnectPairedBleStep
import com.camtransfer.service.connection.TransferAuthorizationStep
import com.camtransfer.service.connection.WaitCameraWifiReadyStep
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraGalleryConnectionServiceTest {
    @Test
    fun connectionServiceRunsIndependentStepsInOfficialOrder() = runBlocking {
        val started = mutableListOf<CameraConnectionStep>()
        val confirmed = mutableListOf<CameraConnectionStep>()
        val executed = mutableListOf<String>()
        val service = CameraGalleryConnectionService(
            onStepStarted = started::add,
            onStepConfirmed = confirmed::add,
        )

        service.connect(
            reconnectPairedBle = ReconnectPairedBleStep { executed += "ble" },
            transferAuthorization = TransferAuthorizationStep { executed += "auth" },
            activateCameraWifi = ActivateCameraWifiStep { executed += "activate" },
            waitCameraWifiReady = WaitCameraWifiReadyStep { executed += "ready" },
            joinCameraWifi = JoinCameraWifiStep { executed += "wifi" },
            connectPtp = ConnectPtpStep { executed += "ptp" },
            confirmGalleryMode = ConfirmGalleryModeStep { executed += "mode" },
            loadGallery = LoadGalleryStep { executed += "load" },
        )

        assertEquals(CameraVendorOfficialGalleryConnectionPolicy.RequiredSteps, started)
        assertEquals(CameraVendorOfficialGalleryConnectionPolicy.RequiredSteps, confirmed)
        assertEquals(
            listOf("ble", "auth", "activate", "ready", "wifi", "ptp", "mode", "load"),
            executed,
        )
    }
}
