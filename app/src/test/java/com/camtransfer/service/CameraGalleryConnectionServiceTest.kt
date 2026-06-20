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
        val stepElapsed = mutableListOf<Long>()
        val executed = mutableListOf<String>()
        val service = CameraGalleryConnectionService(
            onStepStarted = started::add,
            onStepConfirmed = { step, elapsedMs ->
                confirmed += step
                stepElapsed += elapsedMs
            },
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
        assertEquals(CameraVendorOfficialGalleryConnectionPolicy.RequiredSteps.size, stepElapsed.size)
        assert(stepElapsed.all { it >= 0L })
        assertEquals(
            listOf("ble", "auth", "activate", "ready", "wifi", "ptp", "mode", "load"),
            executed,
        )
    }

    @Test
    fun connectionAdapterReportsPerStepElapsedTime() = runBlocking {
        val confirmed = mutableListOf<Pair<CameraConnectionStep, Long>>()
        val clockTicks = ArrayDeque(listOf(100L, 175L))
        val adapter = CameraVendorOfficialGalleryConnectionAdapter(
            onStepConfirmed = { step, elapsedMs -> confirmed += step to elapsedMs },
            elapsedRealtimeMs = { clockTicks.removeFirst() },
        )

        adapter.confirmStep(CameraConnectionStep.ReconnectPairedBle) { "ble" }

        assertEquals(listOf(CameraConnectionStep.ReconnectPairedBle to 75L), confirmed)
    }
}
