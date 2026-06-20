package com.camtransfer.service

import com.camtransfer.service.connection.ActivateCameraWifiStep
import com.camtransfer.service.connection.CameraGalleryConnectionStepRunner
import com.camtransfer.service.connection.ConfirmGalleryModeStep
import com.camtransfer.service.connection.ConnectPtpStep
import com.camtransfer.service.connection.JoinCameraWifiStep
import com.camtransfer.service.connection.LoadGalleryStep
import com.camtransfer.service.connection.ReconnectPairedBleStep
import com.camtransfer.service.connection.TransferAuthorizationStep
import com.camtransfer.service.connection.WaitCameraWifiReadyStep
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraGalleryConnectionStepRunnerPolicyTest {
    @Test
    fun everyOfficialGalleryConnectionStepHasAnIndependentRunner() {
        val runners = listOf(
            ReconnectPairedBleStep { Unit },
            TransferAuthorizationStep { Unit },
            ActivateCameraWifiStep { Unit },
            WaitCameraWifiReadyStep { Unit },
            JoinCameraWifiStep { Unit },
            ConnectPtpStep { Unit },
            ConfirmGalleryModeStep { Unit },
            LoadGalleryStep { Unit },
        )

        assertEquals(
            CameraVendorOfficialGalleryConnectionPolicy.RequiredSteps,
            runners.map { it.step },
        )
        assertEquals(
            runners.size,
            runners.map { it::class }.distinct().size,
        )
        assertTrue(runners.all { it is CameraGalleryConnectionStepRunner<*, *> })
    }

    @Test
    fun cameraServiceDelegatesGalleryConnectionToConnectionModule() {
        val serviceSource = listOf(
            java.io.File("src/main/java/com/camtransfer/service/CameraService.kt"),
            java.io.File("app/src/main/java/com/camtransfer/service/CameraService.kt"),
        ).first { it.exists() }.readText()

        assertTrue(serviceSource.contains("private val galleryConnectionCoordinator"))
        assertTrue(serviceSource.contains("galleryConnectionCoordinator.connectToGallery(onStatus, onStep)"))
        assertTrue(serviceSource.contains("CameraGalleryConnectionCoordinator"))
    }
}
