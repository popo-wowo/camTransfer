package com.camtransfer.service

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class CameraPairingServiceArchitectureTest {
    @Test
    fun pairingFlowLivesInPairingModule() {
        val pairingSource = listOf(
            File("src/main/java/com/camtransfer/service/pairing/CameraPairingService.kt"),
            File("app/src/main/java/com/camtransfer/service/pairing/CameraPairingService.kt"),
        ).first { it.exists() }.readText()

        assertTrue(pairingSource.contains("class CameraPairingService"))
        assertTrue(pairingSource.contains("suspend fun pairWithCamera"))
        assertTrue(pairingSource.contains("suspend fun confirmPairing"))
        assertTrue(pairingSource.contains("ensureNoStaleSystemBondBeforeFreshPairing"))
        assertTrue(pairingSource.contains("pairingStore.save"))
    }

    @Test
    fun cameraServiceDelegatesPairingToPairingModule() {
        val serviceSource = listOf(
            File("src/main/java/com/camtransfer/service/CameraService.kt"),
            File("app/src/main/java/com/camtransfer/service/CameraService.kt"),
        ).first { it.exists() }.readText()

        assertTrue(serviceSource.contains("private val pairingService"))
        assertTrue(serviceSource.contains("pairingService.pairWithCamera(onStatus, onStep)"))
        assertTrue(serviceSource.contains("pairingService.confirmPairing(onStatus, onStep)"))
    }
}
